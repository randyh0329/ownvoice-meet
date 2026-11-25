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
        results?.cancel()
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
    private var socket: URLSessionWebSocketTask?
    private var pending: [Int16] = []
    private var sentSeconds = 0.0
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

    private func connect() async throws {
        var url = URLComponents(string: GeminiLive.endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        try await socket.send(.string(GeminiLive.setupMessage(model: model, language: language)))
        // A bad key or model closes the socket here.
        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                while true {
                    if GeminiLive.parse(try await socket.receive().data).contains(.setupComplete) { return true }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                return false
            }
            let first = try await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard ready else {
            socket.cancel()
            throw AppError(String(localized: "Gemini did not answer the setup (check the key)."))
        }
        queue.sync { self.socket = socket }
        onEvent?(.status(String(localized: "Listening (Gemini Live)")))
        receive(on: socket)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        Task {
            while running {
                do {
                    for event in GeminiLive.parse(try await socket.receive().data) {
                        switch event {
                        case .partial(let t): onEvent?(.partial(t))
                        case .final(let t): onEvent?(.final(t))
                        case .setupComplete, .goAway: break
                        }
                    }
                } catch {
                    guard running else { return }
                    onEvent?(.status(String(localized: "Gemini connection dropped; reconnecting…")))
                    try? await Task.sleep(for: .seconds(1))
                    do { try await connect() } catch { onEvent?(.status(error.localizedDescription)) }
                    return
                }
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            self.pending += samples
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
        running = false
        let socket = queue.sync { self.socket }
        socket?.send(.string(GeminiLive.streamEnd)) { _ in }
        try? await Task.sleep(for: .milliseconds(800))
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync { self.socket = nil }
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
            for event in self.segmenter.push(samples) {
                switch event {
                case .start: self.onEvent?(.partial("…"))
                case .audio: break
                case .end(let utterance): self.upload(utterance)
                case .discard: self.onEvent?(.final(""))
                }
            }
        }
    }

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

    func stop() async {
        await uploads?.value
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
    private var current: String?
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
            do {
                try await socket.send(.string(OpenAIRealtime.sessionUpdate(model: "gpt-live-transcribe", language: language)))
                while true {
                    switch OpenAIRealtime.parse(try await socket.receive().data) {
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
            var texts: [String: String] = [:]
            while running {
                do {
                    switch OpenAIRealtime.parse(try await socket.receive().data) {
                    case let .delta(item, text)?:
                        texts[item, default: ""] += text
                        if current == nil { current = item }
                        if current == item { onEvent?(.partial(texts[item] ?? "")) }
                    case let .completed(item, text)?:
                        texts[item] = nil
                        if current == item { current = nil }
                        onEvent?(.final(text))
                    case .error(let message)?:
                        onEvent?(.status("OpenAI: \(message)"))
                    default:
                        continue
                    }
                } catch {
                    guard running else { return }
                    onEvent?(.status(String(localized: "OpenAI connection dropped; reconnecting…")))
                    try? await Task.sleep(for: .seconds(1))
                    do { try await connect() } catch { onEvent?(.status(error.localizedDescription)) }
                    return
                }
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            for event in self.segmenter.push(samples) {
                let message: String
                switch event {
                case .start(let pcm), .audio(let pcm):
                    message = OpenAIRealtime.append(pcm)
                    self.sentSeconds += Double(pcm.count) / Double(OpenAIRealtime.sampleRate)
                case .end: message = OpenAIRealtime.commit
                case .discard: message = OpenAIRealtime.clear
                }
                self.socket?.send(.string(message)) { _ in }
            }
            if self.sentSeconds >= 5 {
                self.onEvent?(.audio(self.sentSeconds))
                self.sentSeconds = 0
            }
        }
    }

    func stop() async {
        running = false
        try? await Task.sleep(for: .milliseconds(800))
        let socket = queue.sync { self.socket }
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync { self.socket = nil }
    }
}

// MARK: - Gemini Live Translate

/// Gemini Live Translate: hears the speech and gives the Chinese itself, as two streams the
/// Interpreter pairs into lines. The translated audio it also sends is not played.
final class GeminiLiveTranslateRecognizer: Recognizer, InterpreterSink {
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

    private func connect() async throws {
        var url = URLComponents(string: GeminiLive.endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        try await socket.send(.string(GeminiLive.translateSetup(model: model, target: target, instruction: instruction)))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if GeminiLive.parseTranslate(try await socket.receive().data).contains(.setupComplete) {
                queue.sync { self.socket = socket }
                onEvent?(.status(String(localized: "Listening (Gemini Live Translate)")))
                receive(on: socket)
                return
            }
        }
        socket.cancel()
        throw AppError(String(localized: "Gemini did not answer the setup (check the key)."))
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        Task {
            while running {
                do {
                    let events = GeminiLive.parseTranslate(try await socket.receive().data)
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
                    guard running else { return }
                    queue.async { self.interpreter.flush(sink: self) }
                    onEvent?(.status(String(localized: "Gemini connection dropped; reconnecting…")))
                    try? await Task.sleep(for: .seconds(1))
                    do { try await connect() } catch { onEvent?(.status(error.localizedDescription)) }
                    return
                }
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            self.pending += samples
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
        running = false
        ticker?.cancel()
        queue.sync { self.interpreter.flush(sink: self) }
        let socket = queue.sync { self.socket }
        socket?.send(.string(GeminiLive.streamEnd)) { _ in }
        socket?.cancel(with: .normalClosure, reason: nil)
        queue.sync { self.socket = nil }
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
