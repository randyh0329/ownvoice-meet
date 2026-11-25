// The streaming services' own messages.
//
// OpenAI gpt-live-transcribe over the Realtime WebSocket (developers.openai.com/api/docs/guides/
// realtime-transcription): session.update with a transcription session (PCM 24 kHz, no server turn
// detection); the client segments, sends input_audio_buffer.append then .commit per utterance (so
// silence is never billed); deltas and the completed transcript come back per item_id, not always
// in the order the utterances were spoken (Utterances puts them back in order).
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
        /// An utterance was committed (input_audio_buffer.committed): the order they were spoken in.
        case committed(item: String)
        /// No transcript will come for this utterance.
        case failed(item: String)
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
        case "conversation.item.input_audio_transcription.failed": return .failed(item: item)
        case "input_audio_buffer.committed": return .committed(item: item)
        case "error": return .error((v["error"] as? [String: Any])?["message"] as? String ?? "error")
        default: return nil
        }
    }
}

extension OpenAIRealtime {
    /// One connection's transcripts as caption events, utterance by utterance in the order they
    /// were spoken: the gray line shows the oldest utterance still being transcribed, and a
    /// transcript that completes before an earlier one waits for it, so it never lands on the
    /// earlier utterance's line. Make a new one for each connection.
    public struct Utterances: Sendable {
        public enum Output: Equatable, Sendable {
            case partial(String)
            case final(String)
        }

        private var order: [String] = []
        private var texts: [String: String] = [:]
        private var finals: [String: String] = [:]
        private var ended: Set<String> = []

        public init() {}

        public mutating func handle(_ event: Event) -> [Output] {
            switch event {
            case .committed(let item):
                note(item)
                return []
            case let .delta(item, text):
                guard note(item) else { return [] }
                texts[item, default: ""] += text
                return item == order.first ? [.partial(texts[item] ?? "")] : []
            case let .completed(item, text):
                guard note(item) else { return [] }
                finals[item] = text
                return release()
            case .failed(let item):
                guard note(item) else { return [] }
                // What was heard of it, if anything, is all there will be.
                finals[item] = texts[item] ?? ""
                return release()
            case .accepted, .error:
                return []
            }
        }

        /// The connection dropped: each utterance still waiting ends with what was heard of it.
        public mutating func flush() -> [Output] {
            let out = order.map { Output.final(finals[$0] ?? texts[$0] ?? "") }
            self = Utterances()
            return out
        }

        /// Puts `item` in line; false for an utterance already ended.
        @discardableResult
        private mutating func note(_ item: String) -> Bool {
            if ended.contains(item) { return false }
            if !order.contains(item) { order.append(item) }
            return true
        }

        /// The completed transcripts at the front, in order, then the gray line of the next one.
        private mutating func release() -> [Output] {
            var out: [Output] = []
            while let first = order.first, let text = finals[first] {
                out.append(.final(text))
                order.removeFirst()
                finals[first] = nil
                texts[first] = nil
                ended.insert(first)
            }
            if !out.isEmpty, let first = order.first, let text = texts[first], !text.isEmpty {
                out.append(.partial(text))
            }
            return out
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
