// The bilingual script format, one item per line (as in the first version's scriptview):
//   # Title        a section (a tab in the script window)
//   ## Sub         a sub-heading
//   ! cue          a stage direction, not read aloud
//   Q: question    a question
//   > 中文          the meaning of the line above
//   ```copy:name   a block shown boxed with a copy button, until ```
//   anything else  a line to read aloud
// 補對照 fills in the missing half: a line to read with no meaning under it gets its Chinese; a line
// written in Chinese becomes the spoken language, with the Chinese kept as its meaning. Only those
// lines go to the model, as a numbered JSON list; headings, cues, copy blocks and lines that already
// have a meaning are never touched.

import Foundation

public enum ScriptItem: Equatable, Sendable {
    case section(String, index: Int)
    case sub(String)
    case cue(String)
    case gloss(String)
    case question(String)
    case line(String)
    case copy(name: String, text: String)
}

public enum Script {
    public static let template = """
    # 開場
    ! 灰色提示：這行不用唸，例如「切到第 2 張投影片」
    Hi everyone, thanks for having me.
    > 大家好，謝謝邀請。
    寫中文也可以，按「補對照」會產生要唸的句子（語言在設定的「我說的語言」選）。

    # Q&A
    Q: How is this different from other tools?
    > 問：這跟其他工具有什麼不同？
    它不會替你作答，你說的是自己的話。

    ## 救急句
    Sorry, could you repeat the question?
    > 抱歉，可以請你再說一次問題嗎？

    """

    public static func parse(_ source: String) -> [ScriptItem] {
        var items: [ScriptItem] = []
        var sections = 0
        var block: (name: String, lines: [String])?
        let text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "").trimmingTrailingWhitespace()
            if let b = block {
                if line.trimmingCharacters(in: .whitespaces) == "```" {
                    items.append(.copy(name: b.name, text: b.lines.joined(separator: "\n")))
                    block = nil
                } else {
                    block?.lines.append(line)
                }
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("```copy:") {
                block = (String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces), [])
            } else if line.hasPrefix("# ") {
                items.append(.section(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), index: sections))
                sections += 1
            } else if line.hasPrefix("## ") {
                items.append(.sub(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("! ") {
                items.append(.cue(String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                items.append(.gloss(String(line.dropFirst(2))))
            } else if line.hasPrefix("Q: ") {
                items.append(.question(String(line.dropFirst(3))))
            } else {
                items.append(.line(line))
            }
        }
        // An unclosed block still shows, so a typo never hides content.
        if let b = block { items.append(.copy(name: b.name, text: b.lines.joined(separator: "\n"))) }
        return items
    }

    /// The section titles, in order.
    public static func sections(_ items: [ScriptItem]) -> [String] {
        items.compactMap { if case let .section(t, _) = $0 { t } else { nil } }
    }

    // MARK: 補對照

    public enum Direction: Equatable, Sendable {
        /// A line in the spoken language: give its Chinese meaning.
        case toChinese
        /// A line written in Chinese: write it in the spoken language.
        case toSpoken
    }

    /// What can be wrong with the model's answer (the app words it).
    public enum GlossError: Error, Equatable {
        case notAList
        case wrongCount(got: Int, expected: Int)
    }

    public struct Need: Equatable, Sendable {
        public let line: Int
        public let prefix: String
        public let text: String
        public let direction: Direction
    }

    /// Written in Chinese, not in the spoken language. Japanese shares the characters: a line with
    /// kana is Japanese.
    static func isChinese(_ s: String) -> Bool {
        let scalars = s.unicodeScalars
        let cjk = scalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        let latin = scalars.filter { $0.isASCII && CharacterSet.letters.contains($0) }.count
        let kana = scalars.filter { (0x3040...0x30FF).contains($0.value) }.count
        return cjk > 0 && cjk * 2 >= latin && kana == 0
    }

    /// The lines to fill.
    public static func plan(_ script: String) -> [Need] {
        let lines = script.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
        var needs: [Need] = []
        var inBlock = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingTrailingWhitespace()
            if inBlock {
                if line.trimmingCharacters(in: .whitespaces) == "```" { inBlock = false }
                continue
            }
            if line.hasPrefix("```copy:") { inBlock = true; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty || ["# ", "## ", "! ", "> "].contains(where: line.hasPrefix) { continue }
            let (prefix, text) = line.hasPrefix("Q: ") ? ("Q: ", String(line.dropFirst(3))) : ("", line)
            // Already has a meaning: the next non-empty line is a "> " line.
            let next = lines[(i + 1)...].map { $0.trimmingTrailingWhitespace() }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if next?.hasPrefix("> ") == true { continue }
            needs.append(Need(line: i, prefix: prefix, text: text.trimmingCharacters(in: .whitespaces), direction: isChinese(text) ? .toSpoken : .toChinese))
        }
        return needs
    }

    /// The request: one item per need, {"to": "zh" | "speak", "text": …}.
    public static func request(_ needs: [Need]) -> String {
        let items = needs.map { ["to": $0.direction == .toChinese ? "zh" : "speak", "text": $0.text] }
        let data = (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The model's answer as a list of strings, tolerating a code fence around it.
    public static func answers(_ text: String, expect: Int) throws -> [String] {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for fence in ["```json", "```"] where t.hasPrefix(fence) { t = String(t.dropFirst(fence.count)) }
        if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        guard let list = (try? JSONSerialization.jsonObject(with: Data(t.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [Any] else {
            throw GlossError.notAList
        }
        let strings = list.map { $0 as? String ?? "" }
        guard strings.count == expect, !strings.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw GlossError.wrongCount(got: strings.count, expected: expect)
        }
        return strings
    }

    /// The answers put back: spoken-language lines get "> Chinese" under them; Chinese lines become
    /// the spoken language, with "> the Chinese" under it.
    public static func merge(_ script: String, needs: [Need], answers: [String], variant: ChineseVariant = .traditionalTaiwan) -> String {
        var out: [String] = []
        var k = 0
        for (i, raw) in script.components(separatedBy: "\n").enumerated() {
            guard k < needs.count, needs[k].line == i else {
                out.append(raw)
                continue
            }
            let n = needs[k]
            let a = answers[k].trimmingCharacters(in: .whitespacesAndNewlines)
            switch n.direction {
            case .toChinese:
                out.append(raw)
                out.append("> " + variant.fix(a))
            case .toSpoken:
                out.append(n.prefix + a)
                out.append("> " + n.text)
            }
            k += 1
        }
        return out.joined(separator: "\n")
    }
}

extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
