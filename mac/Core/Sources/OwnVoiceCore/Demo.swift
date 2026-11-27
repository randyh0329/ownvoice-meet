// Demo mode's content: a short exchange at a panel, played as captions with no sound, keys or
// network (the same idea as the original app's demo), and a sample for the Reply window. Each line
// has its Chinese in both scripts, so the demo shows the Chinese the user chose.

import Foundation

public enum Demo {
    public struct Line: Sendable, Equatable {
        public let english: String
        public let traditional: String
        public let simplified: String

        public func chinese(_ variant: ChineseVariant) -> String {
            variant == .simplified ? simplified : traditional
        }
    }

    public static let lines: [Line] = [
        Line(english: "Welcome back. Our next demo is OwnVoice Meet, from Zaious in Taiwan.",
             traditional: "歡迎回來。下一個示範是來自台灣的 Zaious 帶來的 OwnVoice Meet。",
             simplified: "欢迎回来。下一个示范是来自台湾的 Zaious 带来的 OwnVoice Meet。"),
        Line(english: "Could you share your screen and show us the reply window?",
             traditional: "可以請你分享畫面，讓我們看看回覆視窗嗎？",
             simplified: "可以请你分享画面，让我们看看回复窗口吗？"),
        Line(english: "We have about five minutes for questions after the demo.",
             traditional: "示範之後大約有五分鐘可以提問。",
             simplified: "示范之后大约有五分钟可以提问。"),
        Line(english: "How is this different from the caption tools people already use?",
             traditional: "這跟大家已經在用的字幕工具有什麼不同？",
             simplified: "这跟大家已经在用的字幕工具有什么不同？"),
        Line(english: "Most tools stop at captions. This one also helps you answer.",
             traditional: "大部分工具只做到字幕，這個還能幫你回答。",
             simplified: "大部分工具只做到字幕，这个还能帮你回答。"),
        Line(english: "Does the translation take the earlier sentences into account?",
             traditional: "翻譯會參考前面的句子嗎？",
             simplified: "翻译会参考前面的句子吗？"),
        Line(english: "Yes, and a glossary keeps names and product terms right.",
             traditional: "會，而且術語表能讓人名和產品名稱保持正確。",
             simplified: "会，而且术语表能让人名和产品名称保持正确。"),
        Line(english: "What happens to the sound? Is anything recorded?",
             traditional: "聲音會怎麼處理？會錄下來嗎？",
             simplified: "声音会怎么处理？会录下来吗？"),
        Line(english: "Only if you turn on saving. Otherwise nothing is kept.",
             traditional: "只有開啟儲存才會留下，否則什麼都不保留。",
             simplified: "只有开启保存才会留下，否则什么都不保留。"),
        Line(english: "Can it tell the speakers apart on a panel like this one?",
             traditional: "像這樣的座談，它分得出誰在說話嗎？",
             simplified: "像这样的座谈，它分得出谁在说话吗？"),
        Line(english: "It can, on the Mac itself, and you can name each voice.",
             traditional: "可以，直接在 Mac 上分辨，每個聲音都能取名字。",
             simplified: "可以，直接在 Mac 上分辨，每个声音都能取名字。"),
        Line(english: "Great. Let's thank our speaker and move on to the next talk.",
             traditional: "太好了。讓我們謝謝講者，接著進入下一場演講。",
             simplified: "太好了。让我们谢谢讲者，接着进入下一场演讲。"),
    ]

    /// The Reply window's sample: what was typed in Chinese, and the English to read aloud.
    public static let reply = Line(
        english: "Caption tools help you understand. This one helps you speak. I type in Chinese, and it gives me English I can read aloud.",
        traditional: "字幕工具幫你聽懂，這個工具幫你開口。我打中文，它給我可以照著唸的英文。",
        simplified: "字幕工具帮你听懂，这个工具帮你开口。我打中文，它给我可以照着念的英文。"
    )

    /// What a recognizer would show while the sentence is still being said: three words more each
    /// time (the whole sentence comes as the final line).
    public static func partials(_ english: String) -> [String] {
        let words = english.split(separator: " ").map(String.init)
        return stride(from: 3, to: words.count, by: 3).map { words[..<$0].joined(separator: " ") }
    }

    /// The Chinese as it streams in: four characters more each time, ending with all of it.
    public static func translationSteps(_ chinese: String) -> [String] {
        let chars = Array(chinese)
        guard !chars.isEmpty else { return [] }
        var steps = stride(from: 4, to: chars.count, by: 4).map { String(chars[..<$0]) }
        steps.append(chinese)
        return steps
    }
}
