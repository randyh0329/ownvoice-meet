// Gemini Live transcription over a WebSocket (BidiGenerateContent), protocol per
// ai.google.dev/gemini-api/docs/live-api/live-transcribe:
//   setup { model, generationConfig.responseModalities, inputAudioTranscription.languageCodes }
//   realtimeInput.audio { data: base64 16-bit 16 kHz mono PCM, mimeType "audio/pcm;rate=16000" }
//   serverContent.interimInputTranscription.text  the hypothesis while someone talks (gray)
//   serverContent.inputTranscription.text         the final text at a pause (white, translated)

import Foundation

public enum GeminiLive {
    public static let endpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    public static let sampleRate = 16_000.0
    /// 100 ms of audio per message.
    public static let chunkSamples = 1_600

    public enum Event: Equatable, Sendable {
        case setupComplete
        case partial(String)
        case final(String)
        case goAway
    }

    public static func setupMessage(model: String, language: String) -> String {
        let lang = language.trimmingCharacters(in: .whitespaces)
        let setup: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "generationConfig": ["responseModalities": ["TEXT"]],
                "inputAudioTranscription": ["languageCodes": lang.isEmpty ? [] : [lang]],
            ],
        ]
        return json(setup)
    }

    public static func audioMessage(_ samples: [Int16]) -> String {
        var bytes = Data(capacity: samples.count * 2)
        for s in samples {
            let le = UInt16(bitPattern: s).littleEndian
            bytes.append(UInt8(le & 0xff))
            bytes.append(UInt8(le >> 8))
        }
        return json(["realtimeInput": ["audio": ["data": bytes.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
    }

    public static let streamEnd = #"{"realtimeInput":{"audioStreamEnd":true}}"#

    /// The events in one server message (JSON arrives in text or binary frames).
    public static func parse(_ data: Data) -> [Event] {
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [Event] = []
        if v["setupComplete"] != nil { events.append(.setupComplete) }
        if v["goAway"] != nil { events.append(.goAway) }
        if let sc = v["serverContent"] as? [String: Any] {
            if let t = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String {
                events.append(.partial(Transcript.sentenceGaps(t.trimmingCharacters(in: .whitespaces))))
            }
            if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String {
                events.append(.final(Transcript.sentenceGaps(t.trimmingCharacters(in: .whitespaces))))
            }
        }
        return events
    }

    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
