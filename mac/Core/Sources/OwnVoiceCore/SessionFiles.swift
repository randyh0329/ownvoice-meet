// What a saved session writes into its folder: transcript.md (every finished line with its
// translation, timed from the start) and summary.md (the live summary as last brought up to date).

import Foundation

public struct TranscriptLine: Equatable, Sendable {
    public let offset: TimeInterval
    public let heard: String
    public let translation: String

    public init(offset: TimeInterval, heard: String, translation: String) {
        self.offset = offset
        self.heard = heard
        self.translation = translation
    }
}

public enum SessionFiles {
    /// "2026-11-25 1405": the session's folder name, sortable.
    public static func folderName(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    public static func hms(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// `header`: lines like "Started: …", "Recognition: …", each written as a list item.
    public static func transcript(title: String, header: [String], lines: [TranscriptLine]) -> String {
        var out = "# \(title)\n\n" + header.map { "- \($0)\n" }.joined() + "\n"
        for l in lines where !l.heard.trimmingCharacters(in: .whitespaces).isEmpty {
            out += "[\(hms(l.offset))] \(l.heard.trimmingCharacters(in: .whitespacesAndNewlines))\n"
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
            return "[\(clock(l.offset))] \(l.heard.trimmingCharacters(in: .whitespacesAndNewlines))" + (zh.isEmpty ? "" : "\n  （\(zh)）")
        }.joined(separator: "\n")
    }
}
