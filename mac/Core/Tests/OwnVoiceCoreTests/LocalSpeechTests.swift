import XCTest
@testable import OwnVoiceCore

final class LocalSpeechTests: XCTestCase {
    func testEachLanguageGoesToTheModelThatKnowsIt() {
        XCTAssertEqual(LocalSpeech.route("en-US"), .parakeet)
        XCTAssertEqual(LocalSpeech.route("en-GB"), .parakeet)
        XCTAssertEqual(LocalSpeech.route("de-DE"), .parakeet)
        XCTAssertEqual(LocalSpeech.route("zh-TW"), .senseVoice)
        XCTAssertEqual(LocalSpeech.route("ja-JP"), .senseVoice)
        XCTAssertEqual(LocalSpeech.route("ko-KR"), .senseVoice)
        XCTAssertEqual(LocalSpeech.route(""), .auto)
    }

    func testSenseVoiceIsHintedOnlyWithLanguagesItKnows() {
        XCTAssertEqual(LocalSpeech.senseVoiceHint("ja-JP"), "ja")
        XCTAssertEqual(LocalSpeech.senseVoiceHint("ko-KR"), "ko")
        XCTAssertEqual(LocalSpeech.senseVoiceHint("vi-VN"), "auto")
        XCTAssertEqual(LocalSpeech.senseVoiceHint(""), "auto")
    }

    func testOnAutomaticChineseStaysWithSenseVoiceAndEnglishGoesToParakeet() {
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: " 我们今天讨论 AI 的影响。", language: "<|zh|>"), .senseVoice("我们今天讨论 AI 的影响。", chinese: true))
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "粤语", language: "<|yue|>"), .senseVoice("粤语", chinese: true))
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "thank you everyone", language: "<|en|>"), .parakeet)
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "", language: ""), .parakeet)
    }

    func testJapaneseAndKoreanAreKeptOnlyWhenWrittenInTheirOwnScript() {
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "ありがとうございます。", language: "<|ja|>"), .senseVoice("ありがとうございます。", chinese: false))
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "감사합니다.", language: "<|ko|>"), .senseVoice("감사합니다.", chinese: false))
        // English it took for Japanese comes out in Latin letters: Parakeet hears it.
        XCTAssertEqual(LocalSpeech.outcome(route: .auto, text: "so the plan", language: "<|ja|>"), .parakeet)
    }

    func testAChosenLanguageKeepsItsModel() {
        XCTAssertEqual(LocalSpeech.outcome(route: .senseVoice, text: "こんにちは", language: "<|ja|>"), .senseVoice("こんにちは", chinese: false))
        XCTAssertEqual(LocalSpeech.outcome(route: .senseVoice, text: "你好", language: "<|zh|>"), .senseVoice("你好", chinese: true))
        XCTAssertEqual(LocalSpeech.outcome(route: .parakeet, text: "你好", language: "<|zh|>"), .parakeet)
    }

    func testEveryModelComesFromItsRepositoryByItsOwnName() {
        XCTAssertEqual(LocalSpeech.files.count, 6)
        for f in LocalSpeech.files {
            let parts = f.name.split(separator: "/").map(String.init)
            XCTAssertEqual(parts.count, 2)
            XCTAssertTrue(LocalSpeech.folders.contains(parts[0]))
            let repo = parts[0] == "parakeet-v3" ? "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8" : "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
            XCTAssertEqual(f.url.absoluteString, "https://huggingface.co/csukuangfj/\(repo)/resolve/main/\(parts[1])")
            XCTAssertEqual(f.sha256.count, 64)
        }
        // About 910 MB, as Settings says.
        XCTAssertEqual(LocalSpeech.totalBytes / 1_000_000, 910)
    }
}
