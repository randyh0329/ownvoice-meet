// Recognition on this Mac, free and offline (sherpa-onnx, as in the first version): NVIDIA Parakeet
// for English and other European languages, SenseVoice for Chinese, Japanese and Korean. The
// energy segmenter cuts sentences as for the sentence-by-sentence services; a gray "…" shows while
// someone talks and the words arrive once the sentence ends, about half a second to a second later.
// With the meeting language on automatic, each sentence picks its own model (LocalSpeech in Core).
// The models (about 910 MB) are downloaded once, each file checked against its SHA-256, into the
// same folder as the voice models. Nothing is sent anywhere.

import AVFoundation
import CryptoKit
import CSherpaOnnx
import Foundation
import Observation
import OwnVoiceCore
import SwiftUI

/// The recognition models: where they live, whether they are here, and their download.
@MainActor
@Observable
final class LocalSpeechModels {
    static let shared = LocalSpeechModels()

    nonisolated static func path(_ file: LocalSpeech.ModelFile) -> URL {
        SpeakerModels.folder.appendingPathComponent(file.name)
    }

    /// Whole when its size is right: a file is only put in place after its checksum matched.
    nonisolated static func isPresent(_ file: LocalSpeech.ModelFile) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path(file).path)[.size] as? NSNumber)?.int64Value
        return size == file.bytes
    }

    nonisolated static func allPresent() -> Bool { LocalSpeech.files.allSatisfy(isPresent) }

    private(set) var ready = LocalSpeechModels.allPresent()
    private(set) var downloading = false
    /// 0…1 while downloading.
    private(set) var progress: Double?
    private(set) var message = ""
    private var task: Task<Void, Never>?

    /// The models' size, as Settings shows it ("910.2 MB").
    static var sizeText: String {
        ByteCountFormatter.string(fromByteCount: LocalSpeech.totalBytes, countStyle: .file)
    }

    /// Downloads whatever is missing; nothing is kept that fails its checksum.
    func download() {
        guard !downloading else { return }
        downloading = true
        message = ""
        task = Task {
            defer {
                downloading = false
                progress = nil
                task = nil
            }
            do {
                let total = Double(LocalSpeech.totalBytes)
                var done: Int64 = LocalSpeech.files.filter(Self.isPresent).reduce(0) { $0 + $1.bytes }
                progress = Double(done) / total
                for file in LocalSpeech.files where !Self.isPresent(file) {
                    message = String(localized: "Downloading the recognition models…")
                    let target = Self.path(file)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let part = target.appendingPathExtension("part")
                    let before = done
                    try await FileDownload.run(file.url, to: part) { written in
                        Task { @MainActor in
                            if self.downloading { self.progress = Double(before + written) / total }
                        }
                    }
                    try Task.checkCancellation()
                    message = String(localized: "Checking the download…")
                    let digest = try await Task.detached { try Self.sha256(of: part) }.value
                    guard digest == file.sha256 else {
                        try? FileManager.default.removeItem(at: part)
                        throw AppError(String(localized: "A recognition model did not match its checksum, so it was not kept. Try again."))
                    }
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: part, to: target)
                    done += file.bytes
                    progress = Double(done) / total
                }
                ready = Self.allPresent()
                message = ready ? String(localized: "✓ The recognition models are on this Mac.") : ""
            } catch is CancellationError {
                message = String(localized: "Download cancelled.")
            } catch let error as URLError where error.code == .cancelled {
                message = String(localized: "Download cancelled.")
            } catch {
                message = String(localized: "The recognition models could not be downloaded: \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Frees the disk space; they can be downloaded again.
    func delete() {
        guard !downloading else { return }
        for folder in LocalSpeech.folders {
            try? FileManager.default.removeItem(at: SpeakerModels.folder.appendingPathComponent(folder))
        }
        ready = Self.allPresent()
        message = String(localized: "The recognition models were deleted.")
    }

    /// Whether any of the files (or a partial download) is on disk.
    var anyOnDisk: Bool {
        LocalSpeech.folders.contains { FileManager.default.fileExists(atPath: SpeakerModels.folder.appendingPathComponent($0).path) }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One file downloaded to `destination`, reporting the bytes written so far (about every megabyte).
/// Cancelling the task cancels the download.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Int64) -> Void
    // Touched only on the session's own (serial) delegate queue, after `run` set the continuation.
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var moved = false
    private var cancelled = false
    private var reported: Int64 = 0

    private init(destination: URL, onProgress: @escaping (Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(_ url: URL, to destination: URL, onProgress: @escaping (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, onProgress: onProgress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        // Starting and cancelling both happen on the delegate queue, so one cannot overtake the other.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    guard !download.cancelled else {
                        c.resume(throwing: CancellationError())
                        return
                    }
                    download.continuation = c
                    session.downloadTask(with: url).resume()
                }
            }
        } onCancel: {
            queue.addOperation {
                download.cancelled = true
                session.invalidateAndCancel()
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten - reported >= 1 << 20 {
            reported = totalBytesWritten
            onProgress(totalBytesWritten)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns: it is moved now.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            failure = AppError(String(localized: "The server did not send the file."))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let c = continuation
        continuation = nil
        if let error = error ?? failure {
            c?.resume(throwing: error)
        } else if moved {
            c?.resume()
        } else {
            c?.resume(throwing: AppError(String(localized: "The server did not send the file.")))
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Cancelled before the task finished (invalidateAndCancel): the wait ends too.
        let c = continuation
        continuation = nil
        c?.resume(throwing: error ?? CancellationError())
    }
}

/// One listening session's recognition on this Mac. Sentences are cut on a queue of their own and
/// recognized, one at a time and in order, on another, so the audio thread never waits.
final class LocalRecognizer: Recognizer, @unchecked Sendable {
    private static let rate = 16_000
    private let route: LocalSpeech.Route
    private let senseVoiceHint: String
    private let chinese: ChineseVariant
    private let converter = BufferConverter(to: BufferConverter.pcm16k)
    private let queue = DispatchQueue(label: "local-speech-segments")
    private let decoder = DispatchQueue(label: "local-speech-decode", qos: .userInitiated)
    // On `queue`:
    private var segmenter = Segmenter(rate: 16_000)
    private var lastAudio = Date()
    private var stopped = false
    private var timer: DispatchSourceTimer?
    // On `decoder` (after start):
    private var parakeet: OpaquePointer?
    private var senseVoice: OpaquePointer?
    private var onEvent: ((RecognitionEvent) -> Void)?

    /// Fails at once (before anything starts) when the models are not downloaded yet.
    init(language: String, chinese: ChineseVariant) throws {
        guard LocalSpeechModels.allPresent() else {
            throw AppError(String(localized: "Download the on-device recognition models in Settings first."))
        }
        route = LocalSpeech.route(language)
        senseVoiceHint = LocalSpeech.senseVoiceHint(language)
        self.chinese = chinese
    }

    deinit {
        if let parakeet { SherpaOnnxDestroyOfflineRecognizer(parakeet) }
        if let senseVoice { SherpaOnnxDestroyOfflineRecognizer(senseVoice) }
    }

    func start(onEvent: @escaping (RecognitionEvent) -> Void) async throws {
        self.onEvent = onEvent
        onEvent(.status(String(localized: "Loading the on-device recognition models…")))
        let route = route, hint = senseVoiceHint
        // Loading a gigabyte of models takes a few seconds: off the main thread.
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            decoder.async {
                if route != .senseVoice { self.parakeet = Self.makeParakeet() }
                if route != .parakeet { self.senseVoice = Self.makeSenseVoice(hint: hint) }
                done.resume(returning: (route == .senseVoice || self.parakeet != nil) && (route == .parakeet || self.senseVoice != nil))
            }
        }
        guard loaded else {
            freeModels()
            throw AppError(String(localized: "The on-device recognition models could not be loaded. Delete them in Settings and download them again."))
        }
        onEvent(.status(String(localized: "Listening (on this Mac, nothing is sent)")))
        // The Mac's sound arrives only while something plays: when it stops mid-sentence, silence
        // is fed in, so the sentence still ends.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.segmenter.inSpeech, Date().timeIntervalSince(self.lastAudio) > 0.25 else { return }
            for event in self.segmenter.push([Int16](repeating: 0, count: Self.rate / 10)) { self.handle(event) }
        }
        timer.resume()
        queue.sync { self.timer = timer }
    }

    private static func makeParakeet() -> OpaquePointer? {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(rate)
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = c(LocalSpeechModels.path(LocalSpeech.parakeetEncoder).path)
        config.model_config.transducer.decoder = c(LocalSpeechModels.path(LocalSpeech.parakeetDecoder).path)
        config.model_config.transducer.joiner = c(LocalSpeechModels.path(LocalSpeech.parakeetJoiner).path)
        config.model_config.tokens = c(LocalSpeechModels.path(LocalSpeech.parakeetTokens).path)
        config.model_config.model_type = c("nemo_transducer")
        // One thread: with more, onnxruntime's idle threads spin and burn a core for nothing.
        config.model_config.num_threads = 1
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        return SherpaOnnxCreateOfflineRecognizer(&config)
    }

    private static func makeSenseVoice(hint: String) -> OpaquePointer? {
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { strings.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            strings.append(p)
            return UnsafePointer(p)
        }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(rate)
        config.feat_config.feature_dim = 80
        config.model_config.sense_voice.model = c(LocalSpeechModels.path(LocalSpeech.senseVoiceModel).path)
        config.model_config.sense_voice.language = c(hint)
        // Numbers as digits, with punctuation.
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = c(LocalSpeechModels.path(LocalSpeech.senseVoiceTokens).path)
        config.model_config.num_threads = 1
        config.model_config.provider = c("cpu")
        config.decoding_method = c("greedy_search")
        return SherpaOnnxCreateOfflineRecognizer(&config)
    }

    /// Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        let samples = converted.int16Samples
        queue.async {
            guard !self.stopped else { return }
            self.lastAudio = Date()
            for event in self.segmenter.push(samples) { self.handle(event) }
        }
    }

    /// On `queue`.
    private func handle(_ event: SegmentEvent) {
        switch event {
        case .start: onEvent?(.partial("…"))
        case .audio: break
        case .end(let utterance): recognize(utterance)
        case .discard: onEvent?(.final(""))
        }
    }

    /// On `queue`: the sentence waits its turn on `decoder`.
    private func recognize(_ utterance: [Int16]) {
        decoder.async {
            let text = self.text(of: utterance)
            self.onEvent?(.audio(Double(utterance.count) / Double(Self.rate)))
            self.onEvent?(.final(text))
            // Someone already speaking again gets the "…" back (the line just finished took it).
            self.queue.async {
                if !self.stopped, self.segmenter.inSpeech { self.onEvent?(.partial("…")) }
            }
        }
    }

    /// On `decoder`: the words of one sentence.
    private func text(of utterance: [Int16]) -> String {
        let samples = utterance.map { Float($0) / 32768 }
        if let senseVoice {
            let (text, language) = Self.decode(senseVoice, samples)
            switch LocalSpeech.outcome(route: route, text: text, language: language) {
            case let .senseVoice(text, isChinese): return isChinese ? chinese.fix(text) : text
            case .parakeet: break
            }
        }
        guard let parakeet else { return "" }
        return Self.decode(parakeet, samples).text
    }

    private static func decode(_ recognizer: OpaquePointer, _ samples: [Float]) -> (text: String, language: String) {
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return ("", "") }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { p in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(rate), p.baseAddress, Int32(p.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return ("", "") }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        let text = result.pointee.text.map { String(cString: $0) } ?? ""
        let language = result.pointee.lang.map { String(cString: $0) } ?? ""
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), language)
    }

    /// The sentence being spoken when listening stops is recognized too (or its "…" dropped); the
    /// sentences still waiting are finished, then the models' memory (about 1 GB) is given back.
    func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let event = segmenter.finish() { handle(event) }
            stopped = true
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            decoder.async {
                self.freeModels()
                done.resume()
            }
        }
    }

    /// On `decoder` (or before it is used).
    private func freeModels() {
        if let parakeet { SherpaOnnxDestroyOfflineRecognizer(parakeet) }
        if let senseVoice { SherpaOnnxDestroyOfflineRecognizer(senseVoice) }
        parakeet = nil
        senseVoice = nil
    }
}

/// Settings: download, check and delete the recognition models.
struct LocalSpeechSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let models = LocalSpeechModels.shared
        let size = LocalSpeechModels.sizeText
        Section("Recognition models on this Mac") {
            Text(verbatim: models.ready && !models.downloading
                ? String(localized: "✓ The recognition models are on this Mac (\(size)).")
                : (models.message.isEmpty ? String(localized: "The models (\(size)) are downloaded once, each file checked against its SHA-256.") : models.message))
            if let p = models.progress {
                let done = ByteCountFormatter.string(fromByteCount: Int64(p * Double(LocalSpeech.totalBytes)), countStyle: .file)
                ProgressView(value: p) {
                    Text(verbatim: String(localized: "\(done) of \(size)"))
                        .font(.caption)
                }
            }
            HStack {
                if models.downloading {
                    Button("Cancel") { models.cancel() }
                } else if !models.ready {
                    Button("Download the Models") { models.download() }
                }
                if !models.downloading && models.anyOnDisk {
                    Button("Delete the Models", role: .destructive) { models.delete() }
                        .disabled(model.isListening && model.settings.listen == .localSherpa)
                }
            }
            Text("NVIDIA Parakeet hears English and 24 other European languages; SenseVoice hears Chinese, Japanese and Korean, and its Chinese is written in the Chinese chosen below. Recognized on this Mac: no key, nothing is sent. While listening it uses about 1 GB of memory, given back when you stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
