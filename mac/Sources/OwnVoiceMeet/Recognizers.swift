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
