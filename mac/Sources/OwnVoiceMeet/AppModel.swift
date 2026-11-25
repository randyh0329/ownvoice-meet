// The app's state: settings, caption lines, whether it is listening. Listening wires an audio
// source to a recognizer; each finished line goes to the translator.

import AVFoundation
import Foundation
import Observation
import OwnVoiceCore

@MainActor
@Observable
final class AppModel {
    /// The one model, for the app's whole life.
    static let shared = AppModel()

    var settings = AppSettings.load() {
        didSet { settings.save() }
    }

    // The Settings window's own state, kept here so it outlives its views.
    var appleCheck = ""
    var geminiKeyDraft = Keychain.get("gemini") ?? ""
    var anthropicKeyDraft = Keychain.get("anthropic") ?? ""
    var keysSaved = false
    var interfaceLanguage = InterfaceLanguage.current {
        didSet {
            interfaceLanguage.apply()
            languageChanged = true
        }
    }
    var languageChanged = false
    private(set) var book = CaptionBook()
    private(set) var isListening = false
    private(set) var status = String(localized: "Press Start to listen.")

    private var source: AudioSource?
    private var recognizer: Recognizer?
    private var translator: Translator?

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard !isListening else { return }
        let s = settings
        do {
            translator = try makeTranslator(s)
            recognizer = try makeRecognizer(s)
        } catch {
            status = error.localizedDescription
            return
        }
        isListening = true
        status = String(localized: "Starting…")
        let source = makeAudioSource(s.input)
        self.source = source
        let recognizer = self.recognizer!
        Task {
            do {
                // The model lives as long as the app.
                try await recognizer.start { event in
                    Task { @MainActor in self.handle(event) }
                }
                try await source.start { buffer in recognizer.feed(buffer) }
                if case .appleSpeech = s.listen { status = String(localized: "Listening (on this Mac)") }
            } catch {
                status = error.localizedDescription
                await teardown()
            }
        }
    }

    func stop() {
        guard isListening else { return }
        status = String(localized: "Stopped.")
        Task { await teardown() }
    }

    func clear() {
        book.clear()
    }

    private func teardown() async {
        source?.stop()
        source = nil
        await recognizer?.stop()
        recognizer = nil
        isListening = false
    }

    private func makeRecognizer(_ s: AppSettings) throws -> Recognizer {
        switch s.listen {
        case .appleSpeech:
            return AppleSpeechRecognizer(language: s.meetingLanguage)
        case .geminiLive:
            guard let key = Keychain.get("gemini") else { throw AppError(String(localized: "Add a Gemini API key in Settings first.")) }
            return GeminiLiveRecognizer(key: key, language: s.meetingLanguage)
        }
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .partial(let text):
            book.partial(text)
        case .final(let text):
            if let id = book.finish(text) { translate(id) }
        case .status(let message):
            status = message
        }
    }

    private func translate(_ id: Int) {
        guard let translator, let text = book.heard(id) else { return }
        let context = book.context(before: id)
        Task {
            do {
                let zh = try await translator.translate(text, context: context)
                book.setTranslation(zh, for: id)
            } catch {
                book.setTranslation("〔\(error.localizedDescription)〕", for: id)
            }
        }
    }
}
