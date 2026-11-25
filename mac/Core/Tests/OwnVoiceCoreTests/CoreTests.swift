import XCTest
@testable import OwnVoiceCore

final class CaptionBookTests: XCTestCase {
    func testALineGrowsGrayThenEndsWhite() {
        var book = CaptionBook()
        let id = book.partial("Welcome to")
        book.partial("Welcome to the panel")
        XCTAssertEqual(book.lines.count, 1)
        XCTAssertFalse(book.lines[0].isFinal)
        XCTAssertEqual(book.finish("Welcome to the panel."), id)
        XCTAssertEqual(book.lines[0], CaptionLine(id: id!, heard: "Welcome to the panel.", isFinal: true))
        book.setTranslation("歡迎來到座談會。", for: id!)
        XCTAssertEqual(book.lines[0].translation, "歡迎來到座談會。")
    }

    func testAnEmptyFinalDropsTheLine() {
        var book = CaptionBook()
        book.partial("um")
        XCTAssertNil(book.finish(""))
        XCTAssertTrue(book.lines.isEmpty)
    }

    func testAFinalWithNoGrayLineStillMakesOne() {
        var book = CaptionBook()
        let id = book.finish("Thanks.")
        XCTAssertEqual(book.lines.map(\.heard), ["Thanks."])
        XCTAssertEqual(book.context(before: id! + 1), ["Thanks."])
    }

    func testContextIsTheFinishedLinesBefore() {
        var book = CaptionBook()
        for t in ["One.", "Two.", "Three."] { book.finish(t) }
        book.partial("Four")
        XCTAssertEqual(book.context(before: 3), ["One.", "Two."])
        XCTAssertEqual(book.context(before: 99, count: 2), ["Two.", "Three."], "the gray line is not context")
    }
}

final class TranscriptTests: XCTestCase {
    func testAFinalThatIsOnlyTheEndOfTheShownLineKeepsTheLine() {
        let shown = "Welcome to the panel on digital libraries. I am the moderator. Our first panelist will talk about preserving web archives for 20 years"
        XCTAssertEqual(Transcript.keepShown(shown: shown, final: "20 years."), shown)
        XCTAssertEqual(Transcript.keepShown(shown: "the old built servers", final: "the old build servers."), "the old build servers.")
        XCTAssertEqual(Transcript.keepShown(shown: "so the plan is to", final: "to"), "to", "too short a line to judge")
        XCTAssertEqual(Transcript.keepShown(shown: shown, final: ""), "", "an empty final still drops the line")
    }

    func testJoinedSentencesGetTheirSpaceBack() {
        XCTAssertEqual(Transcript.sentenceGaps("I am the moderator.Our first panelist will talk about 20 years.The library decided."),
                       "I am the moderator. Our first panelist will talk about 20 years. The library decided.")
        XCTAssertEqual(Transcript.sentenceGaps("in the U.S.A. and e.g. there"), "in the U.S.A. and e.g. there")
        XCTAssertEqual(Transcript.sentenceGaps("version 2.5 of it"), "version 2.5 of it")
    }
}

final class ChineseTests: XCTestCase {
    func testEachVariantGetsItsOwnScript() {
        XCTAssertTrue(ChineseScript.isSimplified("这个问题"))
        XCTAssertEqual(ChineseVariant.traditionalTaiwan.fix("这个问题"), "這個問題")
        XCTAssertEqual(ChineseVariant.traditionalTaiwan.fix("台灣的干擾"), "台灣的干擾", "Traditional text is never converted")
        XCTAssertEqual(ChineseVariant.simplified.fix("這個問題"), "这个问题")
        XCTAssertEqual(ChineseVariant.simplified.fix("这个问题"), "这个问题", "Simplified stays Simplified")
        XCTAssertEqual(ChineseVariant.simplified.appleTargets.first, "zh-Hans-CN")
    }

    func testThePromptsNameTheChosenChinese() {
        let tw = Prompts.system(glossary: "", variant: .traditionalTaiwan)
        let cn = Prompts.system(glossary: "", variant: .simplified)
        XCTAssertTrue(tw.contains("Traditional Chinese as used in Taiwan"))
        XCTAssertFalse(cn.contains("Traditional"), cn)
        XCTAssertTrue(cn.contains("Simplified Chinese as used in mainland China"))
        XCTAssertTrue(Prompts.listenUser(context: [], utterance: "Hi.", variant: .simplified).contains("(简体中文)"))
    }
}

final class PromptTests: XCTestCase {
    func testGlossaryLinesAndTheRequest() {
        let g = Prompts.parseGlossary("# terms\n 數位典藏 = digital archive \nbad line\n= x\n")
        XCTAssertEqual(g.map(\.zh), ["數位典藏"])
        XCTAssertEqual(g.map(\.en), ["digital archive"])
        XCTAssertTrue(Prompts.system(glossary: "數位典藏 = digital archive").hasSuffix("- 數位典藏 = digital archive"))
        XCTAssertEqual(Prompts.system(glossary: ""), Prompts.listenSystem)
        let user = Prompts.listenUser(context: [], utterance: "Hello.")
        XCTAssertTrue(user.contains("(none)") && user.hasSuffix(":\nHello."))
    }
}

final class GeminiLiveTests: XCTestCase {
    func testSetupAudioAndServerMessages() throws {
        let setup = try JSONSerialization.jsonObject(with: Data(GeminiLive.setupMessage(model: "gemini-3.5-transcribe-live", language: "en-US").utf8)) as! [String: Any]
        let s = setup["setup"] as! [String: Any]
        XCTAssertEqual(s["model"] as? String, "models/gemini-3.5-transcribe-live")
        XCTAssertEqual((s["inputAudioTranscription"] as! [String: Any])["languageCodes"] as? [String], ["en-US"])

        let audio = try JSONSerialization.jsonObject(with: Data(GeminiLive.audioMessage([1, -1]).utf8)) as! [String: Any]
        let data = ((audio["realtimeInput"] as! [String: Any])["audio"] as! [String: Any])["data"] as! String
        XCTAssertEqual(Data(base64Encoded: data), Data([0x01, 0x00, 0xff, 0xff]), "16-bit little-endian")

        XCTAssertEqual(GeminiLive.parse(Data(#"{"setupComplete":{}}"#.utf8)), [.setupComplete])
        XCTAssertEqual(GeminiLive.parse(Data(#"{"serverContent":{"interimInputTranscription":{"text":" I am the moderator.Our"}}}"#.utf8)), [.partial("I am the moderator. Our")])
        XCTAssertEqual(GeminiLive.parse(Data(#"{"serverContent":{"inputTranscription":{"text":"Done."}}}"#.utf8)), [.final("Done.")])
        XCTAssertEqual(GeminiLive.parse(Data("not json".utf8)), [])
    }
}

final class RequestTests: XCTestCase {
    func testBodiesAndAnswers() throws {
        let a = try JSONSerialization.jsonObject(with: Requests.anthropicBody(model: "claude-haiku-5-5", system: "S", user: "U", effort: "low")) as! [String: Any]
        XCTAssertEqual((a["output_config"] as? [String: Any])?["effort"] as? String, "low")
        let c = try JSONSerialization.jsonObject(with: Requests.chatBody(model: "gemma4:e4b", system: "S", user: "U", effort: "none")) as! [String: Any]
        XCTAssertEqual(c["reasoning_effort"] as? String, "none")
        XCTAssertEqual((c["messages"] as? [[String: Any]])?.count, 2)

        XCTAssertEqual(try Requests.anthropicText(Data(#"{"content":[{"type":"text","text":" 你好 "}]}"#.utf8), status: 200), "你好")
        XCTAssertEqual(try Requests.chatText(Data(#"{"choices":[{"message":{"content":"好。"}}]}"#.utf8), status: 200), "好。")
        XCTAssertThrowsError(try Requests.chatText(Data(#"{"error":{"message":"bad key"}}"#.utf8), status: 401)) { e in
            XCTAssertEqual((e as? ServiceError)?.message, "401：bad key")
        }
    }
}

final class AssistantTests: XCTestCase {
    func testRepliesSummaryAndGlossFollowTheVariantAndLanguage() {
        let reply = Assistants.replySystem(language: "Japanese")
        XCTAssertTrue(reply.contains("Japanese-language meeting") && reply.contains("Output only the Japanese script"))
        XCTAssertTrue(Assistants.summarySystem(.traditionalTaiwan).contains("繁體中文"))
        let cn = Assistants.summarySystem(.simplified)
        XCTAssertTrue(cn.contains("简体中文") && !cn.contains("Traditional") && !cn.contains("Taiwanese"), cn)
        XCTAssertFalse(Assistants.glossSystem(language: "English", variant: .simplified).contains("Traditional"))
        XCTAssertEqual(Assistants.languageName("ja-JP"), "Japanese")
        XCTAssertEqual(Assistants.languageName(""), "English")
        XCTAssertEqual(Assistants.languageName("Swahili"), "Swahili")
        XCTAssertNil(Assistants.scriptBlock("  \n"))
        XCTAssertTrue(Assistants.summaryUser(before: "", transcript: "x").contains("(none yet)"))
    }

    func testTheScriptGoesInItsOwnCachedBlockOrTheSystemMessage() throws {
        let a = try JSONSerialization.jsonObject(with: Requests.anthropicBody(model: "m", system: "S", user: "U", effort: "", script: "# Talk", stream: true)) as! [String: Any]
        let blocks = a["system"] as! [[String: Any]]
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNotNil(blocks[1]["cache_control"])
        XCTAssertEqual(a["stream"] as? Bool, true)
        let c = try JSONSerialization.jsonObject(with: Requests.chatBody(model: "m", system: "S", user: "U", effort: "", script: "# Talk")) as! [String: Any]
        let system = (c["messages"] as! [[String: Any]])[0]["content"] as! String
        XCTAssertTrue(system.hasPrefix("S\n\n") && system.contains("<script>\n# Talk\n</script>"))
    }
}

final class ScriptTests: XCTestCase {
    func testTheFormat() {
        let items = Script.parse("# Opening\n! next slide\nHi all.\n> 大家好。\nQ: Why?\n## Spare\n```copy:link\nhttps://x\n```\n\n# Q&A\n```copy:open\nunclosed")
        XCTAssertEqual(items, [
            .section("Opening", index: 0), .cue("next slide"), .line("Hi all."), .gloss("大家好。"), .question("Why?"),
            .sub("Spare"), .copy(name: "link", text: "https://x"), .section("Q&A", index: 1), .copy(name: "open", text: "unclosed"),
        ])
        XCTAssertEqual(Script.sections(items), ["Opening", "Q&A"])
        XCTAssertEqual(Script.sections(Script.parse(Script.template)), ["開場", "Q&A"])
    }

    func testPlanFindsOnlyLinesMissingTheirOtherHalf() {
        let script = "# T\nHi all.\n> 大家好。\nThanks for coming.\n謝謝大家。\nQ: 問題是什麼？\n! cue\n```copy:x\nno\n```\n"
        let needs = Script.plan(script)
        XCTAssertEqual(needs.map(\.text), ["Thanks for coming.", "謝謝大家。", "問題是什麼？"])
        XCTAssertEqual(needs.map(\.direction), [.toChinese, .toSpoken, .toSpoken])
        XCTAssertFalse(Script.isChinese("こんにちは世界"), "kana makes it Japanese")
    }

    func testMergeFillsBothDirectionsAndKeepsTheRest() throws {
        let script = "# T\nThanks for coming.\n謝謝大家。\nQ: 問題是什麼？\n"
        let needs = Script.plan(script)
        let answers = try Script.answers("```json\n[\"谢谢光临。\", \"Thank you all.\", \"What is the question?\"]\n```", expect: 3)
        XCTAssertEqual(Script.merge(script, needs: needs, answers: answers),
                       "# T\nThanks for coming.\n> 謝謝光臨。\nThank you all.\n> 謝謝大家。\nQ: What is the question?\n> 問題是什麼？\n")
        XCTAssertThrowsError(try Script.answers("[\"a\"]", expect: 2))
        XCTAssertTrue(Script.request(needs).contains("\"to\":\"speak\""))
    }
}

final class StreamingTests: XCTestCase {
    func testBothStreamFormats() {
        XCTAssertEqual(Streaming.anthropic(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你"}}"#), .text("你"))
        XCTAssertEqual(Streaming.anthropic(#"data: {"type":"message_stop"}"#), .done)
        XCTAssertEqual(Streaming.anthropic(#"data: {"type":"error","error":{"message":"overloaded"}}"#), .error("overloaded"))
        XCTAssertNil(Streaming.anthropic("event: ping"))
        XCTAssertEqual(Streaming.chat(#"data: {"choices":[{"delta":{"content":"好"}}]}"#), .text("好"))
        XCTAssertEqual(Streaming.chat("data: [DONE]"), .done)
        XCTAssertNil(Streaming.chat(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
    }
}

final class SessionFileTests: XCTestCase {
    func testTranscriptAndNames() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SessionFiles.folderName(Date(timeIntervalSince1970: 0), calendar: cal), "1970-01-01 0000")
        XCTAssertEqual(SessionFiles.hms(3725), "01:02:05")
        let md = SessionFiles.transcript(title: "Transcript", header: ["Started: 14:05"], lines: [
            TranscriptLine(offset: 5, heard: "Hello.", translation: "你好。"), TranscriptLine(offset: 9, heard: " ", translation: ""),
        ])
        XCTAssertEqual(md, "# Transcript\n\n- Started: 14:05\n\n[00:00:05] Hello.\n　你好。\n\n")
        XCTAssertEqual(SessionFiles.forSummary([TranscriptLine(offset: 0, heard: "Hi.", translation: "嗨。")], clock: { _ in "14:05" }), "[14:05] Hi.\n  （嗨。）")
    }
}
