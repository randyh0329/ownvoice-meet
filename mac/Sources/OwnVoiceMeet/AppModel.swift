// The app's state: settings, caption lines, listening, and the windows around them (reply,
// script, summary, usage). Listening wires an audio source to a recognizer; each finished line goes
// to the translator (or comes translated, with Live Translate), into the session record (transcript,
// summary, recording) and the summary. Cloud recognition pauses while the room is quiet, and
// listening stops after a long quiet. No @State in the views (see App.swift): what a window keeps
// lives here.

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
        didSet {
            settings.save()
            if settings.speakerNames != oldValue.speakerNames { record?.speakerNames = settings.speakerNames }
        }
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
    var openAIKeyDraft = Keychain.get("openai") ?? ""
    var localKeyDraft = Keychain.get("local") ?? ""
    var keysSaved = false
    var interfaceLanguage = InterfaceLanguage.current {
        didSet {
            interfaceLanguage.apply()
            languageChanged = true
        }
    }
    var languageChanged = false
    var updateMessage = ""
    var updateURL: URL?

    // Usage: this session's, and this month's (kept between launches).
    private(set) var sessionUsage = UsageBook()
    private(set) var monthUsage = UsageStore.load()

    // Speakers: who is speaking now (an index into settings.speakerNames).
    private(set) var currentSpeaker: Int?
    let speakerModels = SpeakerModels()
    private var detector: SpeakerDetector?
    /// Voices (the detector's clusters) → speakers in the list. Naming one line names its voice.
    private var voiceSpeaker: [Int: Int] = [:]
    /// The voice each line was heard in, and the lines the user labelled by hand.
    private var lineVoice: [Int: Int] = [:]
    private var labelledByHand: Set<Int> = []
    /// When each line was heard, on the session's clock: (from, to).
    private var lineTimes: [Int: (from: TimeInterval, to: TimeInterval?)] = [:]
    var speakerPrompt = false
    var speakerDraft = ""

    // Undo: the caption and script windows' own undo managers (⌘Z, Edit menu), set by their views.
    @ObservationIgnored weak var captionsUndo: UndoManager?
    @ObservationIgnored weak var scriptUndo: UndoManager?

    // Segments
    var segmentPrompt = false
    var segmentDraft = ""
    private(set) var segmentName = ""

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
    var summaryPane: SummaryPane = .live
    private(set) var minutes = ""
    private(set) var minutesNote = ""
    private(set) var minutesWorking = false
    /// The session that ended last, kept for "Summarize Whole Meeting" afterwards.
    private(set) var lastRecord: SessionRecord?
    private(set) var summary = ""
    private(set) var summaryUpdated = ""
    private(set) var summaryWorking = false
    private(set) var summaryError = ""

    private var source: AudioSource?
    private var recognizer: Recognizer?
    private var translator: Translator?
    private(set) var record: SessionRecord?
    private var gate: QuietGate?
    /// When the live summary was last brought up to date (or the session started).
    private var lastSummary = Date()
    /// After a failed update: when to try again, sooner than a whole interval.
    private var summaryRetryAt: Date?
    private var ticker: Task<Void, Never>?
    /// Bumped by every start and teardown: a start still in progress backs out when it changed.
    private var generation = 0
    /// The session whose recognizer events are taken: kept through finishing (the last sentence
    /// flushed at stop still arrives), cleared once the session has ended.
    private var eventSession = -1
    /// The last session is still finishing (final summary, last translations): no new start yet.
    private(set) var finishing = false
    /// Translations on their way, waited for (briefly) before the session record closes.
    private var inFlight: [Int: Task<Void, Never>] = [:]
    private var usageMonth = UsageBook.month(Date())
    /// Lines whose final translation is in: a late streamed piece must not overwrite it.
    private var translated: Set<Int> = []
    /// The recognition this session started with.
    private var sessionListen = ListenOption.appleSpeech
    /// Live Translate's own line numbers → caption lines.
    private var interpLines: [Int: Int] = [:]
    /// Each line's translations, early and final, numbered so an older one never overwrites a newer.
    private var lineTranslations = LineTranslations()
    /// Early translations on their way: line → request number → task.
    private var earlyTasks: [Int: [Int: Task<Void, Never>]] = [:]

    // MARK: Listening

    func toggle() {
        if isListening { stop() } else { start() }
    }

    func start() {
        guard !isListening else { return }
        guard !finishing else {
            status = String(localized: "Still finishing the last session; try again in a moment.")
            return
        }
        let s = settings
        let recognizer: Recognizer?
        do {
            // Live Translate translates itself; record-only translates nothing.
            let translatesItself = s.listen == .geminiLiveTranslate || s.listen == .recordOnly
            translator = translatesItself ? nil : try makeTranslator(s, script: script) { model, tokens in
                Task { @MainActor in self.addTokens(model, tokens) }
            }
            recognizer = try makeRecognizer(s)
            record = try SessionRecord(settings: s, recognition: s.listen.label, translation: translatesItself ? s.listen.label : s.translate.label, keepSound: s.listen == .recordOnly)
            record?.speakerNames = s.speakerNames
        } catch {
            status = error.localizedDescription
            return
        }
        self.recognizer = recognizer
        sessionListen = s.listen
        isListening = true
        generation += 1
        let session = generation
        eventSession = session
        status = String(localized: "Starting…")
        segmentName = ""
        lastSummary = Date()
        summaryRetryAt = nil
        interpLines.removeAll()
        inFlight.removeAll()
        cancelEarlyTranslations()
        book.speaker = currentSpeaker
        voiceSpeaker.removeAll()
        lineVoice.removeAll()
        labelledByHand.removeAll()
        lineTimes.removeAll()
        let detectVoices = s.autoSpeakers && speakerModels.ready && s.listen != .recordOnly
        if detectVoices { pruneUnnamedSpeakers() }
        // A new meeting: its summary and its usage start from nothing.
        summary = ""
        summaryUpdated = ""
        summaryError = ""
        minutes = ""
        minutesNote = ""
        sessionUsage = UsageBook()
        let source = makeAudioSource(s.input)
        self.source = source
        let recorder = record?.audioRecorder
        let gate = QuietGate()
        self.gate = gate
        let silence = s.input == .system ? SilenceWatch(after: 10) {
            Task { @MainActor in
                self.status = String(localized: "No sound from the Mac yet. Play something; if it stays silent, allow OwnVoice Meet in System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then quit and reopen it.")
            }
        } : nil
        Task {
            do {
                try await recognizer?.start { event in
                    Task { @MainActor in
                        // Events of a session that has ended (a late status, say) are not shown.
                        if self.eventSession == session { self.handle(event) }
                    }
                }
                // Stop was pressed while the recognizer was starting (a model download, a prompt).
                guard generation == session else {
                    await recognizer?.stop()
                    return
                }
                let started = record?.started ?? Date()
                let detector: SpeakerDetector? = detectVoices
                    ? await Task.detached { SpeakerDetector(sessionStart: started) }.value
                    : nil
                if detectVoices, detector == nil { status = String(localized: "The voice models could not be loaded; speakers are not told apart.") }
                self.detector = detector
                try await source.start { buffer in
                    silence?.feed(buffer)
                    for admitted in gate.admit(buffer) { recognizer?.feed(admitted) }
                    detector?.feed(buffer)
                    recorder?.write(buffer)
                }
                guard generation == session else {
                    source.stop()
                    await recognizer?.stop()
                    return
                }
                switch s.listen {
                case .appleSpeech: status = String(localized: "Listening (on this Mac)")
                case .recordOnly: status = String(localized: "Recording only, no captions")
                default: break
                }
                if let folder = record?.folder { status += " · " + String(localized: "Saving to \(folder.path)") }
                startTicker()
            } catch {
                source.stop()
                guard generation == session else { return }
                let message = error.localizedDescription
                // The record opened for this session is closed too (its folder, its recording).
                await finishSession()
                status = message
            }
        }
    }

    func stop() {
        guard isListening else { return }
        status = String(localized: "Stopped.")
        Task { await finishSession() }
    }

    /// Ends the session: stops listening, waits briefly for translations on their way, writes the
    /// final summary, closes the record. Works on the session's own record even if another starts.
    private func finishSession() async {
        guard !finishing else { return }
        finishing = true
        let record = self.record
        await teardown()
        // The recognizer's last events (dispatched as it stopped) run first, then the translations
        // they started get up to 8 seconds in all.
        try? await Task.sleep(for: .milliseconds(300))
        let deadline = Date().addingTimeInterval(8)
        while let task = inFlight.values.first, deadline.timeIntervalSinceNow > 0 {
            await waitAtMost(seconds: deadline.timeIntervalSinceNow, for: task)
            try? await Task.sleep(for: .milliseconds(50))
        }
        inFlight.removeAll()
        cancelEarlyTranslations()
        // "Only when I press Update Now" means no summary at stop either. One already being written
        // (Update Now pressed just before) is waited for, up to a minute, so the last lines still go in.
        if let record, summaryInterval != nil {
            let until = Date().addingTimeInterval(60)
            while summaryWorking, Date() < until { try? await Task.sleep(for: .milliseconds(200)) }
            await summarize(force: true, record: record)
        }
        record?.close()
        lastRecord = record
        eventSession = -1
        finishing = false
        // The minutes come after: they may take a while and do not hold up a new start.
        if settings.meetingSummaryOnStop, let record {
            Task { await self.summarizeMeeting(record) }
        }
    }

    /// The app is quitting: the session ends as at Stop, given up to 15 seconds for its final
    /// summary; then, whatever still runs, the files are closed (the recording playable).
    func prepareToQuit() async {
        if isListening {
            let task = Task { await self.finishSession() }
            await waitAtMost(seconds: 15, for: task)
        }
        let deadline = Date().addingTimeInterval(15)
        while finishing, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        record?.close()
    }

    func clear() {
        let before = captionsState
        book.clear()
        book.speaker = currentSpeaker
        // Live Translate's lines still on their way keep their numbers: they are still written to
        // the transcript when they finish, just not shown.
        summary = ""
        summaryUpdated = ""
        summaryError = ""
        registerCaptionsUndo(before, String(localized: "Clear Captions"))
    }

    // MARK: Undo

    /// What the caption window shows and Undo can bring back: lines, summary, speakers.
    struct CaptionsState {
        var book: CaptionBook
        var translated: Set<Int>
        var summary: String
        var summaryUpdated: String
        var speakerNames: [String]
        var currentSpeaker: Int?
        var voiceSpeaker: [Int: Int]
    }

    private var captionsState: CaptionsState {
        CaptionsState(book: book, translated: translated, summary: summary, summaryUpdated: summaryUpdated, speakerNames: settings.speakerNames, currentSpeaker: currentSpeaker, voiceSpeaker: voiceSpeaker)
    }

    /// Puts `state` back, and registers the way back again (so Redo works). Lines that came in
    /// after the change stay (CaptionBook.adopt); a summary written since is kept.
    private func apply(_ state: CaptionsState, _ action: String) {
        let now = captionsState
        book.adopt(state.book)
        translated.formUnion(state.translated)
        if summary.isEmpty {
            summary = state.summary
            summaryUpdated = state.summaryUpdated
        }
        settings.speakerNames = state.speakerNames
        currentSpeaker = state.currentSpeaker
        voiceSpeaker = state.voiceSpeaker
        book.speaker = currentSpeaker
        record?.adoptSpeakers(book.lines)
        registerCaptionsUndo(now, action)
    }

    private func registerCaptionsUndo(_ state: CaptionsState, _ action: String) {
        guard let undo = captionsUndo else { return }
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(state, action) }
        }
        undo.setActionName(action)
    }

    /// Replaces the script, undoably (補對照, the template, a file opened).
    func setScript(_ text: String, action: String) {
        let before = script
        script = text
        guard let undo = scriptUndo else { return }
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setScript(before, action: action) }
        }
        undo.setActionName(action)
    }

    // MARK: Speakers told apart by voice

    private var sessionClock: TimeInterval { Date().timeIntervalSince(record?.started ?? Date()) }

    /// The first words of a line reach the screen a moment after they were said: its time starts
    /// 1.5 s earlier.
    private func heardFrom(_ id: Int) {
        if lineTimes[id] == nil { lineTimes[id] = (max(0, sessionClock - 1.5), nil) }
    }

    /// The line ended: once the detector has printed its stretch, the line takes that voice's speaker.
    private func heardTo(_ id: Int) {
        let now = sessionClock
        lineTimes[id] = (lineTimes[id]?.from ?? max(0, now - 3), now)
        guard let detector, let times = lineTimes[id], let to = times.to else { return }
        Task {
            // A stretch is printed only when it ends (a pause, or 10 s), often after the line's words.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(1500))
                if let voice = await detector.speaker(from: times.from, to: to) {
                    labelLine(id, voice: voice)
                    return
                }
            }
        }
    }

    private func labelLine(_ id: Int, voice: Int) {
        lineVoice[id] = voice
        guard !labelledByHand.contains(id), book.line(id) != nil else { return }
        let speaker: Int
        if let known = voiceSpeaker[voice] {
            speaker = known
        } else {
            // A new voice: a new speaker, unnamed ("Speaker 3") until the user names one of its lines.
            settings.speakerNames.append("")
            speaker = settings.speakerNames.count - 1
            voiceSpeaker[voice] = speaker
        }
        book.setSpeaker(speaker, for: id)
        record?.adoptSpeakers(book.lines)
    }

    /// Before a session that tells voices apart: unnamed speakers no line uses are dropped, so the
    /// list does not grow by a meeting's worth of "Speaker n" each time.
    private func pruneUnnamedSpeakers() {
        let used = Set(book.lines.compactMap(\.speaker))
        for i in settings.speakerNames.indices.reversed()
        where settings.speakerNames[i].trimmingCharacters(in: .whitespaces).isEmpty && !used.contains(i) && i != currentSpeaker {
            settings.speakerNames.remove(at: i)
            for line in book.lines {
                if let s = line.speaker, s > i { book.setSpeaker(s - 1, for: line.id) }
            }
            if let c = currentSpeaker, c > i { setCurrentSpeaker(c - 1) }
        }
    }

    // MARK: Speakers

    /// The name of speaker `i` ("Speaker 2" while unnamed), nil for none.
    func speakerName(_ i: Int?) -> String? {
        guard let i, i < settings.speakerNames.count else { return nil }
        let n = settings.speakerNames[i].trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String(localized: "Speaker \(String(i + 1))") : n
    }

    /// Who is speaking now: new lines get this speaker.
    func setCurrentSpeaker(_ i: Int?) {
        currentSpeaker = i
        book.speaker = i
    }

    func askAddSpeaker() {
        speakerDraft = ""
        speakerPrompt = true
    }

    /// Adds a speaker (from the prompt) and makes them the one speaking now.
    func confirmAddSpeaker() {
        let before = captionsState
        let name = speakerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.speakerNames.append(name.isEmpty ? String(localized: "Speaker \(String(settings.speakerNames.count + 1))") : name)
        setCurrentSpeaker(settings.speakerNames.count - 1)
        registerCaptionsUndo(before, String(localized: "Add Speaker"))
    }

    /// Says who said line `id`.
    func assignSpeaker(_ i: Int?, to id: Int) {
        guard book.line(id)?.speaker != i else { return }
        let before = captionsState
        book.setSpeaker(i, for: id)
        labelledByHand.insert(id)
        // Naming a line names its voice: every line of that voice follows, earlier and later.
        if let i, let voice = lineVoice[id] {
            voiceSpeaker[voice] = i
            for (line, v) in lineVoice where v == voice && !labelledByHand.contains(line) {
                book.setSpeaker(i, for: line)
            }
        }
        record?.adoptSpeakers(book.lines)
        registerCaptionsUndo(before, String(localized: "Set Speaker"))
    }

    /// Removes speaker `i`: their lines lose the name; later speakers move up one place.
    func removeSpeaker(at i: Int) {
        guard i < settings.speakerNames.count else { return }
        let before = captionsState
        settings.speakerNames.remove(at: i)
        for line in book.lines {
            guard let s = line.speaker else { continue }
            if s == i { book.setSpeaker(nil, for: line.id) } else if s > i { book.setSpeaker(s - 1, for: line.id) }
        }
        if let c = currentSpeaker { setCurrentSpeaker(c == i ? nil : (c > i ? c - 1 : c)) }
        voiceSpeaker = voiceSpeaker.compactMapValues { s in s == i ? nil : (s > i ? s - 1 : s) }
        // Every line of the transcript, not only those on screen.
        record?.removeSpeaker(at: i)
        record?.adoptSpeakers(book.lines)
        registerCaptionsUndo(before, String(localized: "Remove Speaker"))
    }

    private func teardown() async {
        generation += 1
        let ticker = self.ticker
        self.ticker = nil
        ticker?.cancel()
        // The sound and the recognizer stop at once, even with a summary being written.
        source?.stop()
        source = nil
        await recognizer?.stop()
        recognizer = nil
        // The stretch still going on is printed; lines waiting for their voice keep the detector.
        detector?.finish()
        detector = nil
        gate = nil
        isListening = false
        // A summary the ticker started runs to its end (it does not inherit the cancellation) and
        // is waited for, so the final summary is not skipped.
        await ticker?.value
    }

    private func makeRecognizer(_ s: AppSettings) throws -> Recognizer? {
        func key(_ provider: String, _ missing: String) throws -> String {
            guard let k = Keychain.get(provider) else { throw AppError(missing) }
            return k
        }
        let gemini = String(localized: "Add a Gemini API key in Settings first.")
        let openAI = String(localized: "Add an OpenAI API key in Settings first.")
        // The glossary's names and terms help recognition too.
        let terms = Prompts.recognitionTerms(glossary: s.glossary)
        switch s.listen {
        case .appleSpeech: return AppleSpeechRecognizer(language: s.meetingLanguage, terms: terms)
        case .geminiLive: return GeminiLiveRecognizer(key: try key("gemini", gemini), language: s.meetingLanguage, terms: terms)
        case .geminiLiveTranslate: return GeminiLiveTranslateRecognizer(key: try key("gemini", gemini), chinese: s.chinese, glossary: s.glossary)
        case .geminiTranscribe: return SentenceRecognizer(service: .gemini(key: try key("gemini", gemini)), language: s.meetingLanguage, terms: terms)
        case .openaiLive: return OpenAILiveRecognizer(key: try key("openai", openAI), language: s.meetingLanguage, terms: terms)
        case .openaiMini: return SentenceRecognizer(service: .openAI(key: try key("openai", openAI)), language: s.meetingLanguage, terms: terms)
        case .localWhisper: return SentenceRecognizer(service: .whisper(base: s.whisperURL, model: s.whisperModel, key: Keychain.get("local")), language: s.meetingLanguage, terms: terms)
        case .recordOnly: return nil
        }
    }

    /// Every few seconds while listening: write the transcript; bring the summary up to date when
    /// its interval has passed; pause cloud recognition in a quiet room; stop after a long quiet.
    private func startTicker() {
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                record?.writeIfChanged()
                let s = settings
                if let next = nextSummaryAt, Date() >= next, summaryLinesMissing == 0 {
                    // Its own task: stopping cancels the ticker, not a summary half written.
                    await Task { await self.updateSummary(force: false) }.value
                }
                guard let gate else { continue }
                if gate.takeResumed() {
                    status = String(localized: "Someone is speaking: recognition is back on.")
                }
                let quiet = gate.quietFor
                if s.listen.isCloud, s.pauseWhenQuiet, quiet >= 60, !gate.isPaused {
                    gate.pause()
                    status = String(localized: "Quiet: recognition paused (nothing is billed); it comes back when someone speaks.")
                }
                if s.stopAfterQuietMinutes > 0, quiet >= Double(s.stopAfterQuietMinutes * 60) {
                    let minutes = String(s.stopAfterQuietMinutes)
                    // From outside this task: finishing cancels the ticker, which must not cancel
                    // the final summary with it.
                    Task {
                        await self.finishSession()
                        self.status = String(localized: "Stopped after \(minutes) minutes of quiet.")
                    }
                    return
                }
            }
        }
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .partial, .final, .lineHeard: gate?.speechHeard()
        default: break
        }
        switch event {
        case .partial(let text):
            if let id = book.partial(text) {
                record?.opened(id, speaker: book.line(id)?.speaker)
                heardFrom(id)
                translateEarly(id)
            }
        case .final(let text):
            if let id = book.finish(text) {
                record?.opened(id, speaker: book.line(id)?.speaker)
                record?.finished(id, heard: book.heard(id) ?? text)
                heardTo(id)
                translate(id)
            } else {
                // The sentence came to nothing: an early translation of it still running is cancelled.
                for id in lineTranslations.dropUnfinished() { cancelEarly(id) }
            }
        case .status(let message):
            status = message
        case .audio(let seconds):
            // Priced as the recognizer of this session, even if Settings changed since.
            addAudio(sessionListen.rawValue, seconds)
        case .lineOpened(let n):
            let id = book.openLine()
            interpLines[n] = id
            record?.opened(id, speaker: book.line(id)?.speaker)
            heardFrom(id)
        case let .lineHeard(n, text, done):
            guard let id = interpLines[n] else { return }
            book.setHeard(text, for: id, final: done)
            if done {
                record?.finished(id, heard: text)
                heardTo(id)
            }
        case let .lineTranslated(n, text, done):
            guard let id = interpLines[n] else { return }
            let zh = settings.chinese.fix(text)
            book.setTranslation(zh, for: id)
            // Kept after done: Chinese that comes after a line is complete still joins it.
            if done {
                translated.insert(id)
                record?.translated(id, zh)
            }
        case .lineDropped(let n):
            if let id = interpLines.removeValue(forKey: n) { book.removeLine(id) }
        }
    }

    private func translate(_ id: Int) {
        guard let translator, let text = book.heard(id) else { return }
        let context = book.context(before: id)
        let record = self.record
        // The final translation cancels the early ones still running; its streamed Chinese takes
        // over the line once it is as long as the early Chinese shown.
        let (seq, cancelled) = lineTranslations.start(id, text: text, early: false, now: Date())
        cancelRequests(id, cancelled)
        inFlight[id] = Task {
            defer {
                inFlight[id] = nil
                requestEnded(id, seq: seq)
            }
            do {
                let zh = try await translator.translate(text, context: context) { soFar in
                    Task { @MainActor in
                        if !self.translated.contains(id) { self.showTranslation(soFar, for: id, seq: seq, early: false) }
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

    // MARK: Early translation

    /// A long sentence still being spoken is translated as it stands (LineTranslations decides
    /// when), so its Chinese starts to show before the speaker pauses. Only where there is a
    /// translator (not Live Translate or record only) and only when turned on in Settings.
    private func translateEarly(_ id: Int) {
        guard settings.earlyTranslation, let translator, let text = book.heard(id) else { return }
        let now = Date()
        lineTranslations.opened(id, at: now)
        guard lineTranslations.wantsEarly(id, text: text, now: now) else { return }
        let (seq, cancelled) = lineTranslations.start(id, text: text, early: true, now: now)
        cancelRequests(id, cancelled)
        let context = book.context(before: id)
        earlyTasks[id, default: [:]][seq] = Task {
            defer { requestEnded(id, seq: seq) }
            // One that fails shows nothing: the final translation will come.
            guard let zh = try? await translator.translateUnfinished(text, context: context, partial: { soFar in
                Task { @MainActor in self.showTranslation(soFar, for: id, seq: seq, early: true) }
            }) else { return }
            showTranslation(zh, for: id, seq: seq, early: true, complete: true)
        }
    }

    /// Request `seq`'s Chinese goes under line `id` if it should be there (LineTranslations.accept);
    /// an early one only if it reads as a subtitle.
    private func showTranslation(_ zh: String, for id: Int, seq: Int, early: Bool, complete: Bool = false) {
        if early && !LineTranslations.readsAsSubtitle(zh) { return }
        let result = lineTranslations.accept(id, seq: seq, length: zh.count, complete: complete)
        cancelRequests(id, result.cancelled)
        if result.shown { book.setTranslation(zh, for: id) }
    }

    private func cancelRequests(_ id: Int, _ seqs: [Int]) {
        for seq in seqs { earlyTasks[id]?.removeValue(forKey: seq)?.cancel() }
    }

    private func requestEnded(_ id: Int, seq: Int) {
        lineTranslations.done(id, seq: seq)
        earlyTasks[id]?[seq] = nil
        if earlyTasks[id]?.isEmpty == true { earlyTasks[id] = nil }
    }

    private func cancelEarly(_ id: Int) {
        earlyTasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
    }

    /// A new session, or the end of one: nothing early is still worth translating.
    private func cancelEarlyTranslations() {
        for tasks in earlyTasks.values { tasks.values.forEach { $0.cancel() } }
        earlyTasks.removeAll()
        lineTranslations = LineTranslations()
    }

    // MARK: Segments

    func askNewSegment() {
        guard isListening else { return }
        segmentDraft = ""
        segmentPrompt = true
    }

    func confirmSegment() {
        let name = segmentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let record else { return }
        let n = record.newSegment(name)
        segmentName = n
        status = String(localized: "New segment: \(n)")
    }

    // MARK: Usage

    /// A new month starts its record from nothing, even with the app left open across it.
    private func rollMonth() {
        let month = UsageBook.month(Date())
        guard month != usageMonth else { return }
        usageMonth = month
        monthUsage = UsageStore.load()
    }

    private func addAudio(_ model: String, _ seconds: Double) {
        rollMonth()
        sessionUsage.addAudio(model, seconds: seconds)
        monthUsage.addAudio(model, seconds: seconds)
        UsageStore.save(monthUsage)
    }

    private func addTokens(_ model: String, _ tokens: Tokens) {
        rollMonth()
        sessionUsage.addTokens(model, tokens)
        monthUsage.addTokens(model, tokens)
        UsageStore.save(monthUsage)
    }

    func resetUsage() {
        sessionUsage = UsageBook()
        monthUsage = UsageBook()
        UsageStore.save(monthUsage)
    }

    // MARK: Updates

    /// Asks GitHub (only when the user presses the button) for this fork's latest release.
    func checkForUpdates() async {
        updateMessage = String(localized: "Checking…")
        updateURL = nil
        let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        // The newest release of this app (mac-v…), not of the cross-platform one in the same repo.
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/randyh0329/ownvoice-meet/releases?per_page=30")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let releases = (status == 200 ? try JSONSerialization.jsonObject(with: data) as? [[String: Any]] : nil) ?? []
            let mac = releases.first { r in
                (r["tag_name"] as? String)?.hasPrefix("mac-v") == true && r["draft"] as? Bool != true && r["prerelease"] as? Bool != true
            }
            guard let v = mac, let tag = v["tag_name"] as? String else {
                updateMessage = String(localized: "No release found on GitHub.")
                return
            }
            if Version.isNewer(tag, than: local) {
                updateMessage = String(localized: "\(tag) is available (this is \(local)).")
                updateURL = (v["html_url"] as? String).flatMap(URL.init(string:))
            } else {
                updateMessage = String(localized: "Up to date (\(local)).")
            }
        } catch {
            updateMessage = error.localizedDescription
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
                let reply = try await model.stream(system: system, user: user, script: script, maxTokens: 800) { soFar in
                    Task { @MainActor in if self.replyChinese == zh && self.replyWorking { self.replyText = soFar } }
                }
                addTokens(model.id, reply.tokens)
                if replyChinese == zh { replyText = reply.text }
            } catch {
                if replyChinese == zh { replyText = "〔\(error.localizedDescription)〕" }
            }
            replyWorking = false
        }
    }

    // MARK: Summary

    /// An automatic update waits for at least this many new lines, so a quiet room is skipped.
    static let summaryMinLines = 3

    /// The live summary's interval in minutes; nil: only on Update Now. Settings are saved once per change.
    var summaryInterval: Int? {
        get { settings.summaryAuto ? settings.summaryMinutes : nil }
        set {
            guard newValue != summaryInterval else { return }
            var s = settings
            s.summaryAuto = newValue != nil
            if let newValue { s.summaryMinutes = AppSettings.clampedMinutes(newValue) }
            settings = s
        }
    }

    /// When the live summary is next due: nil when nothing will bring it up to date (not listening
    /// yet or any more, record only, or only when asked). It also waits for `summaryMinLines` new
    /// lines, so a quiet room can push it later.
    var nextSummaryAt: Date? {
        guard ticker != nil, recognizer != nil, let minutes = summaryInterval else { return nil }
        return summaryRetryAt ?? lastSummary.addingTimeInterval(Double(minutes * 60))
    }

    /// How many more lines an automatic update waits for (0: enough).
    var summaryLinesMissing: Int { max(0, Self.summaryMinLines - (record?.forSummary.count ?? 0)) }

    /// Bring the summary up to date with the lines since the last time (`force`: even a few).
    func updateSummary(force: Bool) async {
        guard let record else { return }
        await summarize(force: force, record: record)
    }

    /// Bring `record`'s summary up to date with the lines since the last time.
    private func summarize(force: Bool, record: SessionRecord) async {
        guard !summaryWorking else { return }
        let lines = record.takeForSummary()
        guard !lines.isEmpty, force || lines.count >= Self.summaryMinLines else {
            record.giveBack(lines)
            return
        }
        let s = settings
        let model: TextModel
        do { model = try makeSummaryModel(s.liveSummaryModel, s) } catch {
            summaryError = error.localizedDescription
            record.giveBack(lines)
            summaryRetryAt = Date().addingTimeInterval(60)
            return
        }
        summaryWorking = true
        summaryError = ""
        let system = Prompts.withGlossary(Assistants.summarySystem(s.chinese), glossary: s.glossary)
        let user = Assistants.summaryUser(before: summary, transcript: SessionFiles.forSummary(lines, clock: record.clock))
        do {
            let reply = try await model.stream(system: system, user: user, script: script, maxTokens: 4000) { _ in }
            addTokens(model.id, reply.tokens)
            let text = s.chinese.fix(reply.text)
            guard !text.isEmpty else { throw AppError(String(localized: "The model returned nothing.")) }
            summary = text
            let time = record.clock(Date().timeIntervalSince(record.started))
            summaryUpdated = String(localized: "Updated \(time)")
            record.writeSummary(text, updated: summaryUpdated)
            // The interval counts from the end of an update, so a slow model never runs back to back.
            lastSummary = Date()
            summaryRetryAt = nil
        } catch {
            summaryError = String(localized: "Summary failed: \(error.localizedDescription)")
            record.giveBack(lines)
            summaryRetryAt = Date().addingTimeInterval(60)
        }
        summaryWorking = false
    }

    // MARK: Meeting summary

    /// The whole transcript of `record` (the current or last session) to the meeting-summary model:
    /// the minutes, shown in the Summary window and saved as minutes.md.
    func summarizeMeeting(_ chosen: SessionRecord? = nil) async {
        guard !minutesWorking, let record = chosen ?? record ?? lastRecord else { return }
        let lines = record.allLines()
        guard !lines.isEmpty else {
            minutesNote = String(localized: "Nothing to summarize yet.")
            return
        }
        let s = settings
        let model: TextModel
        do { model = try makeSummaryModel(s.meetingSummaryModel, s) } catch {
            minutesNote = error.localizedDescription
            return
        }
        minutesWorking = true
        summaryPane = .meeting
        minutesNote = String(localized: "Writing the meeting summary with \(model.name)…")
        let system = Prompts.withGlossary(Assistants.minutesSystem(s.chinese), glossary: s.glossary)
        let user = Assistants.minutesUser(title: record.title, transcript: SessionFiles.forSummary(lines, clock: record.clock))
        do {
            let reply = try await model.stream(system: system, user: user, script: script, maxTokens: 16000) { soFar in
                Task { @MainActor in if self.minutesWorking { self.minutes = soFar } }
            }
            addTokens(model.id, reply.tokens)
            let text = s.chinese.fix(reply.text)
            guard !text.isEmpty else { throw AppError(String(localized: "The model returned nothing.")) }
            minutes = text
            let time = record.clock(Date().timeIntervalSince(record.started))
            minutesNote = String(localized: "By \(model.name), \(time)")
            record.writeMinutes(text, model: model.name)
        } catch {
            minutesNote = String(localized: "Meeting summary failed: \(error.localizedDescription)")
        }
        minutesWorking = false
    }

    // MARK: Script

    func insertTemplate() {
        setScript(script.isEmpty ? Script.template : script + "\n" + Script.template, action: String(localized: "Insert Template"))
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
        // The glossary's spellings hold here too, as in captions and replies.
        let system = Prompts.withGlossary(Assistants.glossSystem(language: Assistants.languageName(s.speakLanguage), variant: s.chinese), glossary: s.glossary)
        do {
            var answers: [String] = []
            for start in stride(from: 0, to: needs.count, by: 40) {
                let batch = Array(needs[start..<min(start + 40, needs.count)])
                let reply = try await model.stream(system: system, user: Script.request(batch), script: "", maxTokens: 4000) { _ in }
                addTokens(model.id, reply.tokens)
                answers += try Script.answers(reply.text, expect: batch.count)
            }
            guard script == original else {
                throw AppError(String(localized: "The script changed while filling in; try again."))
            }
            setScript(Script.merge(original, needs: needs, answers: answers, variant: s.chinese), action: String(localized: "Fill In Missing Halves"))
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

/// This month's usage, kept in UserDefaults; a new month starts from nothing.
enum UsageStore {
    private static var key: String { "usage-" + UsageBook.month(Date()) }

    static func load() -> UsageBook {
        guard let data = UserDefaults.standard.data(forKey: key), let book = try? JSONDecoder().decode(UsageBook.self, from: data) else { return UsageBook() }
        return book
    }

    static func save(_ book: UsageBook) {
        if let data = try? JSONEncoder().encode(book) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// Whether the room is quiet, from the sound itself (called on the audio thread): cloud recognition
/// gets no sound while paused, and the first sound with any level brings it back. The last two
/// seconds heard while paused go to the recognizer first, so the first words are not lost.
final class QuietGate: @unchecked Sendable {
    /// Sound kept while paused, sent first when recognition comes back.
    static let prerollSeconds = 2.0
    private let lock = NSLock()
    private var lastSound = Date()
    private var paused = false
    private var resumed = false
    /// Copies: the audio source's buffers are only valid during its callback.
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollLength = 0.0
    /// The room's own level (fans, air conditioning, the microphone's hiss), learned as it goes:
    /// it follows quieter sound at once and louder sound only slowly, so steady noise never
    /// counts as someone speaking.
    private var floor: Float?
    private var loudBuffers = 0

    /// What to give the recognizer for `buffer`: nothing while paused (a copy is kept for the
    /// preroll); the preroll, then `buffer`, when recognition has just come back; else `buffer`.
    func admit(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let level = buffer.rms
        lock.lock()
        defer { lock.unlock() }
        let base = floor ?? level
        floor = level < base ? base + (level - base) * 0.2 : base + (level - base) * 0.002
        // Sound well above the room's level, for a quarter of a second or so.
        loudBuffers = level > max(base * 4, 0.003) ? loudBuffers + 1 : 0
        if loudBuffers >= 3 { heard() }
        if paused {
            keep(buffer)
            return []
        }
        guard !preroll.isEmpty else { return [buffer] }
        let out = preroll + [buffer]
        preroll.removeAll()
        prerollLength = 0
        return out
    }

    /// Under `lock`: the newest two seconds are kept.
    private func keep(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copied() else { return }
        preroll.append(copy)
        prerollLength += copy.soundSeconds
        while preroll.count > 1, prerollLength - preroll[0].soundSeconds >= Self.prerollSeconds {
            prerollLength -= preroll.removeFirst().soundSeconds
        }
    }

    /// The recognizer heard words: someone is speaking, whatever the level.
    func speechHeard() {
        lock.lock()
        defer { lock.unlock() }
        heard()
    }

    /// Under `lock`.
    private func heard() {
        lastSound = Date()
        if paused {
            paused = false
            resumed = true
        }
    }

    var quietFor: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastSound)
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    func pause() {
        lock.lock()
        paused = true
        preroll.removeAll()
        prerollLength = 0
        lock.unlock()
    }

    /// Whether recognition came back since the last call.
    func takeResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let r = resumed
        resumed = false
        return r
    }
}

extension AVAudioPCMBuffer {
    /// A copy of the sound that stays valid after the audio source's callback returns.
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameLength, 1)) else { return nil }
        copy.frameLength = frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (src, dst) in zip(from, to) {
            guard let s = src.mData, let d = dst.mData else { continue }
            memcpy(d, s, Int(min(src.mDataByteSize, dst.mDataByteSize)))
        }
        return copy
    }

    /// Seconds of sound.
    var soundSeconds: Double { format.sampleRate > 0 ? Double(frameLength) / format.sampleRate : 0 }
}

/// Waits for `task` to finish, but no longer than `seconds`; then cancels it and goes on.
func waitAtMost(seconds: Double, for task: Task<Void, Never>) async {
    let once = Once()
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Task {
            await task.value
            once.run { done.resume() }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.run { done.resume() }
        }
    }
    task.cancel()
}

/// Runs its block the first time only (from any thread).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
