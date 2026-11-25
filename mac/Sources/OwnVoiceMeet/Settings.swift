// What the user chose, kept in UserDefaults; API keys in the Keychain, never in a file.

import Foundation
import OwnVoiceCore
import Security

enum ListenOption: String, CaseIterable, Codable, Identifiable {
    case appleSpeech = "apple-speech"
    case geminiLive = "gemini-live"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleSpeech: String(localized: "Apple on-device recognition (free, stays on the Mac)")
        case .geminiLive: String(localized: "Gemini 3.5 Transcribe Live (about US$0.54 an hour)")
        }
    }

    var detail: String {
        switch self {
        case .appleSpeech: String(localized: "macOS's own SpeechAnalyzer: recognized on the Mac, with gray text while someone speaks. The first time, the language's model is downloaded. Needs the meeting language chosen.")
        case .geminiLive: String(localized: "Google's live transcription, steadier in a noisy room. Needs a Gemini API key (use the paid tier: free-tier data is used to improve Google's products).")
        }
    }
}

enum TranslateOption: String, CaseIterable, Codable, Identifiable {
    case apple = "apple-translate"
    case haiku = "claude-haiku-5-5"
    case geminiFlashLite = "gemini-3.5-flash-lite"
    case gemma = "gemma4-e4b"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: String(localized: "Apple Translation (on-device, free)")
        case .haiku: String(localized: "Claude Haiku 5.5 (about US$0.03 an hour)")
        case .geminiFlashLite: String(localized: "Gemini 3.5 Flash-Lite (about US$0.13 an hour)")
        case .gemma: String(localized: "Gemma 4 E4B (local Ollama, free)")
        }
    }

    var detail: String {
        switch self {
        case .apple: String(localized: "macOS's own translation: Chinese appears almost at once. Line by line, without the earlier lines or the glossary. Download the languages first in System Settings → General → Language & Region → Translation Languages.")
        case .haiku: String(localized: "Uses the earlier lines and the glossary; steady wording. Needs an Anthropic API key.")
        case .geminiFlashLite: String(localized: "Uses the earlier lines and the glossary; shares the key with Gemini recognition.")
        case .gemma: String(localized: "Google's open model running on the Mac: free, text stays on the computer. Install Ollama and run ollama pull gemma4:e4b first. A small model: wording is rougher than the cloud models.")
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

/// Languages offered for the meeting (BCP-47). Apple recognition needs one chosen.
struct MeetingLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }

    static let all = [
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
    /// Minutes between summary updates; 0 = only when asked.
    var summaryEveryMinutes = 5
    var saveMode: SaveMode = .off
    /// Empty: Documents/OwnVoice Meet.
    var saveFolder = ""
    var glossary = ""
    var alwaysOnTop = true
    var fontSize = 20.0

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
        summaryEveryMinutes = (try? c.decodeIfPresent(Int.self, forKey: .summaryEveryMinutes)) ?? d.summaryEveryMinutes
        saveMode = (try? c.decodeIfPresent(SaveMode.self, forKey: .saveMode)) ?? d.saveMode
        saveFolder = (try? c.decodeIfPresent(String.self, forKey: .saveFolder)) ?? d.saveFolder
        glossary = (try? c.decodeIfPresent(String.self, forKey: .glossary)) ?? d.glossary
        alwaysOnTop = (try? c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)) ?? d.alwaysOnTop
        fontSize = (try? c.decodeIfPresent(Double.self, forKey: .fontSize)) ?? d.fontSize
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
