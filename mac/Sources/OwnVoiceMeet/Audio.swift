// Where the sound comes from: what the Mac plays (ScreenCaptureKit, for an online meeting) or a
// microphone (AVAudioEngine, for a talk in the room). Either hands over buffers in its own format;
// each recognizer converts them to what it needs (BufferConverter).

import AVFoundation
import CoreMedia
import ScreenCaptureKit

protocol AudioSource: AnyObject {
    /// Start delivering buffers (on an audio thread) until stop().
    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws
    func stop()
}

func makeAudioSource(_ input: AudioInput) -> AudioSource {
    switch input {
    case .system: SystemAudioSource()
    case .microphone: MicrophoneSource()
    }
}

final class MicrophoneSource: AudioSource {
    private let engine = AVAudioEngine()

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw AppError(String(localized: "Microphone access is off: turn on OwnVoice Meet in System Settings → Privacy & Security → Microphone."))
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// The Mac's own output, whatever plays it, without this app's sound. macOS asks once for
/// Screen & System Audio Recording permission; the video is captured at 2×2 pixels and dropped.
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput {
    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "system-audio")

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.onBuffer = onBuffer
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw AppError(String(localized: "No permission to hear the Mac's sound: turn on OwnVoice Meet in System Settings → Privacy & Security → Screen & System Audio Recording, then start again."))
        }
        guard let display = content.displays.first else { throw AppError(String(localized: "No display found to capture sound from.")) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buffer = sampleBuffer.pcmBuffer() else { return }
        onBuffer?(buffer)
    }
}

extension CMSampleBuffer {
    /// The audio in this sample buffer as a PCM buffer of the same format.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription,
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Buffers of any format in, buffers of `output` out (mono 16 kHz for Gemini, the analyzer's format
/// for Apple recognition). The converter is remade when the input format changes.
final class BufferConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to output: AVAudioFormat) {
        self.output = output
    }

    static let pcm16k = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

extension AVAudioPCMBuffer {
    /// The first channel of a 16-bit buffer.
    var int16Samples: [Int16] {
        guard let channel = int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(frameLength)))
    }
}
