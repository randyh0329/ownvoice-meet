// The app's state: settings, caption lines, listening, and the windows around them (reply,
// script, summary). Listening wires an audio source to a recognizer; each finished line goes to
// the translator, into the session record (transcript, summary, recording) and the summary.
// No @State in the views (see App.swift): what a window keeps lives here.

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
    private(set) var book = CaptionBook()
    private(set) var isListening = false
    private(set) var status = String(localized: "Press Start to listen.")

    // Settings window
    var settingsTab: SettingsTab = .listen
    let gemma = GemmaSetup()
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

    // Reply window
    var replyInput = ""
    private(set) var replyChinese = ""
    private(set) var replyText = ""
    private(set) var replyWorking = false

    // Script window
    var script = ScriptFile.load() {
        didSet { ScriptFile.save(script) }
    }
    var scriptEditing = false
    private(set) var scriptWorking = false
    private(set) var scriptMessage = ""

    // Summary window
    private(set) var summary = ""
    private(set) var summaryUpdated = ""
    private(set) var summaryWorking = false
    private(set) var summaryError = ""

    private var source: AudioSource?
    private var recognizer: Recognizer?
    private var translator: Translator?
    private(set) var record: SessionRecord?
    private var lastSummary = Date()
    private var ticker: Task<Void, Never>?
    /// Lines whose final translation is in: a late streamed piece must not overwrite it.
    private var translated: Set<Int> = []

    // MARK: Listening

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard !isListening else { return }
        let s = settings
        let recognizer: Recognizer
        do {
            translator = try makeTranslator(s, script: script)
            recognizer = try makeRecognizer(s)
            record = try SessionRecord(settings: s, recognition: s.listen.label, translation: s.translate.label)
        } catch {
            status = error.localizedDescription
            return
        }
        self.recognizer = recognizer
        isListening = true
        status = String(localized: "Starting…")
        lastSummary = Date()
        let source = makeAudioSource(s.input)
        self.source = source
        let recorder = record?.audioRecorder
        let silence = s.input == .system ? SilenceWatch(after: 10) {
            Task { @MainActor in
                self.status = String(localized: "No sound from the Mac yet. Play something; if it stays silent, allow OwnVoice Meet in System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then quit and reopen it.")
            }
        } : nil
        Task {
            do {
                try await recognizer.start { event in
                    Task { @MainActor in self.handle(event) }
                }
                try await source.start { buffer in
                    silence?.feed(buffer)
                    recognizer.feed(buffer)
                    recorder?.write(buffer)
                }
                if case .appleSpeech = s.listen { status = String(localized: "Listening (on this Mac)") }
                if let folder = record?.folder { status += " · " + String(localized: "Saving to \(folder.path)") }
                startTicker()
            } catch {
                status = error.localizedDescription
                await teardown()
            }
        }
    }

    func stop() {
        guard isListening else { return }
        status = String(localized: "Stopped.")
        Task {
            await teardown()
            await updateSummary(force: true)
            record?.close()
        }
    }

    func clear() {
        book.clear()
        translated.removeAll()
        summary = ""
        summaryUpdated = ""
        summaryError = ""
    }

    private func teardown() async {
        ticker?.cancel()
        ticker = nil
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

    /// Every few seconds while listening: write the transcript, and bring the summary up to date
    /// when its interval has passed.
    private func startTicker() {
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                record?.writeIfChanged()
                let every = settings.summaryEveryMinutes
                if every > 0, Date().timeIntervalSince(lastSummary) >= Double(every * 60), (record?.forSummary.count ?? 0) >= 3 {
                    await updateSummary(force: false)
                }
            }
        }
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .partial(let text):
            if let id = book.partial(text) { record?.opened(id) }
        case .final(let text):
            if let id = book.finish(text) {
                record?.finished(id, heard: book.heard(id) ?? text)
                translate(id)
            }
        case .status(let message):
            status = message
        }
    }

    private func translate(_ id: Int) {
        guard let translator, let text = book.heard(id) else { return }
        let context = book.context(before: id)
        Task {
            do {
                let zh = try await translator.translate(text, context: context) { soFar in
                    Task { @MainActor in
                        if !self.translated.contains(id) { self.book.setTranslation(soFar, for: id) }
                    }
                }
                translated.insert(id)
                book.setTranslation(zh, for: id)
                record?.translated(id, zh)
            } catch {
                translated.insert(id)
                book.setTranslation("〔\(error.localizedDescription)〕", for: id)
                record?.translated(id, "")
            }
        }
    }

    /// The finished lines before the newest, for replies.
    private var recentLines: [String] {
        Array(book.lines.filter(\.isFinal).suffix(8).map(\.heard))
    }

    // MARK: Reply

    func sendReply() {
        let zh = replyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zh.isEmpty, !replyWorking else { return }
        replyInput = ""
        replyChinese = zh
        replyText = ""
        let s = settings
        let model: TextModel
        do { model = try makeTextModel(s) } catch {
            replyText = "〔\(error.localizedDescription)〕"
            return
        }
        replyWorking = true
        let system = Prompts.withGlossary(Assistants.replySystem(language: Assistants.languageName(s.speakLanguage), variant: s.chinese), glossary: s.glossary)
        let user = Assistants.replyUser(context: recentLines, chinese: zh)
        let script = self.script
        Task {
            do {
                let text = try await model.stream(system: system, user: user, script: script, maxTokens: 800) { soFar in
                    Task { @MainActor in if self.replyChinese == zh && self.replyWorking { self.replyText = soFar } }
                }
                if replyChinese == zh { replyText = text }
            } catch {
                if replyChinese == zh { replyText = "〔\(error.localizedDescription)〕" }
            }
            replyWorking = false
        }
    }

    // MARK: Summary

    /// Bring the summary up to date with the lines since the last time (`force`: even a few).
    func updateSummary(force: Bool) async {
        guard !summaryWorking, let record else { return }
        let lines = record.takeForSummary()
        guard !lines.isEmpty, force || lines.count >= 3 else {
            record.giveBack(lines)
            return
        }
        let s = settings
        let model: TextModel
        do { model = try makeTextModel(s) } catch {
            summaryError = error.localizedDescription
            record.giveBack(lines)
            return
        }
        summaryWorking = true
        summaryError = ""
        lastSummary = Date()
        let system = Prompts.withGlossary(Assistants.summarySystem(s.chinese), glossary: s.glossary)
        let user = Assistants.summaryUser(before: summary, transcript: SessionFiles.forSummary(lines, clock: record.clock))
        do {
            let text = s.chinese.fix(try await model.stream(system: system, user: user, script: script, maxTokens: 1500) { _ in })
            guard !text.isEmpty else { throw AppError(String(localized: "The model returned nothing.")) }
            summary = text
            let time = record.clock(Date().timeIntervalSince(record.started))
            summaryUpdated = String(localized: "Updated \(time)")
            record.writeSummary(text, updated: summaryUpdated)
        } catch {
            summaryError = String(localized: "Summary failed: \(error.localizedDescription)")
            record.giveBack(lines)
        }
        summaryWorking = false
    }

    // MARK: Script

    func insertTemplate() {
        script = script.isEmpty ? Script.template : script + "\n" + Script.template
        scriptEditing = true
    }

    /// 補對照: fill in the missing half of each line.
    func fillScript() async {
        let needs = Script.plan(script)
        guard !needs.isEmpty else {
            scriptMessage = String(localized: "Every line already has both halves.")
            return
        }
        let s = settings
        let model: TextModel
        do { model = try makeTextModel(s) } catch {
            scriptMessage = error.localizedDescription
            return
        }
        scriptWorking = true
        scriptMessage = String(localized: "Filling in \(String(needs.count)) lines with \(model.name)…")
        let original = script
        let system = Assistants.glossSystem(language: Assistants.languageName(s.speakLanguage), variant: s.chinese)
        do {
            var answers: [String] = []
            for start in stride(from: 0, to: needs.count, by: 40) {
                let batch = Array(needs[start..<min(start + 40, needs.count)])
                let text = try await model.stream(system: system, user: Script.request(batch), script: "", maxTokens: 4000) { _ in }
                answers += try Script.answers(text, expect: batch.count)
            }
            guard script == original else {
                throw AppError(String(localized: "The script changed while filling in; try again."))
            }
            script = Script.merge(original, needs: needs, answers: answers, variant: s.chinese)
            scriptMessage = String(localized: "Filled in \(String(needs.count)) lines.")
        } catch Script.GlossError.notAList {
            scriptMessage = String(localized: "The model did not answer with a list; try again.")
        } catch Script.GlossError.wrongCount {
            scriptMessage = String(localized: "The model answered the wrong number of lines; try again.")
        } catch {
            scriptMessage = error.localizedDescription
        }
        scriptWorking = false
    }
}

/// The script, kept as script.md in Application Support so it is there next time.
enum ScriptFile {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OwnVoice Meet")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("script.md")
    }

    static func load() -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    static func save(_ text: String) {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
