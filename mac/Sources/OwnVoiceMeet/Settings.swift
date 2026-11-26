// What the user chose, kept in UserDefaults; API keys in the Keychain, never in a file.

import Foundation
import OwnVoiceCore
import Security

enum ListenOption: String, CaseIterable, Codable, Identifiable {
    case appleSpeech = "apple-speech"
    case geminiLive = "gemini-live"
    case geminiLiveTranslate = "gemini-live-translate"
    case geminiTranscribe = "gemini-transcribe"
    case openaiLive = "openai-live"
    case openaiMini = "openai-mini"
    case localWhisper = "local-whisper"
    case localSherpa = "sherpa-local"
    case recordOnly = "record-only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech: String(localized: "Apple on-device recognition (free, stays on the Mac)")
        case .geminiLive: String(localized: "Gemini 3.5 Transcribe Live (about US$0.54 an hour)")
        case .geminiLiveTranslate: String(localized: "Gemini 3.5 Live Translate: hears and translates in one (about US$2.2 an hour)")
        case .geminiTranscribe: String(localized: "Gemini 3.5 Transcribe, sentence by sentence (about US$0.30 an hour)")
        case .openaiLive: String(localized: "OpenAI gpt-live-transcribe (about US$1.02 an hour)")
        case .openaiMini: String(localized: "OpenAI gpt-4o-mini-transcribe, sentence by sentence (about US$0.18 an hour)")
        case .localWhisper: String(localized: "Your own Whisper server (OpenAI-compatible, free)")
        case .localSherpa: String(localized: "On this Mac: Parakeet + SenseVoice (free, offline)")
        case .recordOnly: String(localized: "Record only, no captions")
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech: String(localized: "macOS's own SpeechAnalyzer: recognized on the Mac, with gray text while someone speaks. The first time, the language's model is downloaded. Needs the meeting language chosen.")
        case .geminiLive: String(localized: "Google's live transcription, steadier in a noisy room. Needs a Gemini API key (use the paid tier: free-tier data is used to improve Google's products).")
        case .geminiLiveTranslate: String(localized: "Google's interpreter model hears the speech and gives the Chinese itself; the caption translation model is not used. A preview model. Needs a Gemini API key.")
        case .geminiTranscribe: String(localized: "Each sentence goes to Google once it ends: no gray text, half the price of Live. Needs a Gemini API key.")
        case .openaiLive: String(localized: "OpenAI's live transcription, gray text while someone speaks; only speech is sent. Needs an OpenAI API key.")
        case .openaiMini: String(localized: "Each sentence goes to OpenAI once it ends: the cheapest cloud option, no gray text. Needs an OpenAI API key.")
        case .localWhisper: String(localized: "Each sentence goes to a Whisper server you run (faster-whisper, whisper.cpp server…): sound stays on your own machines. Fill in its address below.")
        case .localSherpa: String(localized: "Recognized on the Mac: NVIDIA Parakeet for English and other European languages, SenseVoice for Chinese, Japanese and Korean. With the meeting language on Detect automatically, each sentence is heard in its own language, so talks that mix Chinese and English work. No gray text: an ellipsis shows while someone speaks, and the line comes about a second after they stop. Download the models (about 910 MB) below first.")
        case .recordOnly: String(localized: "For a room with bad internet: the sound is kept in full on the Mac (turn on saving with the recording), nothing is recognized or translated.")
        }
    }

    /// Recognition that costs money while it runs (paused when the room is quiet).
    var isCloud: Bool {
        switch self {
        case .geminiLive, .geminiLiveTranslate, .geminiTranscribe, .openaiLive, .openaiMini: true
        case .appleSpeech, .localWhisper, .localSherpa, .recordOnly: false
        }
    }
}

enum TranslateOption: String, CaseIterable, Codable, Identifiable {
    case apple = "apple-translate"
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case luna = "gpt-6-luna"
    case sol = "gpt-6.1-sol"
    case geminiFlashLite = "gemini-3.5-flash-lite"
    case geminiFlash = "gemini-3.8-flash"
    case gemma = "gemma4-e4b"
    case gemma12 = "gemma4-12b"
    case translateGemma = "translategemma-4b"
    case localServer = "local-llm"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: String(localized: "Apple Translation (on-device, free)")
        case .haiku: String(localized: "Claude Haiku 5.5 (about US$0.03 an hour)")
        case .sonnet: String(localized: "Claude Sonnet 5.5 (about US$0.66 an hour)")
        case .luna: String(localized: "OpenAI gpt-6-luna (about US$0.03 an hour)")
        case .sol: String(localized: "OpenAI gpt-6.1-sol (about US$0.66 an hour)")
        case .geminiFlashLite: String(localized: "Gemini 3.5 Flash-Lite (about US$0.13 an hour)")
        case .geminiFlash: String(localized: "Gemini 3.8 Flash (about US$0.25 an hour, slow)")
        case .gemma: String(localized: "Gemma 4 E4B (local Ollama, free)")
        case .gemma12: String(localized: "Gemma 4 12B (local Ollama, free, needs 16 GB)")
        case .translateGemma: String(localized: "TranslateGemma 4B (local Ollama, free, translation only)")
        case .localServer: String(localized: "Your own server (OpenAI-compatible: vLLM, LM Studio…)")
        }
    }

    var detail: String {
        switch self {
        case .apple: String(localized: "macOS's own translation: Chinese appears almost at once. Line by line, without the earlier lines or the glossary. Download the languages first in System Settings → General → Language & Region → Translation Languages.")
        case .haiku: String(localized: "Uses the earlier lines and the glossary; steady wording. Needs an Anthropic API key.")
        case .sonnet: String(localized: "Stronger wording and judgment than Haiku, slower, about 20 times the price; captions rarely need it. Needs an Anthropic API key.")
        case .luna: String(localized: "The same price as Haiku; its speed varies more. Needs an OpenAI API key.")
        case .sol: String(localized: "OpenAI's mid tier: stronger, about 20 times the price of luna. Needs an OpenAI API key.")
        case .geminiFlashLite: String(localized: "Uses the earlier lines and the glossary; shares the key with Gemini recognition.")
        case .geminiFlash: String(localized: "Google's newest Flash; 4–7 seconds a sentence (its thinking cannot be turned off), too slow for live captions. Needs a Gemini API key.")
        case .gemma: String(localized: "Google's open model running on the Mac: free, text stays on the computer. Set it up with one click below (Gemma 4 on this Mac). A small model: wording is rougher than the cloud models.")
        case .gemma12: String(localized: "The larger Gemma 4: steadier translation, slower, and wants 16 GB of memory or more. Set it up below.")
        case .translateGemma: String(localized: "Google's model made for translation (55 languages), smaller and faster than Gemma 4 E4B. Line by line, without the earlier lines or the glossary; replies and the summary use another model. Set it up below.")
        case .localServer: String(localized: "Any server with the OpenAI Chat Completions API on your own machines. Fill in its address and model below.")
        }
    }

    /// The Ollama model this option runs, for the setup section.
    var ollamaModel: LocalModel? {
        switch self {
        case .gemma: .gemmaE4B
        case .gemma12: .gemma12B
        case .translateGemma: .translateGemma4B
        default: nil
        }
    }
}

/// A model for the summaries: the text model in use, or one of these.
enum SummaryModelChoice: String, CaseIterable, Codable, Identifiable {
    case auto
    case haiku, sonnet, opus, fable, luna, sol, flashLite, flash, gemma, gemma12, local

    var id: String { rawValue }

    var spec: ModelSpec? {
        switch self {
        case .auto: nil
        case .haiku: .haiku
        case .sonnet: .sonnet
        case .opus: .opus
        case .fable: .fable
        case .luna: .luna
        case .sol: .sol
        case .flashLite: .flashLite
        case .flash: .flash
        case .gemma: .gemma
        case .gemma12: .gemma12
        case .local: TranslateOption.localServer.textModel
        }
    }

    var label: String {
        switch self {
        case .auto: String(localized: "Same as replies (the text model in use)")
        case .opus: String(localized: "Claude Opus 5.5 (strongest value; US$4 / US$20 per million tokens)")
        case .fable: String(localized: "Claude Fable 5.2 (most capable; US$8 / US$40 per million tokens)")
        default: spec?.name ?? rawValue
        }
    }
}

/// The models Settings can set up in Ollama.
enum LocalModel: String, CaseIterable, Identifiable {
    case translateGemma4B = "translategemma:4b"
    case gemmaE4B = "gemma4:e4b"
    case gemma12B = "gemma4:12b"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .translateGemma4B: String(localized: "TranslateGemma 4B: translation only, about 3.3 GB")
        case .gemmaE4B: String(localized: "Gemma 4 E4B: also replies and summaries, about 7 GB")
        case .gemma12B: String(localized: "Gemma 4 12B: steadier, about 8 GB, wants 16 GB of memory")
        }
    }

    var option: TranslateOption {
        switch self {
        case .translateGemma4B: .translateGemma
        case .gemmaE4B: .gemma
        case .gemma12B: .gemma12
        }
    }
}

enum AudioInput: String, CaseIterable, Codable, Identifiable {
    case system
    case microphone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "Sound the Mac plays (online meetings)")
        case .microphone: String(localized: "Microphone (in the room)")
        }
    }
}

/// What a session leaves on disk. Off unless the user chooses: other people's voices are kept.
enum SaveMode: String, CaseIterable, Codable, Identifiable {
    case off
    case transcript
    case transcriptAndAudio = "transcript-audio"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: String(localized: "Don't save")
        case .transcript: String(localized: "Transcript and summary")
        case .transcriptAndAudio: String(localized: "Transcript, summary and recording")
        }
    }
}

/// The language the user speaks in the meeting: replies and 補對照 write in it.
struct SpeakLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all = [
        SpeakLanguage(code: "en", name: String(localized: "English")),
        SpeakLanguage(code: "ja", name: String(localized: "Japanese")),
        SpeakLanguage(code: "ko", name: String(localized: "Korean")),
        SpeakLanguage(code: "de", name: String(localized: "German")),
        SpeakLanguage(code: "fr", name: String(localized: "French")),
        SpeakLanguage(code: "es", name: String(localized: "Spanish")),
        SpeakLanguage(code: "vi", name: String(localized: "Vietnamese")),
        SpeakLanguage(code: "th", name: String(localized: "Thai")),
        SpeakLanguage(code: "id", name: String(localized: "Indonesian")),
    ]
}

/// The interface language: the Mac's, or one chosen here (AppleLanguages, read at launch).
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case traditional = "zh-Hant"
    case simplified = "zh-Hans"

    var id: String { rawValue }

    /// Each language names itself; "System" follows the interface.
    var label: String {
        switch self {
        case .system: String(localized: "Same as the Mac")
        case .english: "English"
        case .traditional: "繁體中文"
        case .simplified: "简体中文"
        }
    }

    /// Set here (in this app's own defaults), not inherited from the Mac.
    static var current: InterfaceLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return allCases.first { $0 != .system && first.hasPrefix($0.rawValue) } ?? .system
    }

    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Languages offered for the meeting (BCP-47). Apple recognition needs one chosen. Detect
/// automatically ("") lets recognition on this Mac pick each sentence's language; the other
/// recognizers take it as no language hint.
struct MeetingLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all = [
        MeetingLanguage(code: "", name: String(localized: "Detect automatically")),
        MeetingLanguage(code: "en-US", name: String(localized: "English (US)")),
        MeetingLanguage(code: "en-GB", name: String(localized: "English (UK)")),
        MeetingLanguage(code: "ja-JP", name: String(localized: "Japanese")),
        MeetingLanguage(code: "ko-KR", name: String(localized: "Korean")),
        MeetingLanguage(code: "de-DE", name: String(localized: "German")),
        MeetingLanguage(code: "fr-FR", name: String(localized: "French")),
        MeetingLanguage(code: "es-ES", name: String(localized: "Spanish")),
    ]
}

struct AppSettings: Codable, Equatable {
    var listen: ListenOption = .appleSpeech
    var translate: TranslateOption = .apple
    var input: AudioInput = .system
    var meetingLanguage = "en-US"
    var chinese: ChineseVariant = .traditionalTaiwan
    var speakLanguage = "en"
    /// The live summary brings itself up to date while listening (else only on Update Now)…
    var summaryAuto = true { didSet { summaryEveryMinutes = summaryAuto ? summaryMinutes : 0 } }
    /// …every this many minutes (within `summaryMinutesRange`), counted from the last update.
    var summaryMinutes = 5 { didSet { summaryEveryMinutes = summaryAuto ? summaryMinutes : 0 } }
    /// What builds before 0.7.1 read (0 meant only when asked), kept in step so going back to one
    /// keeps the choice. Not read by this build.
    private(set) var summaryEveryMinutes = 5
    static let summaryMinutesRange = 1...60
    static func clampedMinutes(_ m: Int) -> Int {
        min(max(m, summaryMinutesRange.lowerBound), summaryMinutesRange.upperBound)
    }
    /// "Every minute" / "Every 5 minutes".
    static func everyMinutes(_ m: Int) -> String {
        m == 1 ? String(localized: "Every minute") : String(localized: "Every \(String(m)) minutes")
    }
    var liveSummaryModel: SummaryModelChoice = .auto
    /// Once the meeting ends, the whole transcript goes to `meetingSummaryModel` for the minutes.
    var meetingSummaryOnStop = false
    var meetingSummaryModel: SummaryModelChoice = .auto
    var saveMode: SaveMode = .off
    /// Empty: Documents/OwnVoice Meet.
    var saveFolder = ""
    var localServerURL = "http://localhost:8000/v1"
    var localServerModel = ""
    var whisperURL = "http://localhost:8790/v1"
    var whisperModel = "large-v3"
    /// Cloud recognition stops sending sound after a quiet minute, and starts again on speech.
    var pauseWhenQuiet = true
    /// Minutes of quiet after which listening stops; 0 = never.
    var stopAfterQuietMinutes = 30
    /// The people in the meeting, named by the user (lines refer to them by position).
    var speakerNames: [String] = []
    /// Speakers told apart by voice, on this Mac (SpeakerDetector).
    var autoSpeakers = false
    var glossary = ""
    var alwaysOnTop = true
    var fontSize = 20.0
    var captionTheme: CaptionTheme = .system
    var customHeard = "#33FF66"
    var customTranslation = "#FFE066"
    var customBackground = "#0C0C0C"
    var customMonospaced = true

    init() {}

    /// Each field falls back to its default, so a setting added later keeps the others.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        listen = (try? c.decodeIfPresent(ListenOption.self, forKey: .listen)) ?? d.listen
        translate = (try? c.decodeIfPresent(TranslateOption.self, forKey: .translate)) ?? d.translate
        input = (try? c.decodeIfPresent(AudioInput.self, forKey: .input)) ?? d.input
        meetingLanguage = (try? c.decodeIfPresent(String.self, forKey: .meetingLanguage)) ?? d.meetingLanguage
        chinese = (try? c.decodeIfPresent(ChineseVariant.self, forKey: .chinese)) ?? d.chinese
        speakLanguage = (try? c.decodeIfPresent(String.self, forKey: .speakLanguage)) ?? d.speakLanguage
        // Before 0.7.1 there was only summaryEveryMinutes, with 0 meaning "only when asked"; such
        // a build drops the newer keys when it saves, so the old one decides when they are missing.
        let legacy = (try? c.decodeIfPresent(Int.self, forKey: .summaryEveryMinutes)) ?? d.summaryMinutes
        let minutes = (try? c.decodeIfPresent(Int.self, forKey: .summaryMinutes)) ?? (legacy > 0 ? legacy : d.summaryMinutes)
        summaryMinutes = Self.clampedMinutes(minutes)
        summaryAuto = (try? c.decodeIfPresent(Bool.self, forKey: .summaryAuto)) ?? (legacy > 0)
        summaryEveryMinutes = summaryAuto ? summaryMinutes : 0
        liveSummaryModel = (try? c.decodeIfPresent(SummaryModelChoice.self, forKey: .liveSummaryModel)) ?? d.liveSummaryModel
        meetingSummaryOnStop = (try? c.decodeIfPresent(Bool.self, forKey: .meetingSummaryOnStop)) ?? d.meetingSummaryOnStop
        meetingSummaryModel = (try? c.decodeIfPresent(SummaryModelChoice.self, forKey: .meetingSummaryModel)) ?? d.meetingSummaryModel
        saveMode = (try? c.decodeIfPresent(SaveMode.self, forKey: .saveMode)) ?? d.saveMode
        saveFolder = (try? c.decodeIfPresent(String.self, forKey: .saveFolder)) ?? d.saveFolder
        localServerURL = (try? c.decodeIfPresent(String.self, forKey: .localServerURL)) ?? d.localServerURL
        localServerModel = (try? c.decodeIfPresent(String.self, forKey: .localServerModel)) ?? d.localServerModel
        whisperURL = (try? c.decodeIfPresent(String.self, forKey: .whisperURL)) ?? d.whisperURL
        whisperModel = (try? c.decodeIfPresent(String.self, forKey: .whisperModel)) ?? d.whisperModel
        pauseWhenQuiet = (try? c.decodeIfPresent(Bool.self, forKey: .pauseWhenQuiet)) ?? d.pauseWhenQuiet
        stopAfterQuietMinutes = (try? c.decodeIfPresent(Int.self, forKey: .stopAfterQuietMinutes)) ?? d.stopAfterQuietMinutes
        speakerNames = (try? c.decodeIfPresent([String].self, forKey: .speakerNames)) ?? d.speakerNames
        autoSpeakers = (try? c.decodeIfPresent(Bool.self, forKey: .autoSpeakers)) ?? d.autoSpeakers
        glossary = (try? c.decodeIfPresent(String.self, forKey: .glossary)) ?? d.glossary
        alwaysOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)) ?? d.alwaysOnTop
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
        captionTheme = (try? c.decodeIfPresent(CaptionTheme.self, forKey: .captionTheme)) ?? d.captionTheme
        customHeard = (try? c.decodeIfPresent(String.self, forKey: .customHeard)) ?? d.customHeard
        customTranslation = (try? c.decodeIfPresent(String.self, forKey: .customTranslation)) ?? d.customTranslation
        customBackground = (try? c.decodeIfPresent(String.self, forKey: .customBackground)) ?? d.customBackground
        customMonospaced = (try? c.decodeIfPresent(Bool.self, forKey: .customMonospaced)) ?? d.customMonospaced
    }

    /// Where sessions are saved.
    var saveFolderURL: URL {
        saveFolder.isEmpty
            ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OwnVoice Meet")
            : URL(fileURLWithPath: saveFolder)
    }

    private static let key = "settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// API keys in the login Keychain, one generic password per provider.
enum Keychain {
    static let service = "OwnVoice Meet"

    static func get(_ provider: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static func set(_ provider: String, _ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
