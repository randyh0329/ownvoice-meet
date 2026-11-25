// Energy-based speech segmentation, carried over from the first version, where it was tuned on
// meeting audio played through the speakers: 30 ms frames, speech above an RMS threshold, 300 ms
// kept from before the onset, an utterance ends after 700 ms of silence or 12 s of speech.
// Upload-per-sentence recognizers take `end`; streaming ones send `start` and `audio` as they come
// and commit on `end`, so silence between sentences is never sent (and never billed).

import Foundation

public enum SegmentEvent: Equatable, Sendable {
    /// Speech began; the audio just before it, so the first word is not clipped.
    case start([Int16])
    /// More audio of the current utterance.
    case audio([Int16])
    /// The utterance ended; all of its audio (preroll included).
    case end([Int16])
    /// What looked like speech was too short to be speech (a click, a cough).
    case discard
}

public struct Segmenter: Sendable {
    public static let rmsThreshold: Float = 0.008
    static let frameMs = 30, prerollMs = 300, endSilenceMs = 700, maxUtteranceMs = 12_000, minVoicedMs = 300

    private let frame: Int
    private var pending: [Int16] = []
    private var preroll: [[Int16]] = []
    private var utterance: [Int16] = []
    public private(set) var inSpeech = false
    private var silentFrames = 0, voicedFrames = 0, totalFrames = 0

    public init(rate: Int) {
        frame = rate * Self.frameMs / 1000
    }

    public mutating func push(_ chunk: [Int16]) -> [SegmentEvent] {
        pending += chunk
        var events: [SegmentEvent] = []
        var audio: [Int16] = []
        while pending.count >= frame {
            let f = Array(pending.prefix(frame))
            pending.removeFirst(frame)
            let sum = f.reduce(Float(0)) { $0 + (Float($1) / 32768) * (Float($1) / 32768) }
            let voiced = (sum / Float(f.count)).squareRoot() > Self.rmsThreshold
            if !inSpeech {
                if voiced {
                    inSpeech = true
                    let pre = preroll.flatMap { $0 }
                    preroll.removeAll()
                    utterance = pre + f
                    silentFrames = 0
                    voicedFrames = 1
                    totalFrames = 1
                    events.append(.start(pre + f))
                } else {
                    preroll.append(f)
                    if preroll.count > Self.prerollMs / Self.frameMs { preroll.removeFirst() }
                }
                continue
            }
            utterance += f
            audio += f
            totalFrames += 1
            if voiced {
                voicedFrames += 1
                silentFrames = 0
            } else {
                silentFrames += 1
            }
            if silentFrames * Self.frameMs >= Self.endSilenceMs || totalFrames * Self.frameMs >= Self.maxUtteranceMs {
                if !audio.isEmpty {
                    events.append(.audio(audio))
                    audio = []
                }
                inSpeech = false
                let utt = utterance
                utterance = []
                events.append(voicedFrames * Self.frameMs >= Self.minVoicedMs ? .end(utt) : .discard)
            }
        }
        if !audio.isEmpty { events.append(.audio(audio)) }
        return events
    }
}

public enum WAV {
    /// 16-bit mono PCM as a WAV file, for upload-per-sentence recognizers.
    public static func data(_ samples: [Int16], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataLen = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataLen)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
