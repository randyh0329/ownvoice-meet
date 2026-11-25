// The prompts beyond caption translation, carried over from the first version: replies (typed
// Chinese into words to read aloud), the live summary, and 補對照 for the script. Written for a
// Taiwanese participant and Traditional Chinese; the Simplified variant swaps the names, as the
// caption prompt does.

import Foundation

public enum Assistants {
    // MARK: Replies

    public static func replySystem(language lang: String, variant: ChineseVariant = .traditionalTaiwan) -> String {
        adapt("""
You help a Taiwanese participant speak in a \(lang)-language meeting. They type what they want to say in Chinese (it may be casual, incomplete, or mixed with other languages). Write the \(lang) they will read aloud word for word.
- Spoken style: short sentences (in English at most about 15 words), plain words that are easy to pronounce, natural meeting register.
- Keep their meaning, stance and tone. Do not add points, greetings, or filler they did not imply.
- Use the conversation context to pick the right terms and refer to what others said.
- If their prepared script is provided and what they type matches a point in it, reuse the script's \(lang) wording and terms.
Output only the \(lang) script, with no quotes, labels or notes.
""", variant)
    }

    public static func replyUser(context: [String], chinese: String) -> String {
        let ctx = context.isEmpty ? "(none)" : context.joined(separator: "\n")
        return "Recent conversation (speech-recognized, may have errors):\n\(ctx)\n\nWhat I want to say (Chinese):\n\(chinese)"
    }

    // MARK: Live summary

    public static func summarySystem(_ variant: ChineseVariant = .traditionalTaiwan) -> String {
        adapt(summaryBase, variant)
    }

    static let summaryBase = """
You keep a running summary of a meeting or talk for a Taiwanese participant who follows it in a language other than their own, with Chinese captions.
You get the summary so far (it may be empty) and the newest stretch of the transcript, which comes from speech recognition and may contain recognition errors.
Return the whole summary brought up to date, in Traditional Chinese as used in Taiwan (繁體中文): at most 8 short bullet points, each starting with "- ", about what was actually said: main points, decisions, numbers and dates, open questions, and who said what when speakers are named.
Keep names and technical terms as they are; merge new points into the existing ones rather than repeating them; drop small talk. Do not invent anything, do not give advice and do not suggest what the participant should say.
Output only the bullet points.
"""

    /// The summary so far and the newest lines.
    public static func summaryUser(before: String, transcript: String) -> String {
        let b = before.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Summary so far:\n\(b.isEmpty ? "(none yet)" : b)\n\nNewest transcript lines (time, what was said in the meeting's language, then the Chinese meaning):\n\(transcript)"
    }

    // MARK: 補對照

    public static func glossSystem(language lang: String, variant: ChineseVariant = .traditionalTaiwan) -> String {
        adapt("""
You prepare a bilingual script for a Taiwanese participant in a \(lang)-language meeting or talk.
You get a JSON list of items. Each has "to": "zh" or "speak", and "text".
- to = zh: give the meaning in natural Traditional Chinese as used in Taiwan, as a reading aid. Keep names and technical terms as they are where Taiwanese speakers would.
- to = speak: write the \(lang) the participant will read aloud: short spoken sentences, plain words, their meaning and tone, nothing added.
Answer with only a JSON array of strings, one per item, in the same order. No other text.
""", variant)
    }

    // MARK: The script as context

    /// The prepared script, appended to a system prompt as reference material.
    public static func scriptBlock(_ script: String) -> String? {
        let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return "The participant's prepared script for today's meeting follows. It is reference material for topic, terminology, names and what they intend to say; others may refer to it. Never translate or recite it unless asked.\n<script>\n\(s)\n</script>"
    }

    // MARK: Languages

    /// The language the participant speaks, by its English name for the prompts. A code it does
    /// not know is passed on as it is.
    public static func languageName(_ code: String) -> String {
        let base = code.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        switch base {
        case "", "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "de": return "German"
        case "fr": return "French"
        case "es": return "Spanish"
        case "vi": return "Vietnamese"
        case "th": return "Thai"
        case "id": return "Indonesian"
        default: return code.trimmingCharacters(in: .whitespaces)
        }
    }

    /// A prompt written for Traditional Chinese as used in Taiwan, for `variant`.
    static func adapt(_ text: String, _ variant: ChineseVariant) -> String {
        guard variant == .simplified else { return text }
        return text
            .replacingOccurrences(of: "Traditional Chinese as used in Taiwan (繁體中文)", with: "Simplified Chinese as used in mainland China (简体中文)")
            .replacingOccurrences(of: ChineseVariant.traditionalTaiwan.promptName, with: variant.promptName)
            .replacingOccurrences(of: ChineseVariant.traditionalTaiwan.scriptName, with: variant.scriptName)
            .replacingOccurrences(of: "Taiwanese speakers", with: "Chinese speakers")
            .replacingOccurrences(of: "a Taiwanese participant", with: "a Chinese-speaking participant")
    }
}
