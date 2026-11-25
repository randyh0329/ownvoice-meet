// Apple's Translation framework (macOS 26 or later) for the captions, through the helper bundled
// next to the app's executable (apple-translate/main.swift, built by build.rs). One helper runs
// while it is needed; requests go one at a time over its stdin/stdout as JSON lines, so a
// sentence costs the on-device translation and a pipe round trip, nothing over the network.
// A helper that died is started again once. Other platforms: not offered (lib.rs offered()).

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;

use serde::Serialize;
use serde_json::{json, Value};

const HELPER: &str = "ownvoice-apple-translate";

struct Helper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

static RUNNING: Mutex<Option<Helper>> = Mutex::new(None);

/// Tauri puts sidecars next to the executable (Contents/MacOS in the app, target/<profile> in dev).
fn helper_path() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    Ok(exe.parent().ok_or("no folder for the executable")?.join(HELPER))
}

fn spawn() -> Result<Helper, String> {
    let path = helper_path()?;
    let mut child = Command::new(&path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Apple 翻譯的小程式打不開（{}）：{e}", path.display()))?;
    let stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = BufReader::new(child.stdout.take().ok_or("no stdout")?);
    Ok(Helper { child, stdin, stdout })
}

/// One request and its answer, blocking. Starts the helper if needed, and once more if it died.
fn request(req: &Value) -> Result<Value, String> {
    if !cfg!(target_os = "macos") {
        return Err("Apple 翻譯只在 Mac 上有".into());
    }
    let mut running = RUNNING.lock().map_err(|_| "Apple 翻譯的狀態壞了")?;
    for _ in 0..2 {
        if running.is_none() {
            *running = Some(spawn()?);
        }
        let h = running.as_mut().expect("just started");
        let mut line = String::new();
        let sent = writeln!(h.stdin, "{req}").and_then(|_| h.stdin.flush()).is_ok();
        if sent && h.stdout.read_line(&mut line).is_ok_and(|n| n > 0) {
            return serde_json::from_str(&line).map_err(|e| format!("Apple 翻譯回了看不懂的內容：{e}"));
        }
        if let Some(mut dead) = running.take() {
            let _ = dead.child.kill();
            let _ = dead.child.wait();
        }
    }
    Err("Apple 翻譯的小程式沒有回應".into())
}

/// The answer's text, or its error.
fn answer_text(v: &Value) -> Result<String, String> {
    if v["ok"].as_bool() == Some(true) {
        Ok(v["text"].as_str().unwrap_or_default().to_string())
    } else {
        Err(v["error"].as_str().unwrap_or("Apple 翻譯失敗").to_string())
    }
}

/// Translate one caption line into Chinese. `source` is the meeting language (BCP-47, as Settings
/// stores it); empty lets the helper detect it.
pub async fn translate(text: &str, source: &str) -> Result<String, String> {
    let req = json!({ "op": "translate", "text": text, "source": source });
    let v = tauri::async_runtime::spawn_blocking(move || request(&req)).await.map_err(|e| e.to_string())??;
    answer_text(&v)
}

/// What Settings shows for the Apple option.
#[derive(Serialize)]
pub struct Status {
    pub ready: bool,
    pub message: String,
}

pub async fn status(source: String) -> Status {
    let req = json!({ "op": "status", "source": source });
    let res = tauri::async_runtime::spawn_blocking(move || request(&req)).await.map_err(|e| e.to_string()).and_then(|r| r);
    describe(res)
}

fn describe(res: Result<Value, String>) -> Status {
    let v = match res {
        Ok(v) => v,
        Err(e) => return Status { ready: false, message: e },
    };
    if v["ok"].as_bool() != Some(true) {
        return Status { ready: false, message: v["error"].as_str().unwrap_or("Apple 翻譯無法使用").to_string() };
    }
    let (source, target) = (v["source"].as_str().unwrap_or("en"), v["target"].as_str().unwrap_or("zh-Hant"));
    let pair = format!("{source} → {target}");
    match v["status"].as_str() {
        Some("installed") => Status { ready: true, message: format!("✓ 可以用：{pair} 的語言包已在這台 Mac 上") },
        Some("supported") => Status {
            ready: false,
            message: format!("語言包還沒下載（{pair}）：按「打開語言與地區設定」→「翻譯語言」，下載英文和中文（台灣）"),
        },
        _ => Status { ready: false, message: format!("Apple 翻譯不支援 {pair}") },
    }
}

/// System Settings → General → Language & Region, where the translation languages are downloaded.
pub fn open_language_settings() -> Result<(), String> {
    if !cfg!(target_os = "macos") {
        return Err("Apple 翻譯只在 Mac 上有".into());
    }
    Command::new("open")
        .arg("x-apple.systempreferences:com.apple.Localization-Settings.extension")
        .status()
        .map_err(|e| e.to_string())
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_and_statuses() {
        assert_eq!(answer_text(&json!({"ok": true, "text": "你好"})).unwrap(), "你好");
        assert!(answer_text(&json!({"ok": false, "error": "語言包還沒下載"})).unwrap_err().contains("語言包"));
        let ready = describe(Ok(json!({"ok": true, "status": "installed", "source": "en", "target": "zh-Hant-TW"})));
        assert!(ready.ready && ready.message.contains("en → zh-Hant-TW"));
        let missing = describe(Ok(json!({"ok": true, "status": "supported", "source": "en", "target": "zh-Hant-TW"})));
        assert!(!missing.ready && missing.message.contains("翻譯語言"));
        let old = describe(Ok(json!({"ok": false, "error": "Apple 翻譯需要 macOS 26 以上", "macos26": false})));
        assert!(!old.ready && old.message.contains("macOS 26"));
        assert!(!describe(Err("打不開".into())).ready);
    }

    // On a Mac with the language packs, after a build (the helper sits next to the test binary's
    // folder only in app builds, so this points at binaries/):
    //   cargo test --lib -- --ignored --nocapture apple_translate_live
    #[test]
    #[ignore]
    fn apple_translate_live() {
        let bin = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("binaries/ownvoice-apple-translate-universal-apple-darwin");
        let mut child = Command::new(bin).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let mut out = BufReader::new(child.stdout.take().unwrap());
        for req in [json!({"op": "status", "source": "en"}), json!({"op": "translate", "text": "The software update fixed the network video quality.", "source": "en"})] {
            let t0 = std::time::Instant::now();
            writeln!(stdin, "{req}").unwrap();
            let mut line = String::new();
            out.read_line(&mut line).unwrap();
            println!("{} ms  {line}", t0.elapsed().as_millis());
        }
    }
}
