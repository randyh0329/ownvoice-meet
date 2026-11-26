// Early translation, carried over from the first version (captions.rs): a sentence that keeps
// growing past `earlyAfter` without ending is translated as it stands, at most every `earlyEvery`,
// so long unbroken speech shows Chinese before the speaker pauses. Each translation of a line is a
// numbered request. As in LiveCaptions-Translator's TranslationTaskQueue (SakiRinn, Apache-2.0), a
// request that completes cancels the older ones still running, and an older request never
// overwrites a newer one. The final translation, started when the sentence ends, cancels the early
// ones and takes over the line once its text has caught up with theirs.

import Foundation

public struct LineTranslations: Sendable {
    /// A sentence still growing after this long is translated before it ends.
    public static let earlyAfter: TimeInterval = 4
    /// At most one early translation of a line this often.
    public static let earlyEvery: TimeInterval = 2
    /// Shorter interim text is not worth an early translation.
    public static let earlyMinChars = 20

    struct Line: Sendable {
        var opened: Date
        var earlyAt: Date?
        var earlyText = ""
        /// The last request number given out.
        var seq = 0
        /// The request whose Chinese is on screen, and its length in characters.
        var shownSeq = 0
        var shownLength = 0
        /// The newest request that came back whole: its pieces still on their way are stale.
        var completeSeq = 0
        var running: [Int] = []
        var finished = false
    }

    private var lines: [Int: Line] = [:]

    public init() {}

    /// Line `id`'s first words were heard at `now` (nothing happens if it is known already).
    public mutating func opened(_ id: Int, at now: Date) {
        if lines[id] == nil { lines[id] = Line(opened: now) }
    }

    /// Whether the sentence on line `id`, still being spoken as `text`, should be translated now.
    public func wantsEarly(_ id: Int, text: String, now: Date) -> Bool {
        guard let line = lines[id] else { return false }
        return !line.finished
            && now.timeIntervalSince(line.opened) >= Self.earlyAfter
            && line.earlyAt.map { now.timeIntervalSince($0) >= Self.earlyEvery } ?? true
            && text != line.earlyText
            && text.count >= Self.earlyMinChars
    }

    /// Numbers a new request for line `id`. The final one cancels every early one; returns the
    /// request's number and those it cancelled.
    public mutating func start(_ id: Int, text: String, early: Bool, now: Date) -> (seq: Int, cancelled: [Int]) {
        var line = lines[id] ?? Line(opened: now)
        var cancelled: [Int] = []
        if early {
            line.earlyAt = now
            line.earlyText = text
        } else {
            line.finished = true
            cancelled = line.running
            line.running.removeAll()
        }
        line.seq += 1
        line.running.append(line.seq)
        lines[id] = line
        return (line.seq, cancelled)
    }

    /// Whether request `seq`'s Chinese (`length` characters, `complete` or still streaming) goes
    /// on screen. A request still streaming waits until it is as long as the text it would replace;
    /// one that was cancelled or has ended shows nothing more. Also returns the requests a complete
    /// one cancelled.
    public mutating func accept(_ id: Int, seq: Int, length: Int, complete: Bool) -> (shown: Bool, cancelled: [Int]) {
        guard var line = lines[id], line.running.contains(seq) else { return (false, []) }
        if seq < line.shownSeq || (!complete && (seq <= line.completeSeq || (seq != line.shownSeq && length < line.shownLength))) {
            return (false, [])
        }
        line.shownSeq = seq
        line.shownLength = length
        var cancelled: [Int] = []
        if complete {
            line.completeSeq = seq
            cancelled = line.running.filter { $0 < seq }
            line.running.removeAll { $0 < seq }
        }
        lines[id] = line
        return (true, cancelled)
    }

    /// Request `seq` ended. A finished line with nothing left running is forgotten.
    public mutating func done(_ id: Int, seq: Int) {
        guard var line = lines[id] else { return }
        line.running.removeAll { $0 == seq }
        lines[id] = line.finished && line.running.isEmpty ? nil : line
    }

    /// The sentence still being spoken came to nothing (or listening ended): its line is forgotten.
    /// Returns the lines dropped, whose requests are to be cancelled.
    public mutating func dropUnfinished() -> [Int] {
        let ids = lines.filter { !$0.value.finished }.map(\.key)
        for id in ids { lines[id] = nil }
        return ids
    }

    /// An early translation is a guess at half a sentence; one that came back as notes or
    /// untranslated (more Latin-script words than Chinese characters, more than a couple of
    /// Japanese kana or Korean hangul, or several lines) is not shown, and the final one will come.
    public static func readsAsSubtitle(_ zh: String) -> Bool {
        let scalars = zh.unicodeScalars
        let han = scalars.filter { (0x4e00...0x9fff).contains($0.value) }.count
        let kanaHangul = scalars.filter { (0x3040...0x30ff).contains($0.value) || (0xac00...0xd7af).contains($0.value) }.count
        // A word: letters of the Latin alphabet, accented ones included.
        var words = 0
        var inWord = false
        for s in scalars {
            let letter = s.properties.isAlphabetic && (s.isASCII || (0xc0...0x24f).contains(s.value))
            if letter && !inWord { words += 1 }
            inWord = letter
        }
        return !zh.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") && han > 0 && han >= words && kanaHangul <= 2
    }
}
