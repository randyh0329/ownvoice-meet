// Gemini 3.5 Live Translate chosen under Translation: the recognition chosen under Listen (Apple,
// Gemini Transcribe, OpenAI…) makes the caption lines, while a Live Translate socket hears the same
// sound and its Chinese is paired onto those lines (Core's Interpreter, following). Lines it brings
// no Chinese for, and every line while it is disconnected, go to the text model (Gemini 3.5
// Flash-Lite on the same key), as do replies and the summary. A refused connection hands the
// captions to the text model for good. Each start of listening is a run with its own number
// (LiveTranslateFollowing), so a run still winding down never touches the next one's pairing.

import AVFoundation
import Foundation
import OwnVoiceCore

/// Live Translate's model, the language it translates into, and its socket setup, shared by the
/// recognizer (hears and translates in one) and the follower.
enum LiveTranslate {
    static let model = "gemini-3.5-live-translate-preview"

    /// Traditional Chinese as used in Taiwan, or Simplified.
    static func target(_ chinese: ChineseVariant) -> String {
        chinese == .traditionalTaiwan ? "zh-TW" : "zh-Hans"
    }

    /// The server turned the key or the model down: trying again will not help.
    struct Refused: Error {}

    /// A socket set up for translation into `target`, once the server says setupComplete (10 s at most).
    static func open(key: String, target: String, instruction: String) async throws -> URLSessionWebSocketTask {
        var url = URLComponents(string: GeminiLive.endpoint)!
        url.queryItems = [URLQueryItem(name: "key", value: key)]
        let socket = URLSession.shared.webSocketTask(with: url.url!)
        socket.resume()
        let deadline = Date().addingTimeInterval(10)
        do {
            try await socket.send(.string(GeminiLive.translateSetup(model: model, target: target, instruction: instruction)))
            while !GeminiLive.parseTranslate(try await socket.receive(before: deadline).data).contains(.setupComplete) {}
        } catch {
            // A bad key or model is refused at the handshake, or closes the socket during setup
            // with the reason in its close code.
            let http = (socket.response as? HTTPURLResponse)?.statusCode ?? 0
            let code = socket.closeCode
            socket.cancel()
            if [401, 403, 404].contains(http) || code == .invalidFramePayloadData || code == .policyViolation {
                throw Refused()
            }
            throw error
        }
        return socket
    }
}

/// The follower for Live Translate chosen under Translation, on the Gemini key.
func makeFollower(_ s: AppSettings) throws -> LiveTranslateFollower {
    guard let key = Keychain.get("gemini") else { throw AppError(String(localized: "Add a Gemini API key in Settings first.")) }
    return LiveTranslateFollower(key: key, chinese: s.chinese, glossary: s.glossary)
}

/// What following brings the app: a line's Chinese, a line left to the text model, a status, and
/// seconds of sound sent (billed at Live Translate's price).
enum FollowEvent {
    case translated(Int, String, done: Bool)
    case untranslated(Int)
    case status(String)
    case audio(Double)
}

/// The pairing, on the main actor for the app's whole life (like the caption lines it pairs onto):
/// which run is current and its Interpreter. What it decides goes to AppModel.followed.
@MainActor
final class FollowingState {
    static let shared = FollowingState()

    private var slot = LiveTranslateFollowing()

    /// Runs `body` on the slot, then hands on what the pairing said (after, so the app may come back here).
    private func with<T>(_ body: (inout LiveTranslateFollowing, InterpreterSink) -> T) -> T {
        let sink = Collected()
        let result = body(&slot, sink)
        for event in sink.events { report(event) }
        return result
    }

    func report(_ event: FollowEvent) {
        AppModel.shared.followed(event)
    }

    // A run of Live Translate.

    func on() -> Int { with { $0.on(sink: $1) } }
    func off(run: Int) { with { $0.off(run: run, sink: $1) } }
    func pause(run: Int) { with { $0.pause(run: run, sink: $1) } }
    func resume(run: Int) { slot.resume(run: run) }
    func translated(run: Int, _ piece: String) { with { $0.translated(run: run, piece, now: Date(), sink: $1) } }
    func flush(run: Int) { with { $0.flush(run: run, sink: $1) } }

    /// Time passes; returns whether nothing waits for run `run`'s Chinese (a good moment to replace
    /// its session).
    func tick(run: Int) -> Bool {
        with { (slot: inout LiveTranslateFollowing, sink: InterpreterSink) -> Bool in
            slot.tick(run: run, now: Date(), sink: sink)
            return slot.idle(run: run)
        }
    }

    // The caption lines (any recognition): nothing happens unless a run is on.

    /// Opening a line already open changes nothing.
    func lineOpened(_ id: Int) { slot.lineOpened(id) }

    /// True when Live Translate brings this line's Chinese; false: the text model should translate it.
    func lineEnded(_ id: Int, _ text: String) -> Bool { with { $0.lineEnded(id, text, now: Date(), sink: $1) } }

    func lineDropped(_ id: Int) { slot.lineDropped(id) }
}

/// Collects what the pairing says.
private final class Collected: InterpreterSink {
    var events: [FollowEvent] = []

    /// Never called: following, lines are only opened by the recognizer.
    func open() -> Int { 0 }
    func heard(_ id: Int, _ text: String, done: Bool) {}
    func translated(_ id: Int, _ text: String, done: Bool) { events.append(.translated(id, text, done: done)) }
    func drop(_ id: Int) {}
    func untranslated(_ id: Int, _ heard: String) { events.append(.untranslated(id)) }
}

/// The Live Translate socket that follows the captions: fed the same sound as the recognizer, its
/// Chinese goes to FollowingState. Sessions are replaced before the server's ten-minute limit, at
/// a moment when no line waits for its Chinese if it can; a dropped connection is tried again,
/// with the text model translating meanwhile and the sound from while it was away dropped (the
/// Chinese after it is for what is being said then). Its state is touched only on `queue`.
final class LiveTranslateFollower: @unchecked Sendable {
    private let key: String
    private let target: String
    private let instruction: String
    private let converter = BufferConverter(to: BufferConverter.pcm16k)
    private let queue = DispatchQueue(label: "gemini-live-translate-follow")
    /// This run's number (set at start, before anything else runs).
    private var run = 0
    private var ticker: Task<Void, Never>?
    // On `queue`:
    private var socket: URLSessionWebSocketTask?
    private var opened = Date()
    private var goingAway = false
    private var pending: [Int16] = []
    private var sentSeconds = 0.0
    /// When sound last came from the source.
    private var lastSound = Date()
    private var running = false
    private var stopping = false
    /// Disconnected after a failure: the text model has the captions until it is back.
    private var away = false
    /// Refused for good: nothing more is sent.
    private var refused = false

    /// The session is replaced at a quiet moment after this long…
    private static let rotateAtPause: TimeInterval = 9 * 60
    /// …and anyway after this long (the server's limit is ten minutes).
    private static let rotateAnyway: TimeInterval = 9 * 60 + 50
    /// No sound for this long: silence is sent, so Live Translate hears the pause…
    private static let silenceAfter: TimeInterval = 0.25
    /// …but only this long after the last sound (a quiet room is not billed for long).
    private static let silenceFor: TimeInterval = 5

    init(key: String, chinese: ChineseVariant, glossary: String) {
        self.key = key
        target = LiveTranslate.target(chinese)
        instruction = Assistants.liveTranslateInstruction(glossary: glossary, variant: chinese)
    }

    /// Starts a run: lines the recognizer opens from now on wait for Live Translate's Chinese.
    @MainActor
    func start() {
        run = FollowingState.shared.on()
        queue.sync { running = true }
        Task { await connect(retryAfter: nil) }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let run = self.run
                let idle = await MainActor.run { FollowingState.shared.tick(run: run) }
                self.queue.async {
                    self.sendSilence()
                    self.rotateIfDue(idle: idle)
                }
            }
        }
    }

    private var isRunning: Bool { queue.sync { running && !stopping } }
    private func isCurrent(_ socket: URLSessionWebSocketTask) -> Bool { queue.sync { self.socket === socket } }

    private func report(_ event: FollowEvent) async {
        await MainActor.run { FollowingState.shared.report(event) }
    }

    /// Connects, trying again while listening goes on, 1, 2, 4… up to 30 seconds apart.
    /// `retryAfter`: the connection just dropped; the first try waits that many seconds.
    private func connect(retryAfter first: Int?) async {
        var delay = first
        let run = self.run
        while isRunning {
            if let delay {
                // Until it is back, the text model translates (and the sound meanwhile is dropped).
                let wasAway = queue.sync { () -> Bool in
                    defer { away = true }
                    return away
                }
                if !wasAway { await MainActor.run { FollowingState.shared.pause(run: run) } }
                await report(.status(String(localized: "Live Translate connection dropped; captions use the text model for now, trying again in \(String(delay)) s…")))
                try? await Task.sleep(for: .seconds(delay))
                guard isRunning else { return }
            }
            do {
                let socket = try await LiveTranslate.open(key: key, target: target, instruction: instruction)
                guard isRunning else {
                    socket.cancel()
                    return
                }
                let wasAway = queue.sync { away }
                if wasAway {
                    await MainActor.run { FollowingState.shared.resume(run: run) }
                }
                queue.sync {
                    // Sound from while it was away is dropped: the Chinese from here on is for what is said now.
                    if away { pending.removeAll() }
                    away = false
                    self.socket = socket
                    opened = Date()
                    goingAway = false
                }
                if wasAway { await report(.status(String(localized: "Live Translate is connected again."))) }
                receive(on: socket)
                return
            } catch is LiveTranslate.Refused {
                queue.sync {
                    refused = true
                    pending.removeAll()
                }
                // Captions go on with the text model.
                await MainActor.run { FollowingState.shared.off(run: run) }
                await report(.status(String(localized: "Live Translate refused the connection (check the Gemini key); captions are translated by the text model.")))
                return
            } catch {
                delay = min((delay ?? 0) * 2, 30)
                if delay == 0 { delay = 1 }
            }
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        let run = self.run
        Task {
            while isRunning || isCurrent(socket) {
                do {
                    let data = try await socket.receive().data
                    // A session already replaced: its late Chinese is not paired.
                    guard isCurrent(socket) else { return }
                    if GeminiLive.parse(data).contains(.goAway) { queue.sync { goingAway = true } }
                    // Only the Chinese is used: what was said is the recognizer's.
                    let pieces = GeminiLive.parseTranslate(data).compactMap { event -> String? in
                        if case .translated(let t) = event { return t }
                        return nil
                    }
                    if !pieces.isEmpty {
                        await MainActor.run {
                            for piece in pieces { FollowingState.shared.translated(run: run, piece) }
                        }
                    }
                } catch {
                    guard isRunning, isCurrent(socket) else { return }
                    let elapsed = queue.sync { () -> TimeInterval in
                        self.socket = nil
                        return Date().timeIntervalSince(opened)
                    }
                    // A Chinese still owed by the closed socket will not come: lines that ended keep
                    // what they have.
                    await MainActor.run { FollowingState.shared.flush(run: run) }
                    // Closed by the server near its time limit: the next session, at once.
                    await connect(retryAfter: elapsed > Self.rotateAtPause ? nil : 1)
                    return
                }
            }
        }
    }

    /// On `queue`: the next session replaces this one near the time limit, or when the server says
    /// it is going away, at a moment when nothing waits for its Chinese if it can.
    private func rotateIfDue(idle: Bool) {
        guard let old = socket, !stopping else { return }
        let elapsed = Date().timeIntervalSince(opened)
        guard (goingAway && idle) || (elapsed > Self.rotateAtPause && idle) || elapsed > Self.rotateAnyway else { return }
        socket = nil
        let run = self.run
        Task {
            old.cancel(with: .normalClosure, reason: nil)
            await MainActor.run { FollowingState.shared.flush(run: run) }
            await connect(retryAfter: nil)
        }
    }

    /// On `queue`: while the source sends nothing (nothing plays), a little silence, so Live
    /// Translate hears the pause and finishes the sentence.
    private func sendSilence() {
        let quiet = Date().timeIntervalSince(lastSound)
        guard socket != nil, !stopping, quiet > Self.silenceAfter, quiet < Self.silenceFor else { return }
        send([Int16](repeating: 0, count: GeminiLive.chunkSamples * 2))
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            guard !self.stopping, !self.refused else { return }
            self.lastSound = Date()
            // Away, the sound is dropped; before the first connection (or between sessions), the
            // last few seconds wait for it.
            guard !self.away else { return }
            guard self.socket != nil else {
                self.pending += samples
                let keep = Int(GeminiLive.sampleRate * 5)
                if self.pending.count > keep { self.pending.removeFirst(self.pending.count - keep) }
                return
            }
            self.send(samples)
        }
    }

    /// On `queue`: sound to the socket, 100 ms a message; every second sent is billed.
    private func send(_ samples: [Int16]) {
        pending += samples
        while pending.count >= GeminiLive.chunkSamples {
            let chunk = Array(pending.prefix(GeminiLive.chunkSamples))
            pending.removeFirst(GeminiLive.chunkSamples)
            socket?.send(.string(GeminiLive.audioMessage(chunk))) { _ in }
            sentSeconds += Double(chunk.count) / GeminiLive.sampleRate
        }
        if sentSeconds >= 5 {
            let seconds = sentSeconds
            sentSeconds = 0
            Task { @MainActor in FollowingState.shared.report(.audio(seconds)) }
        }
    }

    /// The end of the stream is sent and the last Chinese read for 1.5 s; then the run ends: lines
    /// already ended keep what they have, later lines go to the text model.
    func stop() async {
        let socket = queue.sync { () -> URLSessionWebSocketTask? in
            stopping = true
            return self.socket
        }
        if let socket {
            socket.send(.string(GeminiLive.streamEnd)) { _ in }
            try? await Task.sleep(for: .milliseconds(1500))
        }
        let seconds = queue.sync { () -> Double in
            running = false
            self.socket = nil
            defer { sentSeconds = 0 }
            return sentSeconds
        }
        ticker?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        let run = self.run
        await MainActor.run {
            if seconds > 0 { FollowingState.shared.report(.audio(seconds)) }
            FollowingState.shared.off(run: run)
        }
    }
}
