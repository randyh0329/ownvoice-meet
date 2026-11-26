// Recognition on this Mac, as in the first version (local_stt.rs and models.rs there): NVIDIA
// Parakeet TDT 0.6B v3 for English and other European languages, SenseVoice for Chinese, Japanese,
// Korean and Cantonese, both run by sherpa-onnx. Here are the model files (where they come from,
// their size and SHA-256) and which model hears a sentence.
//
// With the meeting language on automatic, SenseVoice hears each sentence first and names its
// language: Chinese and Cantonese keep SenseVoice's text, as do Japanese and Korean when the text
// is written in kana or hangul; anything else goes to Parakeet. Taiwan's forums mix Chinese and
// English, so each sentence is decided by itself.

import Foundation

public enum LocalSpeech {
    public struct ModelFile: Equatable, Sendable {
        /// Path under the models folder.
        public let name: String
        public let url: URL
        public let sha256: String
        public let bytes: Int64
    }

    static let parakeetBase = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/"
    static let senseVoiceBase = "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/"

    static func file(_ folder: String, _ base: String, _ name: String, _ sha256: String, _ bytes: Int64) -> ModelFile {
        ModelFile(name: folder + "/" + name, url: URL(string: base + name)!, sha256: sha256, bytes: bytes)
    }

    /// Parakeet (CC BY 4.0): encoder, decoder, joiner, tokens. SenseVoice: model, tokens; the
    /// 2024-07-17 int8 export, because the 2025-09-09 one named English "yue" and garbled Japanese
    /// and Korean. About 910 MB in all.
    public static let files: [ModelFile] = [
        file("parakeet-v3", parakeetBase, "encoder.int8.onnx", "1afbe69c1ffdabee94755f42e4daf1d93549131a3da11356bda84fcef0f2c479", 652_282_294),
        file("parakeet-v3", parakeetBase, "decoder.int8.onnx", "0222a86147299d4dee90edf95b6d13827edb42ad8b7c9cf0b2582f030937c0b5", 11_845_274),
        file("parakeet-v3", parakeetBase, "joiner.int8.onnx", "cbd02f3696e9944970111fb439d9c3fd365a80374565f13f2b9c7007d253fc98", 6_355_277),
        file("parakeet-v3", parakeetBase, "tokens.txt", "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d", 93_939),
        file("sensevoice", senseVoiceBase, "model.int8.onnx", "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51", 239_233_841),
        file("sensevoice", senseVoiceBase, "tokens.txt", "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc", 315_894),
    ]

    public static var parakeetEncoder: ModelFile { files[0] }
    public static var parakeetDecoder: ModelFile { files[1] }
    public static var parakeetJoiner: ModelFile { files[2] }
    public static var parakeetTokens: ModelFile { files[3] }
    public static var senseVoiceModel: ModelFile { files[4] }
    public static var senseVoiceTokens: ModelFile { files[5] }

    /// The folders under the models folder that hold these files (removed to delete them).
    public static let folders = ["parakeet-v3", "sensevoice"]

    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Languages Parakeet v3 was trained on (ISO 639-1).
    public static let parakeetLanguages: Set<String> = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]

    /// Which model hears a sentence.
    public enum Route: Equatable, Sendable {
        case parakeet
        case senseVoice
        /// SenseVoice names the language, then keeps the sentence or hands it to Parakeet.
        case auto
    }

    /// "en-US" → "en"; "" stays "".
    public static func iso639(_ bcp47: String) -> String {
        bcp47.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// The meeting language decides the model; none chosen means each sentence decides.
    public static func route(_ language: String) -> Route {
        let code = iso639(language)
        if code.isEmpty { return .auto }
        return parakeetLanguages.contains(code) ? .parakeet : .senseVoice
    }

    /// The hint SenseVoice is given: one of the languages it knows, else "auto".
    public static func senseVoiceHint(_ language: String) -> String {
        let code = iso639(language)
        return ["zh", "en", "ja", "ko", "yue"].contains(code) ? code : "auto"
    }

    /// SenseVoice reports the language as "<|zh|>": just "zh".
    public static func languageTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "<|> \n")).lowercased()
    }

    /// Whether SenseVoice's text is kept for a sentence heard on automatic, given the language it
    /// named. Chinese and Cantonese always; Japanese and Korean only when written in kana or
    /// hangul, so English it mistook for one of them still goes to Parakeet.
    public static func keepsSenseVoice(language tag: String, text: String) -> Bool {
        switch tag {
        case "zh", "yue": return true
        case "ja": return text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        case "ko": return text.unicodeScalars.contains { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
        default: return false
        }
    }

    /// Whether the text SenseVoice gave is Chinese, to be written in the user's Chinese.
    public static func isChinese(language tag: String) -> Bool { tag == "zh" || tag == "yue" }

    /// What becomes of a sentence once SenseVoice has heard it.
    public enum Outcome: Equatable, Sendable {
        /// SenseVoice's text is the line; `chinese` when it is to be written in the user's Chinese.
        case senseVoice(String, chinese: Bool)
        /// Parakeet hears the sentence instead.
        case parakeet
    }

    /// `language` as SenseVoice reported it ("<|zh|>").
    public static func outcome(route: Route, text: String, language: String) -> Outcome {
        let tag = languageTag(language)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch route {
        case .parakeet: return .parakeet
        case .senseVoice: return .senseVoice(text, chinese: isChinese(language: tag))
        case .auto: return keepsSenseVoice(language: tag, text: text) ? .senseVoice(text, chinese: isChinese(language: tag)) : .parakeet
        }
    }
}
