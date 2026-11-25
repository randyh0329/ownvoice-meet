// What a saved session writes into its folder: transcript.md (every finished line with its
// translation, timed from the start) and summary.md (the live summary as last brought up to date).

import Foundation

public struct TranscriptLine: Equatable, Sendable {
    public let offset: TimeInterval
    public let heard: String
    public let translation: String
    /// Which segment it belongs to (0 = the first).
    public let segment: Int
    /// Who said it, by name; empty when not set.
    public let speaker: String

    public init(offset: TimeInterval, heard: String, translation: String, segment: Int = 0, speaker: String = "") {
        self.offset = offset
        self.heard = heard
        self.translation = translation
        self.segment = segment
        self.speaker = speaker
    }
}

/// A stretch of the session the user marked ("New Segment"), from `offset` on.
public struct Segment: Equatable, Sendable {
    public let name: String
    public let offset: TimeInterval

    public init(name: String, offset: TimeInterval) {
        self.name = name
        self.offset = offset
    }
}

public enum SessionFiles {
    /// "2026-11-25 1405": the session's folder name, sortable.
    public static func folderName(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `base`, or "base 2", "base 3"… when that name is taken.
    public static func uniqueName(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// `header`: lines like "Started: …", "Recognition: …", each written as a list item.
    /// With more than one segment, each gets a heading: "## 02 · Q&A (00:41:10)".
    public static func transcript(title: String, header: [String], segments: [Segment] = [], lines: [TranscriptLine]) -> String {
        var out = "# \(title)\n\n" + header.map { "- \($0)\n" }.joined() + "\n"
        var current = -1
        for l in lines where !l.heard.trimmingCharacters(in: .whitespaces).isEmpty {
            if segments.count > 1, l.segment != current, l.segment < segments.count {
                current = l.segment
                out += "## \(String(format: "%02d", current + 1)) · \(segments[current].name) (\(hms(segments[current].offset)))\n\n"
            }
            let who = l.speaker.isEmpty ? "" : "\(l.speaker)："
            out += "[\(hms(l.offset))] \(who)\(l.heard.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            let zh = l.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !zh.isEmpty { out += "　\(zh)\n" }
            out += "\n"
        }
        return out
    }

    public static func summary(title: String, updated: String, text: String) -> String {
        "# \(title)\n\n\(updated)\n\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// The lines for the summary model: time, what was said, then the Chinese meaning.
    public static func forSummary(_ lines: [TranscriptLine], clock: (TimeInterval) -> String) -> String {
        lines.filter { !$0.heard.trimmingCharacters(in: .whitespaces).isEmpty }.map { l in
            let zh = l.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let who = l.speaker.isEmpty ? "" : "\(l.speaker): "
            return "[\(clock(l.offset))] \(who)\(l.heard.trimmingCharacters(in: .whitespacesAndNewlines))" + (zh.isEmpty ? "" : "\n  （\(zh)）")
        }.joined(separator: "\n")
    }
}
