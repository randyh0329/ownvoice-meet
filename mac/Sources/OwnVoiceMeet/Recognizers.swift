// Speech to text: Apple's on-device SpeechAnalyzer, or Gemini Live over a WebSocket. Both report
// the sentence so far (partial, gray) and the sentence as finalized (final, translated next).

import AVFoundation
import Foundation
import OwnVoiceCore
import Speech

enum RecognitionEvent {
    case partial(String)
    case final(String)
    case status(String)
    /// Seconds of sound sent to a paid service (for the usage record).
    case audio(Double)
    // Lines the recognizer manages itself, with their Chinese (Gemini Live Translate). `line` is
    // the recognizer's own number for it.
    case lineOpened(Int)
    case lineHeard(Int, String, done: Bool)
    case lineTranslated(Int, String, done: Bool)
    case lineDropped(Int)
}

protocol Recognizer: AnyObject {
    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws
    /// A buffer from the audio source, in the source's format (called on an audio thread).
    func feed(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

// MARK: - Apple SpeechAnalyzer

final class AppleSpeechRecognizer: Recognizer {
    private let language: String
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: BufferConverter?
    private var results: Task<Void, Never>?

    init(language: String) {
        self.language = language.isEmpty ? "en-US" : language
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        let wanted = Locale(identifier: language)
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) })
            ?? supported.first(where: { $0.language.languageCode == wanted.language.languageCode }) else {
            throw AppError(String(localized: "Apple on-device recognition does not support \(language)."))
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onEvent(.status(String(localized: "Downloading Apple's speech model…")))
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError(String(localized: "Apple on-device recognition has no audio format for this language."))
        }
        converter = BufferConverter(to: format)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        results = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    onEvent(result.isFinal ? .final(text) : .partial(text))
                }
            } catch {
                onEvent(.status(String(localized: "Apple recognition stopped: \(error.localizedDescription)")))
            }
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter?.convert(buffer) else { return }
        input?.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        // The last results come after finalizing: let them arrive (briefly) before ending.
        if let results { await waitAtMost(seconds: 3, for: results) }
        analyzer = nil
    }
}

// MARK: - Gemini Live

/// Gemini Live transcription. A dropped connection (or the server ending a session, which it does
/// after about ten minutes) is reconnected while listening goes on.
final class GeminiLiveRecognizer: Recognizer {
    private let key: String
    private let model = "gemini-3.5-transcribe-live"
    private let language: String
    private let converter = BufferConverter(to: BufferConverter.pcm16k)
    private let queue = DispatchQueue(label: "gemini-live")
    // On `queue`:
    private var socket: URLSessionWebSocketTask?
    private var pending: [Int16] = []
    private var sentSeconds = 0.0
    private var stopping = false
    /// The gray text of the line being spoken, finished by hand if its session ends first.
    private var openPartial = ""
    private var running = false
    private var onEvent: ((RecognitionEvent) -> Void)?

    init(key: String, language: String) {
        self.key = key
        self.language = language
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        self.onEvent = onEvent
        running = true
        try await connect()
    }

    private func open() async throws -> URLSessionWebSocketTask {
        var url = URLComponents(string: GeminiLive.endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        // A bad key or model closes the socket here; a server that never answers times out.
        let deadline = Date().addingTimeInterval(10)
        do {
            try await socket.send(.string(GeminiLive.setupMessage(model: model, language: language)))
            while !GeminiLive.parse(try await socket.receive(before: deadline).data).contains(.setupComplete) {}
        } catch {
            socket.cancel()
            throw AppError(String(localized: "Gemini did not answer the setup (check the key)."))
        }
        return socket
    }

    private func connect() async throws {
        let socket = try await open()
        queue.sync { self.socket = socket }
        onEvent?(.status(String(localized: "Listening (Gemini Live)")))
        receive(on: socket)
    }

    private func isCurrent(_ socket: URLSessionWebSocketTask) -> Bool { queue.sync { self.socket === socket } }

    /// The line still gray when its session ends is kept as it stands, not overwritten.
    private func finishPartial() {
        let text = queue.sync { () -> String in
            defer { openPartial = "" }
            return openPartial
        }
        if !text.isEmpty { onEvent?(.final(text)) }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        let opened = Date()
        Task {
            var reader = GeminiLive.Reader()
            var rotating = false
            while running {
                do {
                    let message = try await socket.receive()
                    // A session already replaced by the next: its late words are not shown.
                    guard isCurrent(socket) else { continue }
                    for event in reader.parse(message.data) {
                        switch event {
                        case .partial(let t):
                            queue.sync { openPartial = t }
                            onEvent?(.partial(t))
                        case .final(let t):
                            queue.sync { openPartial = "" }
                            onEvent?(.final(t))
                            // Sessions are limited to about ten minutes: the next one is opened
                            // at a pause after nine.
                            if !rotating, Date().timeIntervalSince(opened) >= 9 * 60 {
                                rotating = true
                                rotate(from: socket)
                            }
                        case .goAway:
                            if !rotating {
                                rotating = true
                                rotate(from: socket)
                            }
                        case .setupComplete:
                            break
                        }
                    }
                    if !rotating, Date().timeIntervalSince(opened) >= 590 {
                        rotating = true
                        rotate(from: socket)
                    }
                } catch {
                    guard running, !queue.sync(execute: { stopping }), isCurrent(socket) else { return }
                    finishPartial()
                    queue.sync { self.socket = nil }
                    await reconnectWithBackoff(service: "Gemini", running: { self.running }, onEvent: onEvent, connect: connect)
                    return
                }
            }
        }
    }

    /// The next session is set up while this one still listens, then takes over the sound.
    private func rotate(from old: URLSessionWebSocketTask) {
        Task {
            // If it cannot be opened, the old one goes on until it closes, and reconnects then.
            guard let next = try? await open() else { return }
            guard running, isCurrent(old) else {
                next.cancel()
                return
            }
            queue.sync { self.socket = next }
            finishPartial()
            receive(on: next)
            old.send(.string(GeminiLive.streamEnd)) { _ in }
            try? await Task.sleep(for: .seconds(1))
            old.cancel(with: .normalClosure, reason: nil)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            guard !self.stopping else { return }
            self.pending += samples
            // Disconnected: nothing is sent or billed, but the last few seconds are kept for the
            // next connection, so a reconnect loses little of what was said.
            guard self.socket != nil else {
                let keep = Int(GeminiLive.sampleRate * 5)
                if self.pending.count > keep { self.pending.removeFirst(self.pending.count - keep) }
                return
            }
            while self.pending.count >= GeminiLive.chunkSamples {
                let chunk = Array(self.pending.prefix(GeminiLive.chunkSamples))
                self.pending.removeFirst(GeminiLive.chunkSamples)
                self.socket?.send(.string(GeminiLive.audioMessage(chunk))) { _ in }
                self.sentSeconds += Double(chunk.count) / GeminiLive.sampleRate
                if self.sentSeconds >= 5 {
                    self.onEvent?(.audio(self.sentSeconds))
                    self.sentSeconds = 0
                }
            }
        }
    }

    func stop() async {
        let socket = queue.sync { () -> URLSessionWebSocketTask? in
            stopping = true
            return self.socket
        }
        socket?.send(.string(GeminiLive.streamEnd)) { _ in }
        // The last sentence comes back after the end of the stream: it is read for up to 1.5 s.
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            if queue.sync(execute: { openPartial.isEmpty }) { break }
        }
        running = false
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync { self.socket = nil }
        finishPartial()
    }
}

extension URLSessionWebSocketTask {
    /// The next message, or an error once `deadline` passes: the socket is cancelled then, which
    /// is what ends a wait for a server that never answers.
    func receive(before deadline: Date) async throws -> Message {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else {
            cancel()
            throw URLError(.timedOut)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(left))
            if !Task.isCancelled { self?.cancel(with: .goingAway, reason: nil) }
        }
        defer { timer.cancel() }
        return try await receive()
    }
}

/// After a dropped connection: try again while still listening, waiting 1, 2, 4… up to 30 seconds
/// between tries, and say so.
func reconnectWithBackoff(service: String, running: @escaping () -> Bool, onEvent: ((RecognitionEvent) -> Void)?, connect: () async throws -> Void) async {
    var delay = 1
    while running() {
        onEvent?(.status(String(localized: "\(service) connection dropped; trying again in \(String(delay)) s…")))
        try? await Task.sleep(for: .seconds(delay))
        guard running() else { return }
        do {
            try await connect()
            return
        } catch {
            delay = min(delay * 2, 30)
        }
    }
}

extension URLSessionWebSocketTask.Message {
    /// The Live API sends JSON in text and in binary frames.
    var data: Data {
        switch self {
        case .string(let s): Data(s.utf8)
        case .data(let d): d
        @unknown default: Data()
        }
    }
}

// MARK: - Sentence by sentence

/// Cuts the sound into utterances (Segmenter) and sends each, once it ends, to an upload service:
/// OpenAI gpt-4o-mini-transcribe, Gemini 3.5 Transcribe, or the user's Whisper server. A gray "…"
/// shows while someone talks; uploads go one at a time, so lines stay in order.
final class SentenceRecognizer: Recognizer {
    enum Service {
        case openAI(key: String)
        case gemini(key: String)
        case whisper(base: String, model: String, key: String?)
    }

    private let service: Service
    private let language: String
    private let converter = BufferConverter(to: BufferConverter.pcm16k)
    private let queue = DispatchQueue(label: "sentences")
    private var segmenter = Segmenter(rate: 16_000)
    private var uploads: Task<Void, Never>?
    private var onEvent: ((RecognitionEvent) -> Void)?

    init(service: Service, language: String) {
        self.service = service
        self.language = language
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        self.onEvent = onEvent
        onEvent(.status(String(localized: "Listening (sentence by sentence)")))
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            for event in self.segmenter.push(samples) { self.handle(event) }
        }
    }

    /// On `queue`.
    private func handle(_ event: SegmentEvent) {
        switch event {
        case .start: onEvent?(.partial("…"))
        case .audio: break
        case .end(let utterance): upload(utterance)
        case .discard: onEvent?(.final(""))
        }
    }

    /// On `queue` (so `uploads` is only touched there).
    private func upload(_ utterance: [Int16]) {
        let previous = uploads
        let wav = WAV.data(utterance, rate: 16_000)
        let seconds = Double(utterance.count) / 16_000
        let service = service, language = language, onEvent = onEvent
        uploads = Task {
            await previous?.value
            do {
                let text = try await Self.transcribe(wav, service: service, language: language)
                if case .whisper = service {} else { onEvent?(.audio(seconds)) }
                onEvent?(.final(text))
            } catch {
                onEvent?(.final(""))
                onEvent?(.status(String(localized: "Recognition failed: \(error.localizedDescription)")))
            }
        }
    }

    private static func transcribe(_ wav: Data, service: Service, language: String) async throws -> String {
        var req: URLRequest
        switch service {
        case .openAI(let key):
            req = URLRequest(url: Uploads.openAITranscriptions, timeoutInterval: 30)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            let form = Uploads.transcriptionForm(wav: wav, model: "gpt-4o-mini-transcribe", language: language)
            req.setValue(form.contentType, forHTTPHeaderField: "content-type")
            req.httpBody = form.body
        case let .whisper(base, model, key):
            let trimmed = base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: trimmed + "/audio/transcriptions"), !trimmed.isEmpty else {
                throw AppError(String(localized: "Your Whisper server: fill in its address in Settings first."))
            }
            req = URLRequest(url: url, timeoutInterval: 60)
            if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization") }
            let form = Uploads.transcriptionForm(wav: wav, model: model, language: language)
            req.setValue(form.contentType, forHTTPHeaderField: "content-type")
            req.httpBody = form.body
        case .gemini(let key):
            req = URLRequest(url: Uploads.geminiInteractions, timeoutInterval: 30)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try Uploads.geminiBody(model: "gemini-3.5-transcribe", language: language, wav: wav)
        }
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if case .gemini = service { return try Uploads.geminiText(data, status: status) }
        return try Uploads.transcriptionText(data, status: status)
    }

    /// The sentence being spoken when listening stops is sent too (or its gray line dropped), and
    /// the uploads finish before the session closes.
    func stop() async {
        let last: Task<Void, Never>? = queue.sync {
            if let event = segmenter.finish() { handle(event) }
            return uploads
        }
        await last?.value
    }
}

// MARK: - OpenAI live

/// OpenAI gpt-live-transcribe over the Realtime WebSocket. The client segments: only speech is
/// sent (preroll + utterance), committed per utterance, so silence is never billed.
final class OpenAILiveRecognizer: Recognizer {
    private let key: String
    private let language: String
    private let converter = BufferConverter(to: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!)
    private let queue = DispatchQueue(label: "openai-live")
    private var segmenter = Segmenter(rate: OpenAIRealtime.sampleRate)
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var sentSeconds = 0.0
    private var onEvent: ((RecognitionEvent) -> Void)?

    init(key: String, language: String) {
        self.key = key
        self.language = language.split(separator: "-").first.map(String.init) ?? ""
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        self.onEvent = onEvent
        running = true
        try await connect()
    }

    private func connect() async throws {
        var lastError = ""
        for url in OpenAIRealtime.urls {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
            let socket = URLSession.shared.webSocketTask(with: req)
            socket.resume()
            let deadline = Date().addingTimeInterval(10)
            do {
                try await socket.send(.string(OpenAIRealtime.sessionUpdate(model: "gpt-live-transcribe", language: language)))
                while true {
                    switch OpenAIRealtime.parse(try await socket.receive(before: deadline).data) {
                    case .accepted?:
                        queue.sync { self.socket = socket }
                        onEvent?(.status(String(localized: "Listening (OpenAI Live)")))
                        receive(on: socket)
                        return
                    case .error(let message)?:
                        throw AppError(message)
                    default:
                        continue
                    }
                }
            } catch {
                socket.cancel()
                lastError = error.localizedDescription
            }
        }
        throw AppError(String(localized: "OpenAI refused the connection: \(lastError)"))
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        Task {
            // Per connection: transcripts in the order they were spoken, each on its own line.
            var utterances = OpenAIRealtime.Utterances()
            func emit(_ outputs: [OpenAIRealtime.Utterances.Output]) {
                for output in outputs {
                    switch output {
                    case .partial(let t): onEvent?(.partial(t))
                    case .final(let t): onEvent?(.final(t))
                    }
                }
            }
            while running {
                do {
                    guard let event = OpenAIRealtime.parse(try await socket.receive().data) else { continue }
                    if case .error(let message) = event {
                        onEvent?(.status("OpenAI: \(message)"))
                    } else {
                        emit(utterances.handle(event))
                    }
                } catch {
                    guard running else { return }
                    // What was heard so far is kept, not overwritten by the next connection.
                    emit(utterances.flush())
                    queue.sync { self.socket = nil }
                    await reconnectWithBackoff(service: "OpenAI", running: { self.running }, onEvent: onEvent, connect: connect)
                    return
                }
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            for event in self.segmenter.push(samples) { self.send(event) }
            if self.sentSeconds >= 5 {
                self.onEvent?(.audio(self.sentSeconds))
                self.sentSeconds = 0
            }
        }
    }

    /// On `queue`. Disconnected: nothing is sent, and nothing is billed.
    private func send(_ event: SegmentEvent) {
        guard let socket else { return }
        let message: String
        switch event {
        case .start(let pcm), .audio(let pcm):
            message = OpenAIRealtime.append(pcm)
            sentSeconds += Double(pcm.count) / Double(OpenAIRealtime.sampleRate)
        case .end: message = OpenAIRealtime.commit
        case .discard: message = OpenAIRealtime.clear
        }
        socket.send(.string(message)) { _ in }
    }

    func stop() async {
        // The sentence being spoken is committed, and its transcript given a moment to come back.
        queue.sync { if let event = segmenter.finish() { send(event) } }
        try? await Task.sleep(for: .milliseconds(1500))
        running = false
        let socket = queue.sync { self.socket }
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync { self.socket = nil }
    }
}

// MARK: - Gemini Live Translate

/// Gemini Live Translate: hears the speech and gives the Chinese itself, as two streams the
/// Interpreter pairs into lines. The translated audio it also sends is not played.
/// Its state is touched only on `queue` (and the socket set once per connection), so it is safe to
/// hand to the tasks that read the socket and tick the interpreter.
final class GeminiLiveTranslateRecognizer: Recognizer, InterpreterSink, @unchecked Sendable {
    private let key: String
    private let model = "gemini-3.5-live-translate-preview"
    private let target: String
    private let instruction: String
    private let converter = BufferConverter(to: BufferConverter.pcm16k)
    private let queue = DispatchQueue(label: "gemini-live-translate")
    private var socket: URLSessionWebSocketTask?
    private var interpreter = Interpreter()
    private var nextLine = 0
    private var pending: [Int16] = []
    private var sentSeconds = 0.0
    private var stopping = false
    private var running = false
    private var ticker: Task<Void, Never>?
    private var onEvent: ((RecognitionEvent) -> Void)?

    init(key: String, chinese: ChineseVariant, glossary: String) {
        self.key = key
        target = chinese == .traditionalTaiwan ? "zh-TW" : "zh-Hans"
        instruction = Assistants.liveTranslateInstruction(glossary: glossary, variant: chinese)
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        self.onEvent = onEvent
        running = true
        try await connect()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                self.queue.async { self.interpreter.tick(now: Date(), sink: self) }
            }
        }
    }

    private func open() async throws -> URLSessionWebSocketTask {
        var url = URLComponents(string: GeminiLive.endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        let deadline = Date().addingTimeInterval(10)
        do {
            try await socket.send(.string(GeminiLive.translateSetup(model: model, target: target, instruction: instruction)))
            while !GeminiLive.parseTranslate(try await socket.receive(before: deadline).data).contains(.setupComplete) {}
        } catch {
            socket.cancel()
            throw AppError(String(localized: "Gemini did not answer the setup (check the key)."))
        }
        return socket
    }

    private func connect() async throws {
        let socket = try await open()
        queue.sync { self.socket = socket }
        onEvent?(.status(String(localized: "Listening (Gemini Live Translate)")))
        receive(on: socket)
    }

    private func isCurrent(_ socket: URLSessionWebSocketTask) -> Bool { queue.sync { self.socket === socket } }

    /// Sessions are limited to about ten minutes: after nine, the next one is set up while this
    /// one still listens, then takes over the sound. The old one's last words still count.
    private func rotate(from old: URLSessionWebSocketTask) {
        Task {
            guard let next = try? await open() else { return }
            guard running, isCurrent(old) else {
                next.cancel()
                return
            }
            queue.sync { self.socket = next }
            receive(on: next)
            old.send(.string(GeminiLive.streamEnd)) { _ in }
            try? await Task.sleep(for: .milliseconds(1500))
            old.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        let opened = Date()
        Task {
            var rotating = false
            while running {
                do {
                    let events = GeminiLive.parseTranslate(try await socket.receive().data)
                    if !rotating, Date().timeIntervalSince(opened) >= 9 * 60, isCurrent(socket) {
                        rotating = true
                        rotate(from: socket)
                    }
                    queue.async {
                        for event in events {
                            switch event {
                            case .heard(let t): self.interpreter.heard(t, now: Date(), sink: self)
                            case .translated(let t): self.interpreter.translated(t, now: Date(), sink: self)
                            case .setupComplete: break
                            }
                        }
                    }
                } catch {
                    guard running, !queue.sync(execute: { stopping }), isCurrent(socket) else { return }
                    queue.sync {
                        self.interpreter.flush(sink: self)
                        self.socket = nil
                    }
                    await reconnectWithBackoff(service: "Gemini", running: { self.running }, onEvent: onEvent, connect: connect)
                    return
                }
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            guard !self.stopping else { return }
            self.pending += samples
            // Disconnected: nothing is sent or billed; the last few seconds wait for the next connection.
            guard self.socket != nil else {
                let keep = Int(GeminiLive.sampleRate * 5)
                if self.pending.count > keep { self.pending.removeFirst(self.pending.count - keep) }
                return
            }
            while self.pending.count >= GeminiLive.chunkSamples {
                let chunk = Array(self.pending.prefix(GeminiLive.chunkSamples))
                self.pending.removeFirst(GeminiLive.chunkSamples)
                self.socket?.send(.string(GeminiLive.audioMessage(chunk))) { _ in }
                self.sentSeconds += Double(chunk.count) / GeminiLive.sampleRate
            }
            if self.sentSeconds >= 5 {
                self.onEvent?(.audio(self.sentSeconds))
                self.sentSeconds = 0
            }
        }
    }

    func stop() async {
        let socket = queue.sync { () -> URLSessionWebSocketTask? in
            stopping = true
            return self.socket
        }
        socket?.send(.string(GeminiLive.streamEnd)) { _ in }
        // The last sentence and its Chinese come after the end of the stream: read for 1.5 s.
        try? await Task.sleep(for: .milliseconds(1500))
        running = false
        ticker?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync {
            self.socket = nil
            self.interpreter.flush(sink: self)
        }
    }

    // InterpreterSink (called on `queue`)
    func open() -> Int {
        nextLine += 1
        onEvent?(.lineOpened(nextLine))
        return nextLine
    }

    func heard(_ id: Int, _ text: String, done: Bool) { onEvent?(.lineHeard(id, text, done: done)) }
    func translated(_ id: Int, _ text: String, done: Bool) { onEvent?(.lineTranslated(id, text, done: done)) }
    func drop(_ id: Int) { onEvent?(.lineDropped(id)) }
}
