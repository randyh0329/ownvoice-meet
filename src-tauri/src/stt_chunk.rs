// Speech-to-text by sentence: the energy segmenter cuts utterances out of the audio and each one is
// posted as a WAV file: to an OpenAI-compatible /audio/transcriptions endpoint (OpenAI
// gpt-4o-mini-transcribe, and self-hosted servers such as faster-whisper behind the same API), or to
// Gemini's /interactions endpoint (gemini-3.5-transcribe, inline audio; protocol per
// ai.google.dev/gemini-api/docs/transcribe: input [{type: audio, data, mime_type}],
// generation_config.transcription_config.language_codes, text in steps[].content[].text).
// A gray "…" line shows while someone talks; the text arrives when the sentence ends.

use std::time::{Duration, Instant};

use base64::Engine as _;
use reqwest::multipart::{Form, Part};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager};
use tokio::sync::mpsc;

use crate::audio::chunk_len;
use crate::captions;
use crate::llm::Http;
use crate::usage;
use crate::vad::{wav, Segmenter, VadEvent};

pub const RATE: u32 = 16_000;
const SILENCE_AFTER: Duration = Duration::from_millis(250);
pub const GEMINI_BASE: &str = "https://generativelanguage.googleapis.com/v1beta";

/// Which API the sentences are posted to.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Api {
    /// OpenAI-compatible POST {base}/audio/transcriptions (multipart).
    OpenAi,
    /// Gemini POST {base}/interactions (JSON, inline base64 audio).
    Gemini,
}

pub struct Config {
    pub catalog_id: String,
    pub api: Api,
    /// Base URL ending before /audio/transcriptions or /interactions, e.g. https://api.openai.com/v1
    pub base_url: String,
    pub key: Option<String>,
    pub model: String,
    /// OpenAI: ISO 639-1. Gemini: BCP-47 (en-US). Empty = let the server detect it.
    pub language: String,
}

pub async fn run(app: AppHandle, cfg: Config, mut audio: mpsc::Receiver<Vec<i16>>) {
    let (jobs, queue) = mpsc::channel::<(u64, Vec<i16>)>(32);
    // One upload at a time keeps captions in order.
    let worker = tauri::async_runtime::spawn(upload_worker(app.clone(), cfg, queue));
    captions::status(&app, "聆聽中（切句上傳）");

    let mut seg = Segmenter::new(RATE);
    let mut current: Option<u64> = None;
    let mut last_audio = Instant::now();
    let mut tick = tokio::time::interval(Duration::from_millis(100));
    let silence = vec![0i16; chunk_len(RATE)];
    loop {
        let events = tokio::select! {
            chunk = audio.recv() => match chunk {
                Some(c) => { last_audio = Instant::now(); seg.push(&c) }
                None => break,
            },
            // Loopback delivers nothing while nothing plays: feed silence so a sentence can end.
            _ = tick.tick() => {
                if last_audio.elapsed() > SILENCE_AFTER && seg.in_speech() { seg.push(&silence) } else { continue }
            }
        };
        for ev in events {
            match ev {
                VadEvent::Start(_) => current = Some(captions::open(&app)),
                VadEvent::Audio(_) => {}
                VadEvent::End(utt) => {
                    if let Some(id) = current.take() {
                        let _ = jobs.send((id, utt)).await;
                    }
                }
                VadEvent::Discard => {
                    if let Some(id) = current.take() {
                        captions::drop_line(&app, id);
                    }
                }
            }
        }
    }
    if let Some(id) = current.take() {
        captions::drop_line(&app, id);
    }
    drop(jobs);
    let _ = worker.await;
}

async fn upload_worker(app: AppHandle, cfg: Config, mut queue: mpsc::Receiver<(u64, Vec<i16>)>) {
    let client = app.state::<Http>().0.clone();
    let base = cfg.base_url.trim_end_matches('/');
    let url = match cfg.api {
        Api::OpenAi => format!("{base}/audio/transcriptions"),
        Api::Gemini => format!("{base}/interactions"),
    };
    while let Some((id, utt)) = queue.recv().await {
        let secs = utt.len() as f64 / RATE as f64;
        let audio = wav(&utt, RATE);
        let result = match cfg.api {
            Api::OpenAi => transcribe(&client, &url, &cfg, audio).await,
            Api::Gemini => transcribe_gemini(&client, &url, &cfg, audio).await,
        };
        match result {
            Ok(text) => {
                usage::add_audio(&app, &cfg.catalog_id, secs);
                captions::finish(&app, id, &text);
            }
            Err(e) => {
                captions::fail(&app, id, &format!("辨識失敗：{e}"));
                captions::status(&app, format!("辨識失敗：{e}"));
            }
        }
    }
}

pub(crate) async fn transcribe(client: &reqwest::Client, url: &str, cfg: &Config, wav: Vec<u8>) -> Result<String, String> {
    let file = Part::bytes(wav).file_name("speech.wav").mime_str("audio/wav").map_err(|e| e.to_string())?;
    let mut form = Form::new().part("file", file).text("model", cfg.model.clone()).text("response_format", "json");
    if !cfg.language.is_empty() {
        form = form.text("language", cfg.language.clone());
    }
    let mut req = client.post(url).multipart(form).timeout(Duration::from_secs(30));
    if let Some(k) = cfg.key.as_deref().filter(|k| !k.is_empty()) {
        req = req.bearer_auth(k);
    }
    let resp = req.send().await.map_err(|e| format!("network: {e}"))?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let v: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    if !status.is_success() {
        let msg = v["error"]["message"].as_str().map(str::to_owned).unwrap_or(body);
        return Err(format!("{status}: {}", msg.chars().take(200).collect::<String>()));
    }
    Ok(v["text"].as_str().unwrap_or_default().to_string())
}

/// One sentence to Gemini's /interactions with a transcription model (gemini-3.5-transcribe).
pub(crate) async fn transcribe_gemini(client: &reqwest::Client, url: &str, cfg: &Config, wav: Vec<u8>) -> Result<String, String> {
    let mut req = client.post(url).json(&gemini_body(&cfg.model, &cfg.language, &wav)).timeout(Duration::from_secs(30));
    if let Some(k) = cfg.key.as_deref().filter(|k| !k.is_empty()) {
        req = req.header("x-goog-api-key", k);
    }
    let resp = req.send().await.map_err(|e| format!("network: {e}"))?;
    let status = resp.status();
    let body = resp.text().await.unwrap_or_default();
    let v: Value = serde_json::from_str(&body).unwrap_or(Value::Null);
    if !status.is_success() {
        let msg = v["error"]["message"].as_str().map(str::to_owned).unwrap_or(body);
        return Err(format!("{status}: {}", msg.chars().take(200).collect::<String>()));
    }
    gemini_text(&v)
}

/// The request: the sentence inline as WAV, verbatim mode (Smart mode would act on spoken
/// "actually no, …" corrections, which in a meeting are the speaker's words, not instructions).
fn gemini_body(model: &str, language: &str, wav: &[u8]) -> Value {
    let languages: Vec<&str> = if language.trim().is_empty() { vec![] } else { vec![language.trim()] };
    json!({
        "model": model,
        "input": [{
            "type": "audio",
            "data": base64::engine::general_purpose::STANDARD.encode(wav),
            "mime_type": "audio/wav",
        }],
        "generation_config": { "transcription_config": { "language_codes": languages } },
    })
}

/// The transcript: every text part of the model's output steps, joined.
fn gemini_text(v: &Value) -> Result<String, String> {
    if let Some(s) = v["status"].as_str().filter(|s| *s != "completed") {
        return Err(format!("Gemini status: {s}"));
    }
    if let Some(t) = v["output_text"].as_str() {
        return Ok(t.trim().to_string());
    }
    let text = v["steps"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|step| step["type"].as_str().map_or(true, |t| t == "model_output"))
        .flat_map(|step| step["content"].as_array().into_iter().flatten())
        .filter(|c| c["type"] == "text")
        .filter_map(|c| c["text"].as_str())
        .collect::<Vec<_>>()
        .join(" ");
    Ok(text.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gemini_request_carries_the_sentence_inline_with_a_language_hint() {
        let b = gemini_body("gemini-3.5-transcribe", "en-US", b"RIFF");
        assert_eq!(b["model"], "gemini-3.5-transcribe");
        assert_eq!(b["input"][0]["type"], "audio");
        assert_eq!(b["input"][0]["mime_type"], "audio/wav");
        assert_eq!(b["input"][0]["data"], "UklGRg==");
        assert_eq!(b["generation_config"]["transcription_config"]["language_codes"], json!(["en-US"]));
        let auto = gemini_body("gemini-3.5-transcribe", "", b"");
        assert_eq!(auto["generation_config"]["transcription_config"]["language_codes"], json!([]), "empty = detect");
    }

    #[test]
    fn gemini_transcript_is_read_from_the_output_steps() {
        // The REST response as documented (ai.google.dev/gemini-api/docs/transcribe#parsing-output).
        let v = json!({
            "id": "interactions/abc123xyz",
            "status": "completed",
            "steps": [{
                "id": "step_001",
                "type": "model_output",
                "content": [{
                    "type": "text",
                    "text": "Hello world",
                    "annotations": [{ "type": "word_info", "text": "Hello", "start_offset": "0.100s", "end_offset": "0.400s" }]
                }]
            }]
        });
        assert_eq!(gemini_text(&v).unwrap(), "Hello world");
        assert_eq!(gemini_text(&json!({ "status": "completed", "steps": [] })).unwrap(), "", "silence");
        assert!(gemini_text(&json!({ "status": "failed" })).is_err());
    }
}
