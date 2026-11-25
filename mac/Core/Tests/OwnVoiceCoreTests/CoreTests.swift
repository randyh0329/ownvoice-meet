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
        let single = try JSONSerialization.jsonObject(with: Requests.chatBody(model: "translategemma:4b", system: "", user: "U", effort: "")) as! [String: Any]
        XCTAssertEqual((single["messages"] as? [[String: Any]])?.count, 1, "TranslateGemma: one user message")

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

final class OllamaTests: XCTestCase {
    func testModelListAndPullLines() {
        XCTAssertTrue(Ollama.hasModel(tags: Data(#"{"models":[{"name":"gemma4:e4b","model":"gemma4:e4b"}]}"#.utf8), model: "gemma4:e4b"))
        XCTAssertTrue(Ollama.hasModel(tags: Data(#"{"models":[{"name":"gemma4:latest"}]}"#.utf8), model: "gemma4:e4b"), "a plain pull of gemma4 is E4B")
        XCTAssertTrue(Ollama.hasModel(tags: Data(#"{"models":[{"name":"translategemma:latest"}]}"#.utf8), model: "translategemma:4b"))
        XCTAssertFalse(Ollama.hasModel(tags: Data(#"{"models":[{"name":"gemma4:e4b"}]}"#.utf8), model: "translategemma:4b"))
        XCTAssertFalse(Ollama.hasModel(tags: Data(#"{"models":[]}"#.utf8), model: "gemma4:e4b"))
        XCTAssertEqual(Ollama.pullStep(#"{"status":"pulling manifest"}"#), .progress(status: "pulling manifest", done: 0, total: 0))
        XCTAssertEqual(Ollama.pullStep(#"{"status":"pulling 4c27","total":6600000000,"completed":1200000000}"#), .progress(status: "pulling 4c27", done: 1_200_000_000, total: 6_600_000_000))
        XCTAssertEqual(Ollama.pullStep(#"{"status":"success"}"#), .done)
        XCTAssertEqual(Ollama.pullStep(#"{"error":"file does not exist"}"#), .error("file does not exist"))
        XCTAssertNil(Ollama.pullStep(""))
    }
}

final class SegmenterTests: XCTestCase {
    let rate = 16_000
    func tone(_ ms: Int) -> [Int16] { (0..<(rate * ms / 1000)).map { Int16(sin(Double($0) * 0.3) * 8000) } }
    func silence(_ ms: Int) -> [Int16] { Array(repeating: 0, count: rate * ms / 1000) }
    func run(_ seg: inout Segmenter, _ audio: [Int16]) -> [SegmentEvent] {
        stride(from: 0, to: audio.count, by: 1600).flatMap { seg.push(Array(audio[$0..<min($0 + 1600, audio.count)])) }
    }

    func testOneSentenceWithPreroll() {
        var seg = Segmenter(rate: rate)
        let ev = run(&seg, silence(600) + tone(1500) + silence(900))
        if case .start = ev.first {} else { XCTFail("starts with start: \(ev.count)") }
        let ends = ev.compactMap { if case let .end(a) = $0 { a.count } else { nil } }
        XCTAssertEqual(ends.count, 1)
        XCTAssertLessThanOrEqual(abs(ends[0] - rate * 2500 / 1000), 480, "300 ms preroll + 1.5 s + 700 ms")
        XCTAssertFalse(seg.inSpeech)
    }

    func testAClickIsDiscardedAndLongSpeechIsCut() {
        var seg = Segmenter(rate: rate)
        XCTAssertTrue(run(&seg, tone(120) + silence(900)).contains(.discard))
        var seg2 = Segmenter(rate: rate)
        XCTAssertEqual(run(&seg2, tone(13_000)).filter { if case .end = $0 { true } else { false } }.count, 1)
    }

    func testWavHeader() {
        let w = WAV.data([0, 1, -1], rate: rate)
        XCTAssertEqual(String(decoding: w.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(w.count, 50)
        XCTAssertEqual(w[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian, UInt32(rate))
    }
}

final class UsageTests: XCTestCase {
    func testCostsAndStreamUsage() {
        var book = UsageBook()
        book.addAudio("gemini-live", seconds: 3600)
        book.addTokens("claude-haiku-5-5", Tokens(input: 180_000, output: 30_000))
        book.addAudio("apple-speech", seconds: 3600)
        XCTAssertEqual(book.total, 0.54 + 0.033, accuracy: 1e-9)
        XCTAssertEqual(Streaming.anthropic(#"data: {"type":"message_start","message":{"usage":{"input_tokens":120,"cache_read_input_tokens":900,"output_tokens":1}}}"#), .usage(Tokens(input: 120, cached: 900, output: 0)))
        XCTAssertEqual(Streaming.anthropic(#"data: {"type":"message_delta","usage":{"output_tokens":42}}"#), .usage(Tokens(output: 42)))
        XCTAssertEqual(Streaming.chat(#"data: {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":1000}}}"#), .usage(Tokens(input: 200, cached: 1000, output: 30)))
        var t = Tokens(input: 120, cached: 900)
        t.merge(Tokens(output: 42))
        XCTAssertEqual(t, Tokens(input: 120, cached: 900, output: 42))
        XCTAssertTrue(Version.isNewer("mac-v0.6.0", than: "0.5.0"))
        XCTAssertFalse(Version.isNewer("mac-v0.5.0", than: "0.5.0"))
        XCTAssertFalse(Version.isNewer("v0.4.9", than: "0.5"))
        XCTAssertTrue(Version.isNewer("0.5.1", than: "0.5"))
    }

    func testTranscriptSegmentsAndTranslateGemma() {
        let md = SessionFiles.transcript(title: "T", header: [], segments: [Segment(name: "Start", offset: 0), Segment(name: "Q&A", offset: 70)], lines: [
            TranscriptLine(offset: 5, heard: "Hi.", translation: "", segment: 0), TranscriptLine(offset: 80, heard: "Why?", translation: "", segment: 1),
        ])
        XCTAssertEqual(md, "# T\n\n\n## 01 · Start (00:00:00)\n\n[00:00:05] Hi.\n\n## 02 · Q&A (00:01:10)\n\n[00:01:20] Why?\n\n")
        let p = Assistants.translateGemma(text: "Hello.", sourceCode: "en-US", variant: .traditionalTaiwan)
        XCTAssertTrue(p.hasPrefix("You are a professional English (en) to Chinese (zh-TW) translator."))
        XCTAssertTrue(p.hasSuffix("into Chinese:\n\n\nHello."))
        XCTAssertTrue(Assistants.translateGemma(text: "x", sourceCode: "ja", variant: .simplified).contains("Japanese (ja) to Chinese (zh-Hans)"))
    }
}

final class RealtimeTests: XCTestCase {
    func testOpenAIAndLiveTranslateMessages() throws {
        let v = try JSONSerialization.jsonObject(with: Data(OpenAIRealtime.sessionUpdate(model: "gpt-live-transcribe", language: "en").utf8)) as! [String: Any]
        let input = (((v["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        XCTAssertEqual((input["format"] as! [String: Any])["rate"] as? Int, 24_000)
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["transcription"] as! [String: Any])["languages"] as? [String], ["en"])
        XCTAssertEqual(OpenAIRealtime.parse(Data(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"Hel"}"#.utf8)), .delta(item: "a", text: "Hel"))
        XCTAssertEqual(OpenAIRealtime.parse(Data(#"{"type":"session.updated"}"#.utf8)), .accepted)
        let t = try JSONSerialization.jsonObject(with: Data(GeminiLive.translateSetup(model: "m", target: "zh-TW", instruction: "I").utf8)) as! [String: Any]
        let s = t["setup"] as! [String: Any]
        XCTAssertEqual(((s["generationConfig"] as! [String: Any])["translationConfig"] as! [String: Any])["targetLanguageCode"] as? String, "zh-TW")
        XCTAssertEqual(GeminiLive.parseTranslate(Data(#"{"serverContent":{"inputTranscription":{"text":" Hi"},"outputTranscription":{"text":"嗨"}}}"#.utf8)), [.heard(" Hi"), .translated("嗨")])
    }
}

final class InterpreterTests: XCTestCase {
    final class Screen: InterpreterSink {
        var lines: [(heard: String, heardDone: Bool, zh: String, zhDone: Bool)] = []
        var dropped: [Int] = []
        func open() -> Int { lines.append(("", false, "", false)); return lines.count - 1 }
        func heard(_ id: Int, _ text: String, done: Bool) { lines[id].heard = text; lines[id].heardDone = done }
        func translated(_ id: Int, _ text: String, done: Bool) { lines[id].zh = text; lines[id].zhDone = done }
        func drop(_ id: Int) { dropped.append(id) }
    }
    let t0 = Date(timeIntervalSince1970: 0)
    func ms(_ n: Double) -> Date { t0.addingTimeInterval(n / 1000) }

    func testASentenceAndItsTranslationMakeOneLine() {
        var i = Interpreter()
        let s = Screen()
        i.heard("Welcome to", now: ms(0), sink: s)
        i.heard(" the panel.", now: ms(300), sink: s)
        i.translated("歡迎來到", now: ms(600), sink: s)
        i.tick(now: ms(1400), sink: s)
        XCTAssertTrue(s.lines[0].heardDone)
        i.translated("座談會。", now: ms(1500), sink: s)
        XCTAssertEqual(s.lines[0].heard, "Welcome to the panel.")
        XCTAssertEqual(s.lines[0].zh, "歡迎來到座談會。")
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertTrue(i.idle)
    }

    func testChineseThatRunsIntoTheNextLineIsSplit() {
        var i = Interpreter()
        let s = Screen()
        i.heard("I am the moderator.", now: ms(0), sink: s)
        i.tick(now: ms(1100), sink: s)
        i.heard("Our first panelist is here.", now: ms(1300), sink: s)
        i.translated("我是主持人。我們的第一位", now: ms(1500), sink: s)
        XCTAssertEqual(s.lines[0].zh, "我是主持人。")
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertEqual(s.lines[1].zh, "我們的第一位")
        XCTAssertFalse(s.lines[1].zhDone)
    }

    func testALineWithoutTranslationEndsAfterAWhile() {
        var i = Interpreter()
        let s = Screen()
        i.heard("大家好。", now: ms(0), sink: s)
        i.tick(now: ms(1000), sink: s)
        i.tick(now: ms(3500), sink: s)
        XCTAssertFalse(s.lines[0].zhDone)
        i.tick(now: ms(4000), sink: s)
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertTrue(i.idle)
    }

    func testFlushEndsEveryLine() {
        var i = Interpreter()
        let s = Screen()
        i.heard("We will", now: ms(0), sink: s)
        i.translated("我們會", now: ms(100), sink: s)
        i.flush(sink: s)
        XCTAssertTrue(s.lines[0].heardDone && s.lines[0].zhDone)
        XCTAssertTrue(i.idle)
    }
}

final class UploadTests: XCTestCase {
    func testFormsAndAnswers() throws {
        let (body, type) = Uploads.transcriptionForm(wav: Data("RIFF".utf8), model: "gpt-4o-mini-transcribe", language: "en-US", boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertEqual(type, "multipart/form-data; boundary=B")
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"speech.wav\"") && text.contains("name=\"language\"\r\n\r\nen\r\n") && text.hasSuffix("--B--\r\n"))
        XCTAssertEqual(try Uploads.transcriptionText(Data(#"{"text":" Hello. "}"#.utf8), status: 200), "Hello.")
        let g = try JSONSerialization.jsonObject(with: Uploads.geminiBody(model: "gemini-3.5-transcribe", language: "en-US", wav: Data("RIFF".utf8))) as! [String: Any]
        XCTAssertEqual(((g["input"] as! [[String: Any]])[0])["data"] as? String, "UklGRg==")
        XCTAssertEqual(try Uploads.geminiText(Data(#"{"status":"completed","steps":[{"type":"model_output","content":[{"type":"text","text":"Hello world"}]}]}"#.utf8), status: 200), "Hello world")
        XCTAssertThrowsError(try Uploads.geminiText(Data(#"{"status":"failed"}"#.utf8), status: 200))
    }

    func testLinesARecognizerManages() {
        var book = CaptionBook()
        let a = book.openLine(), b = book.openLine()
        book.setHeard("Hi", for: a, final: false)
        book.setHeard("There.", for: b, final: true)
        book.setTranslation("那裡。", for: b)
        book.removeLine(a)
        XCTAssertEqual(book.lines, [CaptionLine(id: b, heard: "There.", translation: "那裡。", isFinal: true)])
    }
}

final class ReviewFixTests: XCTestCase {
    func testSessionFoldersNeverCollide() {
        var taken: Set<String> = ["2026-11-25 1405"]
        let second = SessionFiles.uniqueName("2026-11-25 1405") { taken.contains($0) }
        XCTAssertEqual(second, "2026-11-25 1405 2")
        taken.insert(second)
        XCTAssertEqual(SessionFiles.uniqueName("2026-11-25 1405") { taken.contains($0) }, "2026-11-25 1405 3")
        XCTAssertEqual(SessionFiles.uniqueName("2026-11-25 1406") { taken.contains($0) }, "2026-11-25 1406")
    }

    func testStoppingMidSentenceEndsTheUtterance() {
        let rate = 16_000
        let tone = (0..<(rate * 800 / 1000)).map { Int16(sin(Double($0) * 0.3) * 8000) }
        var seg = Segmenter(rate: rate)
        _ = seg.push(tone)
        XCTAssertTrue(seg.inSpeech)
        guard case let .end(audio)? = seg.finish() else { return XCTFail("the sentence being spoken ends") }
        XCTAssertGreaterThan(audio.count, rate / 2)
        XCTAssertFalse(seg.inSpeech)
        XCTAssertNil(seg.finish(), "nothing more")
        var click = Segmenter(rate: rate)
        _ = click.push(Array(tone.prefix(rate / 10)))
        XCTAssertEqual(click.finish(), .discard, "too short to be speech")
    }
}
