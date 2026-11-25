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

    // MARK: Meeting summary (minutes), once the meeting is over

    public static func minutesSystem(_ variant: ChineseVariant = .traditionalTaiwan) -> String {
        adapt("""
        You write the minutes of a meeting or talk for a Taiwanese participant, from its full transcript. The transcript comes from speech recognition and may contain recognition errors; each line has the time, the speaker when known, what was said in the meeting's language and its Chinese meaning.
        Write in Traditional Chinese as used in Taiwan (繁體中文), in Markdown, with these sections, each headed in that language: Overview (two to four sentences), Key points (grouped by topic or by segment, short bullets, saying who said what when speakers are named), Decisions, Action items (who, what, by when, only as stated), Open questions.
        Keep names, numbers, dates and technical terms exactly as they appear. Leave a section out when the meeting had nothing for it. Do not invent anything, do not give advice and do not suggest what the participant should say.
        """, variant)
    }

    public static func minutesUser(title: String, transcript: String) -> String {
        "Meeting: \(title)\n\nFull transcript:\n\(transcript)"
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

    // MARK: TranslateGemma

    /// TranslateGemma's own prompt, a single user message (per its model card): source and target
    /// by name and code, then two blank lines before the text. It takes no context or glossary.
    public static func translateGemma(text: String, sourceCode: String, variant: ChineseVariant) -> String {
        let code = sourceCode.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? "en"
        let source = languageName(code)
        let target = variant == .traditionalTaiwan ? "zh-TW" : "zh-Hans"
        return "You are a professional \(source) (\(code)) to Chinese (\(target)) translator. Your goal is to accurately convey the meaning and nuances of the original \(source) text while adhering to Chinese grammar, vocabulary, and cultural sensitivities. Produce only the Chinese translation, without any additional explanations or commentary. Please translate the following \(source) text into Chinese:\n\n\n\(text)"
    }

    // MARK: Gemini Live Translate

    /// Live Translate's system instruction: only wording, register and terms (Google ignores
    /// instructions beyond translating into the target language).
    public static func liveTranslateInstruction(glossary: String, variant: ChineseVariant) -> String {
        var text = variant == .traditionalTaiwan
            ? "Translate for a Taiwanese participant following a meeting. Use Traditional Chinese as used in Taiwan (臺灣繁體中文), with Taiwan vocabulary: 軟體, 網路, 影片, 資料, 品質, 專案, 伺服器, 程式, not their Mainland forms. Natural, concise meeting register. Keep names, product names and acronyms as spoken."
            : "Translate for a participant following a meeting. Use Simplified Chinese as used in mainland China (简体中文). Natural, concise meeting register. Keep names, product names and acronyms as spoken."
        let terms = Prompts.parseGlossary(glossary)
        if !terms.isEmpty {
            text += "\nAlways translate these terms this way:\n" + terms.map { "- \($0.en) → \($0.zh)" }.joined(separator: "\n")
        }
        return text
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
