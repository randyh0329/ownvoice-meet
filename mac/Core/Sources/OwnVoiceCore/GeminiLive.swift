// Gemini Live transcription over a WebSocket (BidiGenerateContent), protocol per
// ai.google.dev/gemini-api/docs/live-api/live-transcribe:
//   setup { model, generationConfig.responseModalities, inputAudioTranscription.languageCodes }
//   realtimeInput.audio { data: base64 16-bit 16 kHz mono PCM, mimeType "audio/pcm;rate=16000" }
//   serverContent.interimInputTranscription.text  the hypothesis while someone talks (gray)
//   serverContent.inputTranscription.text         the final text at a pause (white, translated)
// The interim text sometimes runs words together that it had sent apart; Reader puts the spaces back.

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
        parse(data, interim: { $0 }, final: {})
    }

    /// `interim` sees the hypothesis before the sentence gaps go back; `final` hears of a final text.
    static func parse(_ data: Data, interim: (String) -> String, final: () -> Void) -> [Event] {
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var events: [Event] = []
        if v["setupComplete"] != nil { events.append(.setupComplete) }
        if v["goAway"] != nil { events.append(.goAway) }
        if let sc = v["serverContent"] as? [String: Any] {
            if let t = (sc["interimInputTranscription"] as? [String: Any])?["text"] as? String {
                events.append(.partial(Transcript.sentenceGaps(interim(t.trimmingCharacters(in: .whitespaces)))))
            }
            if let t = (sc["inputTranscription"] as? [String: Any])?["text"] as? String {
                final()
                events.append(.final(Transcript.sentenceGaps(t.trimmingCharacters(in: .whitespaces))))
            }
        }
        return events
    }

    /// Reads one connection's server messages as `parse` does, and also puts back the spaces the
    /// live hypothesis drops (Respace). Keep one for the whole session, across reconnects.
    public struct Reader: Sendable {
        var spacing = Respace()

        public init() {}

        public mutating func parse(_ data: Data) -> [Event] {
            var spacing = self.spacing
            defer { self.spacing = spacing }
            return GeminiLive.parse(data, interim: { $0.isEmpty ? $0 : spacing.fix($0) }, final: { spacing.reset() })
        }
    }

    /// Puts back spaces the live hypothesis drops. On long unbroken speech Gemini's interim text
    /// glues words it has already sent apart ("old built servers once every" becomes "oldbuild
    /// servers onceevery"; the final text is spaced correctly). A token is split where the previous
    /// hypothesis of the line had, at the same place, two words that it runs together: the first
    /// exactly, the second starting the same way (it may have been revised, as built became build).
    struct Respace: Sendable {
        var prev: [String] = []

        mutating func fix(_ text: String) -> String {
            var words: [String] = []
            for token in text.split(separator: " ") {
                var rest = String(token)
                while let second = split(at: words.count, rest) {
                    words.append(String(rest.dropLast(second.count)))
                    rest = second
                }
                words.append(rest)
            }
            prev = words
            return words.joined(separator: " ")
        }

        /// The second part, if `token` at word position `at` is the previous hypothesis's words at
        /// `at` and `at + 1` run together.
        func split(at: Int, _ token: String) -> String? {
            guard at + 1 < prev.count else { return nil }
            let (a, b) = (prev[at], prev[at + 1])
            guard token.hasPrefix(a) else { return nil }
            let rest = token.dropFirst(a.count)
            let common = zip(rest, b).prefix { $0 == $1 }.count
            return common >= 2 ? String(rest) : nil
        }

        mutating func reset() { prev.removeAll() }
    }

    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
