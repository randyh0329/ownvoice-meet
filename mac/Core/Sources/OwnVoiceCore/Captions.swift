// Caption lines as the screen shows them: a line opens with the first words heard (gray), changes
// while the sentence goes on, ends when the recognizer finalizes it (white, then translated). An
// empty final drops the line. A final that is only the last few words of a long line already shown
// keeps the line (Transcript.keepShown).

import Foundation

public struct CaptionLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public var heard: String
    public var translation: String = ""
    public var isFinal: Bool = false
    /// Who said it: an index into the user's speaker list (names can change; lines follow).
    public var speaker: Int?

    public init(id: Int, heard: String, translation: String = "", isFinal: Bool = false, speaker: Int? = nil) {
        self.id = id
        self.heard = heard
        self.translation = translation
        self.isFinal = isFinal
        self.speaker = speaker
    }
}

public struct CaptionBook: Sendable {
    public private(set) var lines: [CaptionLine] = []
    private var nextID = 1
    private var openID: Int?
    /// Who is speaking now, as the user set it: new lines get this speaker.
    public var speaker: Int?
    /// Older lines leave the screen (the transcript, later, keeps them all).
    public static let maxLines = 400

    public init() {}

    /// What has been heard of the sentence still going on. Returns its line.
    @discardableResult
    public mutating func partial(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return openID }
        if let id = openID, let i = index(of: id) {
            lines[i].heard = t
            return id
        }
        let id = take()
        lines.append(CaptionLine(id: id, heard: t, speaker: speaker))
        openID = id
        trim()
        return id
    }

    /// The sentence ended with `text`. Returns the line to translate, nil when nothing came of it.
    @discardableResult
    public mutating func finish(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = openID, let i = index(of: id) {
            openID = nil
            let kept = Transcript.keepShown(shown: lines[i].heard, final: t)
            if kept.isEmpty {
                lines.remove(at: i)
                return nil
            }
            lines[i].heard = kept
            lines[i].isFinal = true
            return id
        }
        openID = nil
        guard !t.isEmpty else { return nil }
        let id = take()
        lines.append(CaptionLine(id: id, heard: t, isFinal: true, speaker: speaker))
        trim()
        return id
    }

    // Lines a recognizer manages itself (Live Translate keeps several open at once).

    /// A new gray line, not the "open" one partial/finish work on.
    public mutating func openLine() -> Int {
        let id = take()
        lines.append(CaptionLine(id: id, heard: "", speaker: speaker))
        trim()
        return id
    }

    public mutating func setHeard(_ text: String, for id: Int, final: Bool) {
        guard let i = index(of: id) else { return }
        lines[i].heard = text
        if final { lines[i].isFinal = true }
    }

    public mutating func removeLine(_ id: Int) {
        if let i = index(of: id) { lines.remove(at: i) }
        if openID == id { openID = nil }
    }

    public mutating func setTranslation(_ text: String, for id: Int) {
        if let i = index(of: id) { lines[i].translation = text }
    }

    /// The user says who said line `id` (nil: nobody in particular).
    public mutating func setSpeaker(_ speaker: Int?, for id: Int) {
        if let i = index(of: id) { lines[i].speaker = speaker }
    }

    public func line(_ id: Int) -> CaptionLine? {
        index(of: id).map { lines[$0] }
    }

    public func heard(_ id: Int) -> String? {
        index(of: id).map { lines[$0].heard }
    }

    /// The finished lines before `id`, oldest first: context for its translation.
    public func context(before id: Int, count: Int = 6) -> [String] {
        Array(lines.filter { $0.id < id && $0.isFinal }.suffix(count).map(\.heard))
    }

    public mutating func clear() {
        lines.removeAll()
        openID = nil
    }

    private mutating func take() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func index(of id: Int) -> Int? {
        lines.lastIndex { $0.id == id }
    }

    private mutating func trim() {
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }
}

/// Fixes for what streaming recognizers send.
public enum Transcript {
    /// The final text, or the line already shown when the final is only its last few words. On a
    /// Mac's microphone (2026-11-22) a line shown from its first sentence on was finalized as
    /// "20 years", the end of the second; the reader had seen both sentences.
    public static func keepShown(shown: String, final fin: String) -> String {
        func words(_ t: String) -> [String] {
            t.split(whereSeparator: \.isWhitespace)
                .map { String($0.filter { $0.isLetter || $0.isNumber }).lowercased() }
                .filter { !$0.isEmpty }
        }
        let (s, f) = (words(shown), words(fin))
        let tail = !f.isEmpty && s.count >= 8 && f.count * 2 < s.count && Array(s.suffix(f.count)) == f
        return tail ? shown : fin
    }

    /// Gemini joins the sentences of one long turn with no space ("the moderator.Our first"): a
    /// space goes back after a sentence end that follows a lowercase letter or digit and comes
    /// before a capital, which leaves initials and abbreviations ("U.S.A.") alone.
    public static func sentenceGaps(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        for (i, c) in chars.enumerated() {
            out.append(c)
            let ends = c == "." || c == "?" || c == "!"
            let before = i > 0 && (chars[i - 1].isLowercase || chars[i - 1].isNumber)
            let next = i + 1 < chars.count && chars[i + 1].isUppercase
            if ends && before && next { out.append(" ") }
        }
        return out
    }
}
