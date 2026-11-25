// Telling speakers apart by voice (as in the first version, checked on a real 47-minute
// roundtable): each stretch of speech becomes a voice print; a stretch joins the closest speaker met
// so far when they are alike enough (cosine similarity at least `threshold`), a stretch shorter than
// `minNew` seconds keeps the speaker who was talking (too short to found a new one), and each
// speaker's print is the running mean of their stretches. Caption lines then take the speaker of
// the stretch that overlaps them most. The prints come from the app (sherpa-onnx, CAM++); this is
// only the bookkeeping.

import Foundation

public struct VoiceClusters: Sendable {
    public static let threshold: Float = 0.4
    public static let minNew: Float = 2.0

    private var means: [[Float]] = []
    private var counts: [Float] = []
    private var previous: Int?

    public init() {}

    public var count: Int { means.count }

    /// The speaker (0, 1, 2…) of a stretch `seconds` long with voice print `print`.
    public mutating func assign(_ print: [Float], seconds: Float) -> Int {
        let norm = { (v: [Float]) in max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9) }
        let n = norm(print)
        let e = print.map { $0 / n }
        var best: (Int, Float)?
        for (k, m) in means.enumerated() {
            let sim = zip(m, e).reduce(Float(0)) { $0 + $1.0 * $1.1 } / norm(m)
            if best == nil || sim > best!.1 { best = (k, sim) }
        }
        let who: Int
        if let (k, sim) = best, sim >= Self.threshold {
            who = k
        } else if let p = previous, seconds < Self.minNew {
            who = p
        } else {
            means.append(Array(repeating: 0, count: e.count))
            counts.append(0)
            who = means.count - 1
        }
        let c = counts[who]
        means[who] = zip(means[who], e).map { ($0 * c + $1) / (c + 1) }
        counts[who] = c + 1
        previous = who
        return who
    }
}

/// A stretch of speech on the session's clock (seconds from the start) and who spoke it.
public struct VoiceStretch: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let speaker: Int

    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }

    /// The speaker of the stretch that overlaps `from…to` the most; nil when none does.
    public static func speaker(in stretches: [VoiceStretch], from: TimeInterval, to: TimeInterval) -> Int? {
        var best: (Int, TimeInterval)?
        for s in stretches {
            let overlap = min(s.end, to) - max(s.start, from)
            if overlap > 0, best == nil || overlap > best!.1 { best = (s.speaker, overlap) }
        }
        return best?.0
    }
}
