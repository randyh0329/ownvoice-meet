// Gemini Live Translate sends two continuous streams with no turns: what was said and the Chinese,
// the second a little behind. This pairs them into caption lines (as in the first version):
//   - What was said grows the newest line. It ends at a pause (inQuiet without new words), at the
//     end of a sentence once long (splitChars), or at maxChars anyway.
//   - The Chinese goes to the oldest line still waiting for it. That translation is complete when
//     the line has ended and the Chinese has as many sentences, or once the next line has ended
//     too and the Chinese reads as a whole sentence of plausible length, or when no Chinese has come
//     for zhQuiet after the line ended. Chinese that completes one line and starts the next is split
//     at the sentence end.
//   - Chinese that comes when no line is waiting for it belongs to the line just completed (one
//     English sentence may come back as two Chinese ones: "Right, let's start." as "對。" then
//     "我們開始吧。"): that line's translation is sent again, longer, still done. Chinese with no
//     line at all before it gets a line of its own, ended at once with nothing heard.
// Following another recognizer (Live Translate chosen under Translation): the lines are the
// recognizer's (the app reports each line opened, ended or dropped) and Live Translate, hearing the
// same audio, only supplies the Chinese, paired the same way. Chinese with no line waiting joins the
// line just completed only when that is recent (orphanLate); otherwise it is kept for the next line.
// A line Live Translate brings no Chinese for goes to the text model rather than end with none.
// While Live Translate is disconnected (pause, resume), lines that end go to the text model, and so
// do the lines being spoken when it went: the Chinese for their start will not come.
// No network, no screen: a sink receives the lines, so the pairing is tested on its own.

import Foundation

public protocol InterpreterSink: AnyObject {
    func open() -> Int
    func heard(_ id: Int, _ text: String, done: Bool)
    func translated(_ id: Int, _ text: String, done: Bool)
    func drop(_ id: Int)
    /// Following: a line Live Translate brought no Chinese for, with what was said on it; the text
    /// model translates it.
    func untranslated(_ id: Int, _ heard: String)
}

public extension InterpreterSink {
    /// Only lines another recognizer makes go to the text model.
    func untranslated(_ id: Int, _ heard: String) {}
}

public struct Interpreter {
    static let inQuiet: TimeInterval = 1.0
    static let zhQuiet: TimeInterval = 3.0
    static let splitChars = 120
    static let maxChars = 300
    /// Following: Chinese this soon after a line's translation completed, with no line waiting,
    /// still belongs to it.
    static let orphanLate: TimeInterval = 1.5

    struct Line {
        let id: Int
        var heard = ""
        var zh = ""
        var ended: Date?
        /// Following: the text model translates this line (Live Translate missed the start of it).
        /// It still takes the Chinese meant for it, so that Chinese does not land under the next line.
        var skip = false
    }

    private var lines: [Line] = []
    /// The line completed last, for Chinese that comes after it with no line waiting, and when.
    private var lastDone: Line?
    private var lastDoneAt: Date?
    private var lastIn: Date?
    private var lastOut: Date?
    /// The lines are another recognizer's (openLine, endLine, removeLine); only Chinese comes here.
    public let following: Bool
    /// Following: Chinese that came with no line waiting for it.
    private var orphan = ""
    /// Following, while Live Translate is disconnected: lines go to the text model.
    public private(set) var away = false

    /// `following`: pairing for lines another recognizer makes.
    public init(following: Bool = false) {
        self.following = following
    }

    /// Nothing is being spoken or translated.
    public var idle: Bool { lines.isEmpty }

    // MARK: Following another recognizer

    /// The recognizer opened a line. Opening one already waiting changes nothing.
    public mutating func openLine(_ id: Int) {
        guard !lines.contains(where: { $0.id == id }) else { return }
        lines.append(Line(id: id, zh: orphan, skip: away))
        orphan = ""
    }

    /// The recognizer's line ended with `text`. False when the Chinese for it will not come from
    /// here (the caller has the text model translate it): a line opened before this pairing began,
    /// or while Live Translate is disconnected, or one it missed the start of.
    public mutating func endLine(_ id: Int, _ text: String, now: Date, sink: InterpreterSink) -> Bool {
        guard let at = lines.firstIndex(where: { $0.id == id }) else { return false }
        if away {
            // No Chinese is coming for it: its sound was not sent.
            lines.remove(at: at)
            return false
        }
        lines[at].heard = text
        lines[at].ended = now
        let taken = !lines[at].skip
        release(now: now, sink: sink)
        return taken
    }

    /// The recognizer dropped a line: Chinese it had goes on to the next.
    public mutating func removeLine(_ id: Int) {
        guard let at = lines.firstIndex(where: { $0.id == id }) else { return }
        let gone = lines.remove(at: at)
        guard !gone.zh.isEmpty else { return }
        if at < lines.count {
            lines[at].zh = gone.zh + lines[at].zh
        } else {
            orphan = gone.zh + orphan
        }
    }

    /// Following: Live Translate lost its connection. Lines that ended keep the Chinese they have
    /// (or go to the text model), the lines being spoken will be the text model's, and so will
    /// every line that ends until it is back (resume).
    public mutating func pause(sink: InterpreterSink) {
        flush(sink: sink)
        for i in lines.indices { lines[i].skip = true }
        lastDone = nil
        lastDoneAt = nil
        away = true
    }

    /// Following: Live Translate is connected again, hearing what is said from now on.
    public mutating func resume() {
        away = false
    }

    // MARK: Both streams

    public mutating func heard(_ piece: String, now: Date, sink: InterpreterSink) {
        guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastIn = now
        if lines.last.map({ $0.ended != nil }) ?? true {
            lines.append(Line(id: sink.open()))
        }
        let i = lines.count - 1
        Self.grow(&lines[i].heard, piece)
        let text = lines[i].heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let long = text.count >= Self.maxChars || (text.count >= Self.splitChars && Self.endsSentence(text))
        sink.heard(lines[i].id, text, done: long)
        if long { lines[i].ended = now }
    }

    public mutating func translated(_ piece: String, now: Date, sink: InterpreterSink) {
        guard !piece.isEmpty else { return }
        lastOut = now
        var rest = Substring(piece)
        while !rest.isEmpty {
            // A line already complete now that the next one has ended does not take this piece.
            release(now: now, sink: sink)
            let cut = rest.firstIndex(where: Self.isZhEnd).map { rest.index(after: $0) } ?? rest.endIndex
            if lines.isEmpty, var last = lastDone, !following || lastDoneAt.map({ now.timeIntervalSince($0) < Self.orphanLate }) == true {
                // More Chinese for the line just completed.
                Self.grow(&last.zh, String(rest[..<cut]))
                rest = rest[cut...]
                lastDone = last
                lastDoneAt = now
                sink.translated(last.id, last.zh.trimmingCharacters(in: .whitespacesAndNewlines), done: true)
                continue
            }
            if lines.isEmpty, following {
                // Kept for the next line the recognizer opens.
                orphan += rest
                return
            }
            let head = rest[..<cut]
            rest = rest[cut...]
            if lines.isEmpty {
                // Chinese with nothing heard before it: a line of its own, with nothing heard.
                let line = Line(id: sink.open(), ended: now)
                sink.heard(line.id, "", done: true)
                lines.append(line)
            }
            let nextEnded = lines.count > 1 && lines[1].ended != nil
            Self.grow(&lines[0].zh, String(head))
            if Self.complete(lines[0], nextEnded: nextEnded) {
                complete(lines.removeFirst(), now: now, sink: sink)
            } else if !lines[0].skip {
                sink.translated(lines[0].id, lines[0].zh.trimmingCharacters(in: .whitespacesAndNewlines), done: false)
            }
        }
    }

    /// Time passes: pauses end lines (unless following: the recognizer ends them) and their translations.
    public mutating func tick(now: Date, sink: InterpreterSink) {
        if !following, let i = lines.indices.last, lines[i].ended == nil, let last = lastIn, now.timeIntervalSince(last) >= Self.inQuiet {
            lines[i].ended = now
            sink.heard(lines[i].id, lines[i].heard.trimmingCharacters(in: .whitespacesAndNewlines), done: true)
        }
        release(now: now, sink: sink)
        while let first = lines.first, let ended = first.ended {
            let since = max(lastOut ?? ended, ended)
            guard now.timeIntervalSince(since) >= Self.zhQuiet else { break }
            complete(lines.removeFirst(), now: now, sink: sink)
        }
    }

    /// The session ended: every line ends as it stands. Following, lines still being spoken stay
    /// (the next session's Chinese, or the text model, will translate them).
    public mutating func flush(sink: InterpreterSink) {
        let now = Date()
        var speaking: [Line] = []
        for var line in lines {
            if line.ended == nil {
                if following {
                    speaking.append(line)
                    continue
                }
                line.ended = now
                let t = line.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink.heard(line.id, t, done: true) }
            }
            complete(line, now: now, sink: sink)
        }
        lines = speaking
        orphan = ""
        if !following {
            lastDone = nil
            lastDoneAt = nil
        }
    }

    private mutating func release(now: Date, sink: InterpreterSink) {
        while let first = lines.first, Self.complete(first, nextEnded: lines.count > 1 && lines[1].ended != nil) {
            complete(lines.removeFirst(), now: now, sink: sink)
        }
    }

    /// A line's translation ends as it stands. Following, a line with no Chinese goes to the text
    /// model, and one the text model already has only gave up the Chinese meant for it.
    private mutating func complete(_ line: Line, now: Date, sink: InterpreterSink) {
        guard !line.skip else { return }
        let zh = line.zh.trimmingCharacters(in: .whitespacesAndNewlines)
        if following, zh.isEmpty {
            sink.untranslated(line.id, line.heard.trimmingCharacters(in: .whitespacesAndNewlines))
        } else if !following, line.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, zh.isEmpty {
            sink.drop(line.id)
        } else {
            sink.translated(line.id, zh, done: true)
            lastDone = line
            lastDoneAt = now
        }
    }

    static func complete(_ line: Line, nextEnded: Bool) -> Bool {
        let zh = line.zh.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.ended != nil, let last = zh.last, isZhEnd(last) else { return false }
        let heard = line.heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if sentences(zh) >= sentences(heard) { return true }
        // The interpreter joined sentences: once the next line is waiting too, a whole sentence of
        // plausible length (Chinese runs about a third of the English letters, or more) will do.
        return nextEnded && zh.count * 4 >= heard.count
    }

    /// Streams may send pieces or the text so far; either way `text` ends up as the whole.
    static func grow(_ text: inout String, _ piece: String) {
        let soFar = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = piece.drop { $0.isWhitespace }
        if !soFar.isEmpty, whole.count > soFar.count, whole.hasPrefix(soFar) {
            text = piece
        } else {
            text += piece
        }
    }

    static func isZhEnd(_ c: Character) -> Bool { "。？！?!…".contains(c) }

    static func endsSentence(_ t: String) -> Bool {
        guard let last = t.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!。？！…".contains(last)
    }

    static func sentences(_ t: String) -> Int {
        max(1, t.split(whereSeparator: { ".?!。？！…".contains($0) }).filter { $0.contains { $0.isLetter || $0.isNumber } }.count)
    }
}
