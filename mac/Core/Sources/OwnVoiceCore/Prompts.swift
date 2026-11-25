// The caption prompt, carried over from the first version where it was checked in live meetings:
// it never comments on recognition errors (its output is the subtitle), and the request names
// Chinese the user chose itself, since with only the system prompt saying so a long line now and
// then came back in the other script. The prompt was written for Traditional Chinese as used in
// Taiwan; the Simplified variant swaps the names.

import Foundation

public enum Prompts {
    public static let listenSystem = """
You are a live interpreter in an online meeting. Translate the latest utterance, whatever language it is in, into natural Traditional Chinese as used in Taiwan; an utterance already in Chinese is given back in Traditional Chinese.
The utterance comes from speech recognition: it may contain recognition errors or be a sentence fragment. Translate the most plausible meaning and keep a fragment as a fragment; do not complete it or add anything.
When a word looks misrecognized, silently use the most plausible reading; keep an unknown name as heard. Never comment on the recognition or on your translation.
Your entire output is shown as a subtitle: output only the Chinese translation, with no quotes, labels or notes.
"""

    /// The caption system prompt for `variant`.
    public static func listenSystem(_ variant: ChineseVariant) -> String {
        guard variant != .traditionalTaiwan else { return listenSystem }
        return listenSystem
            .replacingOccurrences(of: ChineseVariant.traditionalTaiwan.promptName, with: variant.promptName)
            .replacingOccurrences(of: ChineseVariant.traditionalTaiwan.scriptName, with: variant.scriptName)
    }

    /// The request for one caption line, with recent lines as context.
    public static func listenUser(context: [String], utterance: String, variant: ChineseVariant = .traditionalTaiwan, unfinished: Bool = false) -> String {
        let ctx = context.isEmpty ? "(none)" : context.joined(separator: "\n")
        let target = "\(variant.promptName) (\(variant.promptTag))"
        let ask = unfinished
            ? "The speaker is still talking: this utterance stops mid-sentence. Translate only what is there, as a fragment, into \(target), and output only that"
            : "Translate this utterance into \(target)"
        return "Recent conversation, for context only (do not translate):\n\(ctx)\n\n\(ask):\n\(utterance)"
    }

    /// `中文 = English` per line; `#` starts a comment.
    public static func parseGlossary(_ text: String) -> [(zh: String, en: String)] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line -> (zh: String, en: String)? in
                guard let eq = line.firstIndex(of: "=") else { return nil }
                let zh = line[..<eq].trimmingCharacters(in: .whitespaces)
                let en = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return zh.isEmpty || en.isEmpty ? nil : (zh, en)
            }
    }

    /// The caption system prompt for `variant`, with the glossary appended.
    public static func system(glossary: String, variant: ChineseVariant = .traditionalTaiwan) -> String {
        let base = listenSystem(variant)
        let terms = parseGlossary(glossary)
        guard !terms.isEmpty else { return base }
        let list = terms.map { "- \($0.zh) = \($0.en)" }.joined(separator: "\n")
        return base + "\n\nGlossary (always use these renderings):\n" + list
    }
}
