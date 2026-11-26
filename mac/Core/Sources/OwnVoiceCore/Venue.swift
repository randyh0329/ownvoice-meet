// A talk in the room: the agenda that names the segments, the file names each segment's
// transcript and recording take, and what the microphone check makes of the level it heard.

import Foundation

public enum Agenda {
    /// One segment name per line; blank lines are skipped.
    public static func names(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The agenda's name for segment `index` (0 = the first), nil once the agenda has run out.
    public static func name(_ agenda: [String], at index: Int) -> String? {
        index >= 0 && index < agenda.count ? agenda[index] : nil
    }
}

extension SessionFiles {
    /// "03-Session 3A Digital Libraries": segment `index` (1 = the first) as a file name, safe on
    /// macOS and Windows (no slashes, colons or other reserved characters, at most 60 characters
    /// of the name, no trailing dot or space). Just "03" when nothing of the name is left.
    public static func segmentStem(_ index: Int, _ name: String) -> String {
        let reserved = Set("\\/:*?\"<>|")
        let spaced = String(name.map { c -> Character in
            let control = c.unicodeScalars.contains { $0.properties.generalCategory == .control }
            return control || reserved.contains(c) ? " " : c
        })
        var clean = String(spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(60))
        while let last = clean.last, last == "." || last == " " { clean.removeLast() }
        let number = String(format: "%02d", index)
        return clean.isEmpty ? number : "\(number)-\(clean)"
    }

    /// "02 · Q&A": a segment's heading (`index` 0 = the first).
    public static func segmentTitle(_ index: Int, _ name: String) -> String {
        "\(String(format: "%02d", index + 1)) · \(name)"
    }

    /// One segment's own transcript (`index` 0 = the first): its heading with the time it began,
    /// the session's header, then only its lines.
    public static func segmentTranscript(index: Int, header: [String], segments: [Segment], lines: [TranscriptLine]) -> String {
        guard index >= 0, index < segments.count else { return "" }
        let s = segments[index]
        let title = "\(segmentTitle(index, s.name)) (\(hms(s.offset)))"
        return transcript(title: title, header: header, lines: lines.filter { $0.segment == index })
    }
}

/// What the microphone check makes of the loudest moment it heard (the level of a stretch of
/// about a tenth of a second, after the gain, 0…1).
public enum MicVerdict: Equatable, Sendable {
    /// Muted, the wrong microphone, or no permission.
    case almostSilent
    /// Speech recognition will struggle: raise the gain or move closer.
    case tooQuiet
    /// May distort: lower the gain.
    case tooLoud
    case fine

    public init(peak: Float) {
        if peak < 0.003 {
            self = .almostSilent
        } else if peak < 0.03 {
            self = .tooQuiet
        } else if peak > 0.7 {
            self = .tooLoud
        } else {
            self = .fine
        }
    }
}

public enum MicLevel {
    /// The gain steps offered (1 = the sound as it comes).
    public static let gains: [Double] = [1, 2, 4, 8]

    /// The step nearest to `gain`, for a value saved by hand or by an older build.
    public static func nearestGain(_ gain: Double) -> Double {
        gains.min { abs($0 - gain) < abs($1 - gain) } ?? 1
    }

    /// Multiplies every sample by `gain`, clipped to -1…1 (louder, never wrapping around).
    public static func apply(gain: Float, to samples: UnsafeMutableBufferPointer<Float>) {
        guard gain != 1 else { return }
        for i in samples.indices {
            samples[i] = min(1, max(-1, samples[i] * gain))
        }
    }

    /// How full a level meter is (0…1) for a level (root mean square, 0…1): ordinary speech
    /// fills about half of it, as in the Windows app.
    public static func meter(_ rms: Float) -> Double {
        Double(min(1, max(0, rms).squareRoot() * 2.4))
    }
}
