import XCTest
@testable import OwnVoiceCore

final class VenueTests: XCTestCase {
    func testSegmentNamesComeFromTheAgendaThenRunOut() {
        let agenda = Agenda.names("Keynote\n\n  Session 3A: Digital Libraries \r\n")
        XCTAssertEqual(agenda, ["Keynote", "Session 3A: Digital Libraries"])
        XCTAssertEqual(Agenda.name(agenda, at: 0), "Keynote")
        XCTAssertEqual(Agenda.name(agenda, at: 1), "Session 3A: Digital Libraries")
        XCTAssertNil(Agenda.name(agenda, at: 2))
        XCTAssertNil(Agenda.name([], at: 0))
    }

    func testFileNamesAreSafe() {
        XCTAssertEqual(SessionFiles.segmentStem(3, "Session 3A: Digital Libraries"), "03-Session 3A Digital Libraries")
        XCTAssertEqual(SessionFiles.segmentStem(1, "a/b\\c*?\"<>|"), "01-a b c")
        XCTAssertEqual(SessionFiles.segmentStem(12, "  ...  "), "12")
        XCTAssertEqual(SessionFiles.segmentStem(2, "段落 2."), "02-段落 2")
        XCTAssertEqual(SessionFiles.segmentStem(4, "tab\there\nnew"), "04-tab here new")
        XCTAssertEqual(SessionFiles.segmentStem(1, String(repeating: "x", count: 100)).count, 3 + 60)
        XCTAssertEqual(SessionFiles.segmentStem(100, "Q&A"), "100-Q&A")
    }

    func testEachSegmentGetsItsOwnTranscript() {
        let segments = [Segment(name: "Keynote", offset: 0), Segment(name: "Q&A", offset: 65)]
        let lines = [
            TranscriptLine(offset: 12, heard: "Welcome.", translation: "歡迎。", segment: 0),
            TranscriptLine(offset: 70, heard: "Any questions?", translation: "", segment: 1, speaker: "Ann"),
        ]
        let second = SessionFiles.segmentTranscript(index: 1, header: ["Started: 14:05"], segments: segments, lines: lines)
        XCTAssertEqual(second, "# 02 · Q&A (00:01:05)\n\n- Started: 14:05\n\n[00:01:10] Ann：Any questions?\n\n")
        let first = SessionFiles.segmentTranscript(index: 0, header: [], segments: segments, lines: lines)
        XCTAssertTrue(first.hasPrefix("# 01 · Keynote (00:00:00)\n"))
        XCTAssertTrue(first.contains("Welcome.\n　歡迎。\n"))
        XCTAssertFalse(first.contains("Any questions?"))
        XCTAssertEqual(SessionFiles.segmentTranscript(index: 2, header: [], segments: segments, lines: lines), "")
    }

    func testMicrophoneCheckVerdicts() {
        XCTAssertEqual(MicVerdict(peak: 0), .almostSilent)
        XCTAssertEqual(MicVerdict(peak: 0.002), .almostSilent)
        XCTAssertEqual(MicVerdict(peak: 0.01), .tooQuiet)
        XCTAssertEqual(MicVerdict(peak: 0.1), .fine)
        XCTAssertEqual(MicVerdict(peak: 0.8), .tooLoud)
    }

    func testGainLiftsAndClips() {
        var samples: [Float] = [0.1, -0.1, 0.3, -0.6]
        samples.withUnsafeMutableBufferPointer { MicLevel.apply(gain: 2, to: $0) }
        XCTAssertEqual(samples, [0.2, -0.2, 0.6, -1])
        samples.withUnsafeMutableBufferPointer { MicLevel.apply(gain: 4, to: $0) }
        XCTAssertEqual(samples, [0.8, -0.8, 1, -1])
        XCTAssertEqual(MicLevel.nearestGain(3.1), 4)
        XCTAssertEqual(MicLevel.nearestGain(40), 8)
        XCTAssertEqual(MicLevel.nearestGain(0), 1)
        XCTAssertEqual(MicLevel.meter(0), 0)
        XCTAssertEqual(MicLevel.meter(1), 1)
        XCTAssertEqual(MicLevel.meter(0.04), 0.48, accuracy: 0.001)
    }
}
