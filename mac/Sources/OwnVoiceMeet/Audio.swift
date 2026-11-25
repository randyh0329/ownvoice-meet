// Where the sound comes from: what the Mac plays (a Core Audio tap, for an online meeting) or a
// microphone (AVAudioEngine, for a talk in the room). Either hands over buffers in its own format;
// each recognizer converts them to what it needs (BufferConverter).

import AVFoundation
import CoreAudio

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

/// The Mac's own output, whatever plays it, without this app's sound: a Core Audio process tap
/// (macOS 14.2+) on all processes but this one, read through a private aggregate device. It needs
/// only "System Audio Recording Only" (asked once), not screen recording.
final class SystemAudioSource: AudioSource {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "system-audio", qos: .userInitiated)

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let own = Self.processObject(pid: getpid())
        // The Mac keeps playing as usual (taps leave the sound unmuted unless asked).
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tap))

        guard let output = Self.defaultOutputUID() else {
            stop()
            throw AppError(String(localized: "No sound output device found."))
        }
        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OwnVoice Meet",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate))

        guard var asbd = Self.tapFormat(tap), let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw AppError(String(localized: "Could not read the format of the Mac's sound."))
        }
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { _, input, _, _, _ in
            // The buffer is only valid during this call; every consumer copies or converts at once.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            onBuffer(buffer)
        })
        try check(AudioDeviceStart(aggregate, proc))
    }

    func stop() {
        if aggregate != kAudioObjectUnknown {
            if let proc {
                AudioDeviceStop(aggregate, proc)
                AudioDeviceDestroyIOProcID(aggregate, proc)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            stop()
            throw AppError(String(localized: "Could not listen to the Mac's sound (error \(String(status))): allow OwnVoice Meet in System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only), then quit and reopen it."))
        }
    }

    /// This process as Core Audio knows it, to leave its own sound out.
    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr ? asbd : nil
    }
}

/// Watches for nothing but digital silence (what a tap without permission delivers, and what an
/// idle Mac plays): after `after` seconds of it, says so once.
final class SilenceWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var heardSomething = false
    private let started = Date()
    private var warned = false
    private let after: TimeInterval
    private let onSilence: @Sendable () -> Void

    init(after: TimeInterval, onSilence: @escaping @Sendable () -> Void) {
        self.after = after
        self.onSilence = onSilence
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let loud = buffer.peak > 0
        lock.lock()
        if loud { heardSomething = true }
        let warn = !heardSomething && !warned && Date().timeIntervalSince(started) >= after
        if warn { warned = true }
        lock.unlock()
        if warn { onSilence() }
    }
}

extension AVAudioPCMBuffer {
    /// The loudest sample of the first channel, 0…1 (any non-zero sample counts for 16-bit buffers).
    var peak: Float {
        guard let samples = floatChannelData?[0] else { return int16Samples.contains { $0 != 0 } ? 1 : 0 }
        var top: Float = 0
        for i in 0..<Int(frameLength) { top = max(top, abs(samples[i])) }
        return top
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
