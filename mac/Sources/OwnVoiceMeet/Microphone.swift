// A talk in the room: which microphone (Core Audio's input devices), how loud it comes in (a level
// meter fed from the audio thread a few times a second, not per buffer), and the 6-second
// Microphone Check in Settings that says whether the level suits speech recognition.

import AVFoundation
import CoreAudio
import Observation
import OwnVoiceCore

/// A microphone the Mac has, by Core Audio's UID (kept in the settings) and its name.
struct InputDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

enum InputDevices {
    /// Every device with an input (built-in, USB, Bluetooth, an audio interface…).
    static func all() -> [InputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(uid: uid, name: name)
        }
    }

    /// The device with this UID, if it is connected.
    static func id(uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// The name of the microphone with this UID, or of the Mac's default input for "".
    static func name(uid: String) -> String? {
        if !uid.isEmpty { return all().first { $0.uid == uid }?.name }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return string(device, kAudioObjectPropertyName)
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

extension AVAudioPCMBuffer {
    /// Multiplies every sample by `gain`, clipped (a microphone's float samples; others are left).
    func applyGain(_ gain: Float) {
        guard gain != 1, let channels = floatChannelData else { return }
        let n = Int(frameLength)
        if format.isInterleaved {
            MicLevel.apply(gain: gain, to: UnsafeMutableBufferPointer(start: channels[0], count: n * Int(format.channelCount)))
        } else {
            for c in 0..<Int(format.channelCount) {
                MicLevel.apply(gain: gain, to: UnsafeMutableBufferPointer(start: channels[c], count: n))
            }
        }
    }
}

/// Fed every buffer on the audio thread; hands the loudest level of the last tenth of a second
/// (as a meter fill, 0…1) to `onLevel` at most that often, and keeps the loudest of all.
final class LevelTap: @unchecked Sendable {
    private let lock = NSLock()
    private var recent: Float = 0
    private var loudest: Float = 0
    private var buffers = 0
    private var last = Date()
    private let onLevel: @Sendable (Double) -> Void

    init(onLevel: @escaping @Sendable (Double) -> Void) {
        self.onLevel = onLevel
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let rms = buffer.rms
        let now = Date()
        lock.lock()
        recent = max(recent, rms)
        loudest = max(loudest, rms)
        buffers += 1
        var send: Float?
        if now.timeIntervalSince(last) >= 0.1 {
            send = recent
            recent = 0
            last = now
        }
        lock.unlock()
        if let send { onLevel(MicLevel.meter(send)) }
    }

    /// The loudest level so far (root mean square of a buffer, 0…1) and how many buffers came.
    var heard: (loudest: Float, buffers: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loudest, buffers)
    }
}

/// Settings' Microphone Check: listens for 6 seconds with the chosen microphone and gain, shows
/// the level as it goes, then says whether it suits speech recognition.
@MainActor
@Observable
final class MicCheck {
    private(set) var running = false
    private(set) var level = 0.0
    private(set) var result = ""

    func run(device: String, gain: Double) async {
        guard !running else { return }
        running = true
        level = 0
        result = String(localized: "Checking: let the speaker or the room be talking…")
        let source = MicrophoneSource(device: device, gain: gain)
        let tap = LevelTap { value in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.level = value
            }
        }
        do {
            try await source.start { buffer in tap.feed(buffer) }
            try? await Task.sleep(for: .seconds(6))
            source.stop()
            let heard = tap.heard
            let name = InputDevices.name(uid: device) ?? String(localized: "Microphone")
            if heard.buffers == 0 {
                result = String(localized: "\(name) sent no sound.")
            } else {
                let percent = String(Int((heard.loudest * 100).rounded())) + "%"
                let verdict = Self.verdict(MicVerdict(peak: heard.loudest))
                result = String(localized: "\(name), loudest moment \(percent): \(verdict)")
            }
        } catch {
            source.stop()
            result = String(localized: "The check failed: \(error.localizedDescription)")
        }
        running = false
        level = 0
    }

    static func verdict(_ v: MicVerdict) -> String {
        switch v {
        case .almostSilent: String(localized: "Almost no sound. The microphone may be muted or the wrong one, or OwnVoice Meet may not be allowed to use it (System Settings → Privacy & Security → Microphone).")
        case .tooQuiet: String(localized: "Too quiet. Raise the gain one step and check again, or move the Mac closer to the speaker or the loudspeaker. The Mac's own input volume is in System Settings → Sound → Input.")
        case .tooLoud: String(localized: "Too loud, it may distort. Lower the gain one step.")
        case .fine: String(localized: "The level is fine: you can start.")
        }
    }
}
