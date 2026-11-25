// The streaming services' own messages.
//
// OpenAI gpt-live-transcribe over the Realtime WebSocket (developers.openai.com/api/docs/guides/
// realtime-transcription): session.update with a transcription session (PCM 24 kHz, no server turn
// detection); the client segments, sends input_audio_buffer.append then .commit per utterance (so
// silence is never billed); deltas and the completed transcript come back per item_id.
//
// Gemini Live Translate (gemini-3.5-live-translate-preview): setup adds translationConfig with AUDIO
// out and both transcriptions; inputTranscription is what was said and outputTranscription the
// translation, both continuous streams (Interpreter pairs them into lines).

import Foundation

public enum OpenAIRealtime {
    public static let sampleRate = 24_000
    /// The guide shows no transcription-only URL; both forms are tried, in order.
    public static let urls = [
        URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!,
        URL(string: "wss://api.openai.com/v1/realtime?model=gpt-live-transcribe")!,
    ]

    public enum Event: Equatable, Sendable {
        case accepted
        case delta(item: String, text: String)
        case completed(item: String, text: String)
        case error(String)
    }

    public static func sessionUpdate(model: String, language: String) -> String {
        var transcription: [String: Any] = ["model": model, "delay": "low"]
        if !language.isEmpty { transcription["languages"] = [language] }
        let msg: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": sampleRate],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ]],
            ],
        ]
        return GeminiLive.json(msg)
    }

    public static func append(_ samples: [Int16]) -> String {
        GeminiLive.json(["type": "input_audio_buffer.append", "audio": pcmBase64(samples)])
    }

    public static let commit = #"{"type":"input_audio_buffer.commit"}"#
    public static let clear = #"{"type":"input_audio_buffer.clear"}"#

    public static func parse(_ data: Data) -> Event? {
        guard let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let item = v["item_id"] as? String ?? ""
        switch v["type"] as? String {
        case "session.updated": return .accepted
        case "conversation.item.input_audio_transcription.delta": return .delta(item: item, text: v["delta"] as? String ?? "")
        case "conversation.item.input_audio_transcription.completed": return .completed(item: item, text: v["transcript"] as? String ?? "")
        case "error": return .error((v["error"] as? [String: Any])?["message"] as? String ?? "error")
        default: return nil
        }
    }
}

extension GeminiLive {
    public enum TranslateEvent: Equatable, Sendable {
        case setupComplete
        case heard(String)
        case translated(String)
    }

    public static func translateSetup(model: String, target: String, instruction: String) -> String {
        var setup: [String: Any] = [
            "model": "models/\(model)",
            "inputAudioTranscription": [String: Any](),
            "outputAudioTranscription": [String: Any](),
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                // Speech already in the target language stays silent.
                "translationConfig": ["targetLanguageCode": target, "echoTargetLanguage": false],
            ],
        ]
        if !instruction.isEmpty { setup["systemInstruction"] = ["parts": [["text": instruction]]] }
        return json(["setup": setup])
    }

    public static func parseTranslate(_ data: Data) -> [TranslateEvent] {
        guard let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var events: [TranslateEvent] = []
        if v["setupComplete"] != nil { events.append(.setupComplete) }
        if let sc = v["serverContent"] as? [String: Any] {
            if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String { events.append(.heard(t)) }
            if let t = (sc["outputTranscription"] as? [String: Any])?["text"] as? String { events.append(.translated(t)) }
        }
        return events
    }
}

func pcmBase64(_ samples: [Int16]) -> String {
    var bytes = Data(capacity: samples.count * 2)
    for s in samples {
        let le = UInt16(bitPattern: s).littleEndian
        bytes.append(UInt8(le & 0xff))
        bytes.append(UInt8(le >> 8))
    }
    return bytes.base64EncodedString()
}
