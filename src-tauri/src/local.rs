// Checks for self-hosted servers, behind the "測試連線" buttons in Settings: does the transcription
// server answer a real request, and which models does the chat server offer? Both speak the OpenAI
// API (docs/LOCAL.md), so the same checks work for faster-whisper servers, vLLM, Ollama, LM Studio.
// Gemma 4 (翻) runs in Ollama at its default address: Settings checks that Ollama answers and has
// the model, and can download it (Ollama's /api/pull, which streams one JSON line per step).

use std::time::{Duration, Instant};

use futures_util::StreamExt;
use serde_json::Value;

use crate::stt_chunk::{self, Api, Config};
use crate::vad;

/// Post half a second of silence to `<base>/audio/transcriptions`. Silence should come back as an
/// empty (or near-empty) transcript; what matters is that the server answers in the expected shape.
pub async fn check_stt(client: &reqwest::Client, base: &str, model: &str, key: Option<String>) -> Result<String, String> {
    let base = base.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err("請先填伺服器網址".into());
    }
    let cfg = Config { catalog_id: "local-whisper".into(), api: Api::OpenAi, base_url: base.into(), key, model: model.trim().into(), language: "en".into() };
    let wav = vad::wav(&vec![0i16; stt_chunk::RATE as usize / 2], stt_chunk::RATE);
    let t0 = Instant::now();
    stt_chunk::transcribe(client, &format!("{base}/audio/transcriptions"), &cfg, wav).await?;
    Ok(format!("連線成功：伺服器在 {} ms 內回應了轉錄請求", t0.elapsed().as_millis()))
}

/// The model ids `<base>/models` lists (OpenAI's shape: {"data": [{"id": ...}]}).
pub async fn list_models(client: &reqwest::Client, base: &str, key: Option<String>) -> Result<Vec<String>, String> {
    let base = base.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err("請先填伺服器網址".into());
    }
    let mut req = client.get(format!("{base}/models")).timeout(Duration::from_secs(10));
    if let Some(k) = key.as_deref().filter(|k| !k.is_empty()) {
        req = req.bearer_auth(k);
    }
    let resp = req.send().await.map_err(|e| format!("連不上 {base}：{e}"))?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!("{status}：{}", body.chars().take(200).collect::<String>()));
    }
    let v: Value = serde_json::from_str(&body).map_err(|_| "回應不是 OpenAI 相容的模型清單".to_string())?;
    let mut ids: Vec<String> = v["data"].as_array().into_iter().flatten().filter_map(|m| m["id"].as_str().map(str::to_owned)).collect();
    ids.sort();
    if ids.is_empty() {
        return Err("伺服器沒有列出任何模型".into());
    }
    Ok(ids)
}

/// Ollama's OpenAI-compatible API at its default address (the Gemma 4 options).
pub const OLLAMA_URL: &str = "http://localhost:11434/v1";
const OLLAMA_PULL: &str = "http://localhost:11434/api/pull";

/// Does Ollama answer, and does it have `model`?
pub async fn ollama_check(client: &reqwest::Client, model: &str) -> Result<String, String> {
    let ids = list_models(client, OLLAMA_URL, None).await.map_err(|e| {
        if e.starts_with("連不上") {
            "連不上 Ollama：請先安裝並打開 Ollama（ollama.com/download），它會在背景執行".to_string()
        } else {
            format!("Ollama 回應有問題：{e}")
        }
    });
    let ids = match ids {
        Ok(ids) => ids,
        // An Ollama with no models at all lists none.
        Err(e) if e.contains("沒有列出任何模型") => Vec::new(),
        Err(e) => return Err(e),
    };
    if has_model(&ids, model) {
        Ok(format!("✓ Ollama 已經有 {model}，可以開始用"))
    } else {
        Err(format!("Ollama 有在執行，但還沒有 {model}：按「下載模型」，或在終端機執行 ollama pull {model}"))
    }
}

/// Ollama lists `gemma4:latest` for a plain `ollama pull gemma4`, which is the E4B model.
fn has_model(ids: &[String], model: &str) -> bool {
    let latest = model == "gemma4:e4b";
    ids.iter().any(|id| id == model || (latest && id == "gemma4:latest"))
}

/// Download `model` into Ollama; `progress(status, done_bytes, total_bytes)` follows each step.
pub async fn ollama_pull(client: &reqwest::Client, model: &str, mut progress: impl FnMut(&str, u64, u64)) -> Result<(), String> {
    let resp = client
        .post(OLLAMA_PULL)
        .json(&serde_json::json!({ "model": model, "stream": true }))
        .send()
        .await
        .map_err(|_| "連不上 Ollama：請先安裝並打開 Ollama（ollama.com/download）".to_string())?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Ollama 沒有開始下載：{status} {}", body.chars().take(200).collect::<String>()));
    }
    let mut bytes = resp.bytes_stream();
    let mut buf = Vec::new();
    while let Some(chunk) = bytes.next().await {
        buf.extend_from_slice(&chunk.map_err(|e| format!("下載中斷：{e}"))?);
        while let Some(nl) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=nl).collect();
            match pull_step(&String::from_utf8_lossy(&line)) {
                Some(PullStep::Error(e)) => return Err(format!("Ollama 下載失敗：{e}")),
                Some(PullStep::Done) => return Ok(()),
                Some(PullStep::Progress { status, done, total }) => progress(&status, done, total),
                None => {}
            }
        }
    }
    Err("下載沒有完成就中斷了（再按一次會接著下載）".into())
}

#[derive(Debug, PartialEq)]
enum PullStep {
    Progress { status: String, done: u64, total: u64 },
    Done,
    Error(String),
}

/// One line of /api/pull: {"status":"pulling 1a2b…","total":…,"completed":…}, then {"status":"success"}.
fn pull_step(line: &str) -> Option<PullStep> {
    let v: Value = serde_json::from_str(line.trim()).ok()?;
    if let Some(e) = v["error"].as_str() {
        return Some(PullStep::Error(e.to_string()));
    }
    let status = v["status"].as_str()?;
    if status == "success" {
        return Some(PullStep::Done);
    }
    Some(PullStep::Progress { status: status.to_string(), done: v["completed"].as_u64().unwrap_or(0), total: v["total"].as_u64().unwrap_or(0) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ollama_model_names() {
        let ids = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(has_model(&ids(&["gemma4:e4b"]), "gemma4:e4b"));
        assert!(has_model(&ids(&["gemma4:latest"]), "gemma4:e4b"), "a plain `ollama pull gemma4` is E4B");
        assert!(!has_model(&ids(&["gemma4:latest"]), "gemma4:12b"));
        assert!(!has_model(&ids(&["gemma4:e2b", "qwen3:8b"]), "gemma4:e4b"));
    }

    #[test]
    fn ollama_pull_lines() {
        assert_eq!(pull_step(r#"{"status":"pulling manifest"}"#), Some(PullStep::Progress { status: "pulling manifest".into(), done: 0, total: 0 }));
        assert_eq!(
            pull_step(r#"{"status":"pulling 4c27e0f5b5ad","digest":"sha256:4c27","total":6600000000,"completed":1200000000}"#),
            Some(PullStep::Progress { status: "pulling 4c27e0f5b5ad".into(), done: 1_200_000_000, total: 6_600_000_000 })
        );
        assert_eq!(pull_step(r#"{"status":"success"}"#), Some(PullStep::Done));
        assert_eq!(pull_step(r#"{"error":"pull model manifest: file does not exist"}"#), Some(PullStep::Error("pull model manifest: file does not exist".into())));
        assert_eq!(pull_step(""), None);
    }

    // Needs Ollama running: cargo test --lib -- --ignored --nocapture ollama_gemma_check
    #[tokio::test]
    #[ignore]
    async fn ollama_gemma_check() {
        let client = reqwest::Client::new();
        println!("{:?}", ollama_check(&client, "gemma4:e4b").await);
    }

    // Needs scripts/local_whisper_server.py running on port 8790:
    //   cargo test --lib -- --ignored --nocapture local_whisper_check
    #[tokio::test]
    #[ignore]
    async fn local_whisper_check() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::new();
        let ok = check_stt(&client, "http://127.0.0.1:8790/v1", "large-v3", None).await;
        println!("{ok:?}");
        assert!(ok.is_ok());
        let bad = check_stt(&client, "http://127.0.0.1:1/v1", "x", None).await;
        println!("{bad:?}");
        assert!(bad.is_err(), "a closed port is reported");
    }

    #[tokio::test]
    async fn empty_address_is_reported_without_a_request() {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::new();
        assert!(check_stt(&client, "  ", "m", None).await.unwrap_err().contains("網址"));
        assert!(list_models(&client, "", None).await.unwrap_err().contains("網址"));
    }
}
