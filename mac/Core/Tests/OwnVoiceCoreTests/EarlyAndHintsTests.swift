import XCTest
@testable import OwnVoiceCore

final class EarlyTranslationTests: XCTestCase {
    let long = "so the plan for the next quarter is to move"

    func testEarlyTranslationWaitsThenThrottles() {
        let t0 = Date()
        var l = LineTranslations()
        l.opened(1, at: t0)
        XCTAssertFalse(l.wantsEarly(1, text: long, now: t0 + 3), "not before 4 s")
        XCTAssertFalse(l.wantsEarly(1, text: "so the plan", now: t0 + LineTranslations.earlyAfter), "too short to be worth it")
        XCTAssertTrue(l.wantsEarly(1, text: long, now: t0 + LineTranslations.earlyAfter))
        _ = l.start(1, text: long, early: true, now: t0 + 4)
        let longer = "so the plan for the next quarter is to move the whole deployment"
        XCTAssertFalse(l.wantsEarly(1, text: longer, now: t0 + 5), "at most every 2 s")
        XCTAssertFalse(l.wantsEarly(1, text: long, now: t0 + 6), "same text again")
        XCTAssertTrue(l.wantsEarly(1, text: longer, now: t0 + 6))
        _ = l.start(1, text: longer, early: false, now: t0 + 6)
        XCTAssertFalse(l.wantsEarly(1, text: longer + " now", now: t0 + 60), "never after the sentence ended")
        XCTAssertFalse(l.wantsEarly(2, text: long, now: t0 + 60), "a line never opened")
    }

    func testAFinishedRequestCancelsOlderOnesAndOlderNeverOverwriteNewer() {
        let t0 = Date()
        var l = LineTranslations()
        let a = l.start(1, text: "first part of it", early: true, now: t0).seq
        let b = l.start(1, text: "first part of it and more", early: true, now: t0).seq
        let r = l.accept(1, seq: b, length: 12, complete: true)
        XCTAssertTrue(r.shown)
        XCTAssertEqual(r.cancelled, [a])
        XCTAssertFalse(l.accept(1, seq: a, length: 30, complete: true).shown)
        XCTAssertFalse(l.accept(1, seq: b, length: 5, complete: false).shown, "a late piece of a request already complete")
    }

    func testTheFinalTranslationReplacesTheEarlyOneOnceItCatchesUp() {
        let t0 = Date()
        var l = LineTranslations()
        let e = l.start(1, text: "an early part of the sentence", early: true, now: t0).seq
        XCTAssertTrue(l.accept(1, seq: e, length: 10, complete: false).shown)
        XCTAssertTrue(l.accept(1, seq: e, length: 20, complete: true).shown)
        let (f, cancelled) = l.start(1, text: "an early part of the sentence, finished.", early: false, now: t0)
        XCTAssertEqual(cancelled, [e], "the final request cancels early ones")
        XCTAssertFalse(l.accept(1, seq: f, length: 5, complete: false).shown, "keeps the fuller early text while the final one starts")
        XCTAssertTrue(l.accept(1, seq: f, length: 21, complete: false).shown)
        XCTAssertTrue(l.accept(1, seq: f, length: 22, complete: false).shown)
        XCTAssertFalse(l.accept(1, seq: e, length: 25, complete: true).shown)
        XCTAssertTrue(l.accept(1, seq: f, length: 22, complete: true).shown)
        l.done(1, seq: f)
        XCTAssertFalse(l.accept(1, seq: f, length: 30, complete: false).shown, "forgotten once done")
    }

    func testAnEarlyTranslationStillRunningWhenTheFinalOneStartsShowsNothingMore() {
        let t0 = Date()
        var l = LineTranslations()
        let e = l.start(1, text: "an early part of the sentence", early: true, now: t0).seq
        _ = l.start(1, text: "an early part of the sentence, finished.", early: false, now: t0)
        XCTAssertFalse(l.accept(1, seq: e, length: 40, complete: false).shown)
    }

    func testASentenceThatCameToNothingIsDropped() {
        let t0 = Date()
        var l = LineTranslations()
        l.opened(1, at: t0)
        _ = l.start(2, text: "done", early: false, now: t0)
        let e = l.start(3, text: "a sentence still going on", early: true, now: t0).seq
        XCTAssertEqual(Set(l.dropUnfinished()), [1, 3])
        XCTAssertFalse(l.accept(3, seq: e, length: 10, complete: true).shown)
    }

    func testNotesInsteadOfATranslationAreNotShownEarly() {
        XCTAssertTrue(LineTranslations.readsAsSubtitle("遷移到新叢集，然後在每個團隊都簽核之後"))
        XCTAssertTrue(LineTranslations.readsAsSubtitle("把 Kubernetes 叢集升級"))
        XCTAssertFalse(LineTranslations.readsAsSubtitle("to the new cluster and then retire the old build servers once every"))
        XCTAssertFalse(LineTranslations.readsAsSubtitle("遷移到新的叢集\n\nWait, I must output only the translation."))
        XCTAssertFalse(LineTranslations.readsAsSubtitle(""))
        XCTAssertFalse(LineTranslations.readsAsSubtitle("図書館は来年三月までに移行します"))
        XCTAssertFalse(LineTranslations.readsAsSubtitle("도서관은 내년 삼월까지"))
        XCTAssertFalse(LineTranslations.readsAsSubtitle("café déjà vu über 好"), "accented words still count as words")
    }

    func testTheUnfinishedRequestAsksForAFragment() {
        let user = Prompts.listenUser(context: [], utterance: "so the plan for the next quarter is", unfinished: true)
        XCTAssertTrue(user.contains("still talking"))
        XCTAssertTrue(user.hasSuffix("so the plan for the next quarter is"))
    }
}

final class RecognitionHintsTests: XCTestCase {
    let glossary = """
    # names
    庫伯尼提斯 = Kubernetes
    大查詢 = BigQuery
    K8s = kubernetes
    壞的 = <tag>
    沒有等號
    """

    func testTermsAreTheMeetingSideOnceEach() {
        XCTAssertEqual(Prompts.recognitionTerms(glossary: glossary), ["Kubernetes", "BigQuery"])
        XCTAssertEqual(Prompts.recognitionTerms(glossary: ""), [])
        let many = (1...150).map { "詞\($0) = Term\($0)" }.joined(separator: "\n")
        XCTAssertEqual(Prompts.recognitionTerms(glossary: many).count, Prompts.maxRecognitionTerms)
    }

    func testTheUploadPromptListsTheTermsAndStaysShort() {
        XCTAssertEqual(Prompts.transcriptionPrompt(terms: ["Kubernetes", "BigQuery"]), "Names and terms in this meeting: Kubernetes, BigQuery.")
        XCTAssertEqual(Prompts.transcriptionPrompt(terms: []), "")
        let long = Prompts.transcriptionPrompt(terms: (1...100).map { "SomeLongProductName\($0)" })
        XCTAssertLessThan(long.count, 700)
        XCTAssertTrue(long.hasSuffix("."))
    }

    func testTheTermsGoIntoEachRequest() throws {
        let terms = ["Kubernetes", "BigQuery"]
        let live = try JSONSerialization.jsonObject(with: Data(GeminiLive.setupMessage(model: "m", language: "en-US", terms: terms).utf8)) as! [String: Any]
        let transcription = (live["setup"] as! [String: Any])["inputAudioTranscription"] as! [String: Any]
        XCTAssertEqual(transcription["customVocabulary"] as? [String], terms)
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["en-US"])
        let none = try JSONSerialization.jsonObject(with: Data(GeminiLive.setupMessage(model: "m", language: "").utf8)) as! [String: Any]
        XCTAssertNil(((none["setup"] as! [String: Any])["inputAudioTranscription"] as! [String: Any])["customVocabulary"])

        let rt = try JSONSerialization.jsonObject(with: Data(OpenAIRealtime.sessionUpdate(model: "gpt-live-transcribe", language: "en", terms: terms).utf8)) as! [String: Any]
        let input = ((rt["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any]
        XCTAssertEqual((input["transcription"] as! [String: Any])["keywords"] as? [String], terms)

        let g = try JSONSerialization.jsonObject(with: Uploads.geminiBody(model: "gemini-3.5-transcribe", language: "en-US", wav: Data("RIFF".utf8), terms: terms)) as! [String: Any]
        let config = (g["generation_config"] as! [String: Any])["transcription_config"] as! [String: Any]
        XCTAssertEqual(config["custom_vocabulary"] as? [String], terms)
        XCTAssertEqual(config["language_codes"] as? [String], ["en-US"])

        let prompt = Prompts.transcriptionPrompt(terms: terms)
        let form = String(decoding: Uploads.transcriptionForm(wav: Data("RIFF".utf8), model: "whisper-1", language: "en", prompt: prompt, boundary: "B").body, as: UTF8.self)
        XCTAssertTrue(form.contains("name=\"prompt\"\r\n\r\n\(prompt)\r\n"))
        let bare = String(decoding: Uploads.transcriptionForm(wav: Data("RIFF".utf8), model: "whisper-1", language: "en", boundary: "B").body, as: UTF8.self)
        XCTAssertFalse(bare.contains("prompt"))
    }
}

final class RecognitionHintsFallbackTests: XCTestCase {
    func testRefusedHintsAreDroppedForTheSessionAndAnnouncedOnce() {
        let hints = RecognitionHints(["Kubernetes", "BigQuery"])
        XCTAssertEqual(hints.terms, ["Kubernetes", "BigQuery"])
        XCTAssertFalse(hints.takeNotice(), "nothing to tell before a refusal")
        hints.refuse()
        XCTAssertEqual(hints.terms, [])
        XCTAssertTrue(hints.takeNotice())
        XCTAssertFalse(hints.takeNotice(), "said once")
        hints.refuse()
        XCTAssertFalse(hints.takeNotice(), "a second refusal is not announced again")
        XCTAssertEqual(hints.terms, [])
    }

    func testOnlyARejectedRequestIsRetriedWithoutTheHints() {
        XCTAssertTrue(RecognitionHints.mayBeRefused(status: 400))
        XCTAssertTrue(RecognitionHints.mayBeRefused(status: 422))
        for status in [200, 401, 403, 404, 408, 429, 500, 503] {
            XCTAssertFalse(RecognitionHints.mayBeRefused(status: status), String(status))
        }
    }
}
