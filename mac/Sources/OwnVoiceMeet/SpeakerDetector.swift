// Speakers told apart by voice, on this Mac (sherpa-onnx, as in the first version): silero VAD cuts
// the sound into stretches of speech, CAM++ (3D-Speaker) turns each into a voice print, and
// VoiceClusters (Core) decides whose it is. Caption lines then take the speaker of the stretch that
// overlaps them most. The two models (about 32 MB) are downloaded once, checked against their
// SHA-256. Nothing is sent anywhere.

import AVFoundation
import CryptoKit
import CSherpaOnnx
import Foundation
import Observation
import OwnVoiceCore

/// The models, where they live, and whether they are here.
@MainActor
@Observable
final class SpeakerModels {
    struct File: Sendable {
        let name: String
        let url: URL
        let sha256: String
    }

    // Constant paths, read from the detector's own queue too.
    nonisolated static let files = [
        File(name: "silero_vad_v5.onnx",
             url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad_v5.onnx")!,
             sha256: "6b99cbfd39246b6706f98ec13c7c50c6b299181f2474fa05cbc8046acc274396"),
        File(name: "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
             url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")!,
             sha256: "98daf9bcf1c8abf3db374fec4c27a5eda7c58705bb3f180d057b085a72a88bb5"),
    ]

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OwnVoice Meet/models")
    }

    nonisolated static func path(_ file: File) -> URL { folder.appendingPathComponent(file.name) }

    private(set) var ready = SpeakerModels.allPresent()
    private(set) var downloading = false
    private(set) var message = ""

    nonisolated private static func allPresent() -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: path($0).path) }
    }

    /// Downloads whatever is missing; nothing is kept that fails its checksum.
    func download() async {
        guard !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for (i, file) in Self.files.enumerated() where !FileManager.default.fileExists(atPath: Self.path(file).path) {
                message = String(localized: "Downloading the voice models (\(String(i + 1)) of \(String(Self.files.count)))…")
                let (temp, response) = try await URLSession.shared.download(from: file.url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw AppError(String(localized: "The voice models could not be downloaded."))
                }
                let digest = SHA256.hash(data: try Data(contentsOf: temp)).map { String(format: "%02x", $0) }.joined()
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: temp)
                    throw AppError(String(localized: "A voice model did not match its checksum, so it was not kept."))
                }
                try? FileManager.default.removeItem(at: Self.path(file))
                try FileManager.default.moveItem(at: temp, to: Self.path(file))
            }
            ready = Self.allPresent()
            message = ready ? String(localized: "✓ The voice models are on this Mac.") : ""
        } catch {
            message = error.localizedDescription
        }
    }
}

/// One listening session's speaker detection. Fed from the audio thread; the voice prints are
/// worked out on a queue of its own, so the audio never waits for them.
final class SpeakerDetector: @unchecked Sendable {
    private static let rate = 16_000
    private let queue = DispatchQueue(label: "speaker-detection", qos: .utility)
    private let converter = BufferConverter(to: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!)
    private let vad: OpaquePointer
    private let extractor: OpaquePointer
    private let dim: Int
    private let sessionStart: Date
    /// Where sample 0 falls on the session's clock (seconds from its start): known once the first
    /// sound arrives, which can be a while after the session started (a permission prompt, say).
    private var offset: TimeInterval?
    private var pending: [Float] = []
    private var clusters = VoiceClusters()
    private var stretches: [VoiceStretch] = []

    /// nil when the models cannot be loaded.
    init?(sessionStart: Date) {
        let vadPath = SpeakerModels.path(SpeakerModels.files[0]).path
        let embedPath = SpeakerModels.path(SpeakerModels.files[1]).path
        let vad: OpaquePointer? = vadPath.withCString { model in
            "cpu".withCString { provider in
                var c = SherpaOnnxVadModelConfig()
                c.silero_vad.model = model
                c.silero_vad.threshold = 0.5
                c.silero_vad.min_silence_duration = 0.4
                c.silero_vad.min_speech_duration = 0.25
                // Longer speech is cut here, so a speaker who never pauses is still printed often.
                c.silero_vad.max_speech_duration = 10
                c.silero_vad.window_size = 512
                c.sample_rate = Int32(Self.rate)
                c.num_threads = 1
                c.provider = provider
                return SherpaOnnxCreateVoiceActivityDetector(&c, 60)
            }
        }
        let extractor: OpaquePointer? = embedPath.withCString { model in
            "cpu".withCString { provider in
                var c = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                c.model = model
                c.num_threads = 1
                c.provider = provider
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&c)
            }
        }
        guard let vad, let extractor else {
            if let vad { SherpaOnnxDestroyVoiceActivityDetector(vad) }
            if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }
            return nil
        }
        self.vad = vad
        self.extractor = extractor
        dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))
        self.sessionStart = sessionStart
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
        SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor)
    }

    /// Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let channel = converted.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        let arrived = Date()
        queue.async {
            if self.offset == nil {
                self.offset = max(0, arrived.timeIntervalSince(self.sessionStart) - Double(samples.count) / Double(Self.rate))
            }
            self.pending += samples
            let whole = self.pending.count / 512 * 512
            var i = 0
            while i < whole {
                self.pending.withUnsafeBufferPointer { p in
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(self.vad, p.baseAddress! + i, 512)
                }
                i += 512
            }
            self.pending.removeFirst(whole)
            self.drain()
        }
    }

    /// Listening stopped: the stretch still going on is printed too.
    func finish() {
        queue.sync {
            SherpaOnnxVoiceActivityDetectorFlush(vad)
            drain()
        }
    }

    /// The speaker (a cluster: 0, 1, 2…) of the session's `from…to`, once its stretch is printed.
    /// Asked without blocking: the queue may be busy working out a voice print.
    func speaker(from: TimeInterval, to: TimeInterval) async -> Int? {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: VoiceStretch.speaker(in: self.stretches, from: from, to: to)) }
        }
    }

    /// On `queue`: every finished stretch becomes a voice print and is given a speaker.
    private func drain() {
        while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
            let start = Double(segment.pointee.start) / Double(Self.rate)
            let n = Int(segment.pointee.n)
            if let samples = segment.pointee.samples, n > 0, let print = voicePrint(samples, count: n) {
                let seconds = Double(n) / Double(Self.rate)
                let who = clusters.assign(print, seconds: Float(seconds))
                let base = offset ?? 0
                stretches.append(VoiceStretch(start: base + start, end: base + start + seconds, speaker: who))
                if stretches.count > 600 { stretches.removeFirst(stretches.count - 600) }
            }
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }
    }

    private func voicePrint(_ samples: UnsafeMutablePointer<Float>, count: Int) -> [Float]? {
        guard let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Self.rate), samples, Int32(count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        return Array(UnsafeBufferPointer(start: v, count: dim))
    }
}
