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
