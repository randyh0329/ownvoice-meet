// Gemini Live Translate sends two continuous streams with no turns: what was said and the Chinese,
// the second a little behind. This pairs them into caption lines (as in the first version):
//   - What was said grows the newest line. It ends at a pause (inQuiet without new words), at the
//     end of a sentence once long (splitChars), or at maxChars anyway.
//   - The Chinese goes to the oldest line still waiting for it. That translation is complete when
//     the line has ended and the Chinese has as many sentences, or once the next line has ended
//     too and the Chinese reads as a whole sentence of plausible length, or when no Chinese has come
//     for zhQuiet after the line ended. Chinese that completes one line and starts the next is split
//     at the sentence end.
// No network, no screen: a sink receives the lines, so the pairing is tested on its own.

import Foundation

public protocol InterpreterSink: AnyObject {
    func open() -> Int
    func heard(_ id: Int, _ text: String, done: Bool)
    func translated(_ id: Int, _ text: String, done: Bool)
    func drop(_ id: Int)
}

public struct Interpreter {
    static let inQuiet: TimeInterval = 1.0
    static let zhQuiet: TimeInterval = 3.0
    static let splitChars = 120
    static let maxChars = 300

    struct Line {
        let id: Int
        var heard = ""
        var zh = ""
        var ended: Date?
    }

    private var lines: [Line] = []
    private var lastIn: Date?
    private var lastOut: Date?

    public init() {}

    public var idle: Bool { lines.isEmpty }

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
            release(now: now, sink: sink)
            if lines.isEmpty {
                // Chinese with nothing heard before it: a line of its own.
                lines.append(Line(id: sink.open(), ended: now))
            }
            let cut = rest.firstIndex(where: Self.isZhEnd).map { rest.index(after: $0) } ?? rest.endIndex
            let head = rest[..<cut]
            rest = rest[cut...]
            let nextEnded = lines.count > 1 && lines[1].ended != nil
            Self.grow(&lines[0].zh, String(head))
            if Self.complete(lines[0], nextEnded: nextEnded) {
                complete(lines.removeFirst(), sink: sink)
            } else {
                sink.translated(lines[0].id, lines[0].zh.trimmingCharacters(in: .whitespacesAndNewlines), done: false)
            }
        }
    }

    public mutating func tick(now: Date, sink: InterpreterSink) {
        if let i = lines.indices.last, lines[i].ended == nil, let last = lastIn, now.timeIntervalSince(last) >= Self.inQuiet {
            lines[i].ended = now
            sink.heard(lines[i].id, lines[i].heard.trimmingCharacters(in: .whitespacesAndNewlines), done: true)
        }
        release(now: now, sink: sink)
        while let first = lines.first, let ended = first.ended {
            let since = max(lastOut ?? ended, ended)
            guard now.timeIntervalSince(since) >= Self.zhQuiet else { break }
            complete(lines.removeFirst(), sink: sink)
        }
    }

    /// The session ended: every line ends as it stands.
    public mutating func flush(sink: InterpreterSink) {
        for var line in lines {
            if line.ended == nil {
                line.ended = Date()
                let t = line.heard.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { sink.heard(line.id, t, done: true) }
            }
            complete(line, sink: sink)
        }
        lines.removeAll()
    }

    private mutating func release(now: Date, sink: InterpreterSink) {
        while let first = lines.first, Self.complete(first, nextEnded: lines.count > 1 && lines[1].ended != nil) {
            complete(lines.removeFirst(), sink: sink)
        }
    }

    private func complete(_ line: Line, sink: InterpreterSink) {
        let zh = line.zh.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && zh.isEmpty {
            sink.drop(line.id)
        } else {
            sink.translated(line.id, zh, done: true)
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
