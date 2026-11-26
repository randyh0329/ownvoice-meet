import Foundation
import XCTest
@testable import OwnVoiceCore

/// Live Translate following another recognizer (ported from the first version's gemini_translate.rs tests).
final class FollowingTests: XCTestCase {
    /// Records what reaches the screen: per line, what was said and the Chinese, and whether each is done.
    final class Screen: InterpreterSink {
        var lines: [(heard: String, heardDone: Bool, zh: String, zhDone: Bool)] = []
        var dropped: [Int] = []
        /// Lines handed to the text model, with what was said on them.
        var toTextModel: [(Int, String)] = []

        func open() -> Int {
            lines.append(("", false, "", false))
            return lines.count - 1
        }

        func heard(_ id: Int, _ text: String, done: Bool) {
            XCTAssertFalse(lines[id].heardDone, "line \(id) heard after it ended")
            lines[id].heard = text
            lines[id].heardDone = done
        }

        func translated(_ id: Int, _ text: String, done: Bool) {
            // Late Chinese may extend a complete line, never reopen it.
            XCTAssertTrue(!lines[id].zhDone || done, "line \(id) reopened after its translation was complete")
            lines[id].zh = text
            lines[id].zhDone = done
        }

        func drop(_ id: Int) { dropped.append(id) }

        func untranslated(_ id: Int, _ heard: String) {
            XCTAssertFalse(lines[id].zhDone, "line \(id) already had its translation")
            toTextModel.append((id, heard))
        }

        var textModelIDs: [Int] { toTextModel.map(\.0) }
    }

    let t0 = Date(timeIntervalSince1970: 1000)
    func ms(_ n: Double) -> Date { t0.addingTimeInterval(n / 1000) }

    func testOnlyTheChineseComesFromLiveTranslate() {
        let s = Screen()
        var i = Interpreter(following: true)
        let a = s.open()
        i.openLine(a)
        i.translated("歡迎來到", now: ms(500), sink: s)
        i.tick(now: ms(3000), sink: s)
        XCTAssertEqual(s.lines[0].zh, "歡迎來到")
        XCTAssertFalse(s.lines[0].heardDone || s.lines[0].zhDone, "the recognizer ends lines, not pauses here")
        XCTAssertTrue(i.endLine(a, "Welcome to the panel.", now: ms(3100), sink: s))
        i.translated("座談會。", now: ms(3200), sink: s)
        XCTAssertEqual(s.lines[0].zh, "歡迎來到座談會。")
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertEqual(s.lines[0].heard, "", "what was said is the recognizer's to show")
        // Late Chinese with no line waiting joins the line just completed.
        i.translated("各位好。", now: ms(3600), sink: s)
        XCTAssertEqual(s.lines[0].zh, "歡迎來到座談會。各位好。")
        // Later, it waits for the next line.
        i.translated("今天", now: ms(6000), sink: s)
        let b = s.open()
        i.openLine(b)
        i.translated("談數位典藏。", now: ms(6200), sink: s)
        XCTAssertEqual(s.lines[1].zh, "今天談數位典藏。")
        XCTAssertFalse(s.lines[1].zhDone, "not before the recognizer ends the line")
        XCTAssertTrue(i.endLine(b, "Today it is digital archives.", now: ms(6500), sink: s))
        XCTAssertTrue(s.lines[1].zhDone)
        XCTAssertTrue(i.idle)
    }

    func testOpeningALineTwiceChangesNothing() {
        let s = Screen()
        var i = Interpreter(following: true)
        let a = s.open()
        i.openLine(a)
        i.translated("我們", now: ms(100), sink: s)
        i.openLine(a)
        XCTAssertTrue(i.endLine(a, "We go.", now: ms(200), sink: s))
        i.translated("走吧。", now: ms(300), sink: s)
        XCTAssertEqual(s.lines[0].zh, "我們走吧。")
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertTrue(i.idle)
    }

    func testADroppedLineHandsItsChineseOn() {
        let s = Screen()
        var i = Interpreter(following: true)
        let (a, b) = (s.open(), s.open())
        i.openLine(a)
        i.translated("我們", now: ms(100), sink: s)
        i.openLine(b)
        i.removeLine(a)
        i.translated("開始吧。", now: ms(200), sink: s)
        XCTAssertTrue(i.endLine(b, "Let's start.", now: ms(300), sink: s))
        XCTAssertEqual(s.lines[1].zh, "我們開始吧。")
        XCTAssertTrue(s.lines[1].zhDone)
    }

    func testASessionEndingKeepsLinesStillBeingSpoken() {
        let s = Screen()
        var i = Interpreter(following: true)
        let (a, b) = (s.open(), s.open())
        i.openLine(a)
        _ = i.endLine(a, "First.", now: ms(0), sink: s)
        i.openLine(b)
        i.flush(sink: s)
        XCTAssertEqual(s.textModelIDs, [a], "the ended line had no Chinese: the text model translates it")
        XCTAssertEqual(s.toTextModel.first?.1, "First.")
        XCTAssertFalse(i.idle, "the line still being spoken waits for the next session")
        i.translated("第二句。", now: ms(5000), sink: s)
        XCTAssertTrue(i.endLine(b, "Second.", now: ms(5100), sink: s))
        XCTAssertEqual(s.lines[1].zh, "第二句。")
        XCTAssertTrue(s.lines[1].zhDone)
    }

    func testOneSentenceHeardTwoInChineseStayOneLine() {
        let s = Screen()
        var i = Interpreter(following: true)
        let a = s.open()
        i.openLine(a)
        XCTAssertTrue(i.endLine(a, "Right, let's start.", now: ms(0), sink: s))
        i.translated("對。我們開始吧。", now: ms(1200), sink: s)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].zh, "對。我們開始吧。")
        XCTAssertTrue(s.lines[0].zhDone)
        XCTAssertTrue(i.idle)
        // The same when the two sentences come in pieces.
        let t = Screen()
        var j = Interpreter(following: true)
        let b = t.open()
        j.openLine(b)
        _ = j.endLine(b, "Right, let's start.", now: ms(0), sink: t)
        j.translated("對。", now: ms(1200), sink: t)
        XCTAssertTrue(t.lines[0].zhDone)
        j.translated("我們開始", now: ms(1400), sink: t)
        j.translated("吧。", now: ms(1500), sink: t)
        XCTAssertEqual(t.lines[0].zh, "對。我們開始吧。")
        XCTAssertTrue(t.lines[0].zhDone)
        j.tick(now: ms(9000), sink: t)
        XCTAssertTrue(j.idle)
        XCTAssertTrue(t.toTextModel.isEmpty)
    }

    func testChineseLongAfterTheLastLineWaitsForTheNext() {
        let s = Screen()
        var i = Interpreter(following: true)
        let a = s.open()
        i.openLine(a)
        _ = i.endLine(a, "Thanks.", now: ms(0), sink: s)
        i.translated("謝謝。", now: ms(100), sink: s)
        XCTAssertTrue(s.lines[0].zhDone)
        i.translated("下一位", now: ms(2000), sink: s)
        XCTAssertEqual(s.lines[0].zh, "謝謝。", "past orphanLate: not the last line's")
        let b = s.open()
        i.openLine(b)
        _ = i.endLine(b, "Next speaker, please.", now: ms(2500), sink: s)
        i.translated("講者，請。", now: ms(2600), sink: s)
        XCTAssertEqual(s.lines[1].zh, "下一位講者，請。")
        XCTAssertTrue(s.lines[1].zhDone)
    }

    func testALineWithNoChineseGoesToTheTextModel() {
        let s = Screen()
        var i = Interpreter(following: true)
        let a = s.open()
        i.openLine(a)
        XCTAssertTrue(i.endLine(a, "Thanks.", now: ms(0), sink: s))
        i.tick(now: ms(3500), sink: s)
        XCTAssertEqual(s.textModelIDs, [a])
        XCTAssertEqual(s.toTextModel.first?.1, "Thanks.")
        XCTAssertFalse(s.lines[0].zhDone, "not completed with no Chinese")
        XCTAssertTrue(i.idle)
        // A session ending (rotated) hands its ended lines with no Chinese on the same way.
        let b = s.open()
        i.openLine(b)
        _ = i.endLine(b, "Next.", now: ms(4000), sink: s)
        i.flush(sink: s)
        XCTAssertEqual(s.textModelIDs, [a, b])
        // A line opened before the pairing began is not taken.
        XCTAssertFalse(i.endLine(99, "Earlier.", now: ms(5000), sink: s))
    }

    func testWhileDisconnectedTheTextModelTranslates() {
        let s = Screen()
        var i = Interpreter(following: true)
        let (a, b) = (s.open(), s.open())
        i.openLine(a)
        i.translated("歡迎", now: ms(100), sink: s)
        _ = i.endLine(a, "Welcome.", now: ms(200), sink: s)
        i.openLine(b)
        // The connection drops: the ended line keeps what it has, the one being spoken is the text model's.
        i.pause(sink: s)
        XCTAssertEqual(s.lines[a].zh, "歡迎")
        XCTAssertTrue(s.lines[a].zhDone)
        XCTAssertTrue(i.away)
        let c = s.open()
        i.openLine(c)
        XCTAssertFalse(i.endLine(c, "Said while it was away.", now: ms(1000), sink: s), "the text model translates it")
        // Back: the line spoken across the gap is the text model's, yet takes the Chinese of its tail.
        i.resume()
        let d = s.open()
        i.openLine(d)
        i.translated("那件事。", now: ms(2000), sink: s)
        XCTAssertFalse(i.endLine(b, "And about that matter.", now: ms(2100), sink: s))
        i.translated("下一句。", now: ms(2300), sink: s)
        XCTAssertTrue(i.endLine(d, "Next sentence.", now: ms(2400), sink: s))
        XCTAssertEqual(s.lines[b].zh, "", "the tail's Chinese did not land under it")
        XCTAssertEqual(s.lines[d].zh, "下一句。", "nor under the next line")
        XCTAssertTrue(s.lines[d].zhDone)
        XCTAssertTrue(s.toTextModel.isEmpty, "the caller sends lines not taken to the text model")
        XCTAssertTrue(i.idle)
    }

    func testAStaleRunLeavesTheNewerRunAlone() {
        let s = Screen()
        var f = LiveTranslateFollowing()
        XCTAssertFalse(f.following)
        let first = f.on(sink: s)
        XCTAssertTrue(f.following)
        let a = s.open()
        f.lineOpened(a)
        f.translated(run: first, "第一", now: ms(100), sink: s)
        // Listening stopped and started again while the first run still winds down.
        let second = f.on(sink: s)
        XCTAssertNotEqual(first, second)
        let b = s.open()
        f.lineOpened(b)
        f.translated(run: first, "舊的。", now: ms(200), sink: s)
        f.pause(run: first, sink: s)
        XCTAssertTrue(f.following, "the old run's pause does not touch the new one")
        f.translated(run: second, "新的。", now: ms(300), sink: s)
        XCTAssertTrue(f.lineEnded(b, "The new one.", now: ms(400), sink: s))
        XCTAssertEqual(s.lines[b].zh, "新的。")
        XCTAssertTrue(s.lines[b].zhDone)
        XCTAssertTrue(f.idle(run: second))
        XCTAssertTrue(f.idle(run: first), "a stale run has nothing waiting")
        // The line of the first run is no longer paired: the text model has it.
        XCTAssertFalse(f.lineEnded(a, "The old one.", now: ms(500), sink: s))
        // The old run's off leaves the new run on; the new run's off ends it.
        f.off(run: first, sink: s)
        XCTAssertTrue(f.following)
        f.off(run: second, sink: s)
        XCTAssertFalse(f.following)
        let c = s.open()
        f.lineOpened(c)
        XCTAssertFalse(f.lineEnded(c, "After.", now: ms(600), sink: s), "with Live Translate off, the text model translates")
    }

    func testTheSpeakingLineIsKnownUntilItEnds() {
        var book = CaptionBook()
        XCTAssertNil(book.speakingLine)
        let id = book.partial("…")
        XCTAssertEqual(book.speakingLine, id)
        XCTAssertNil(book.finish(""), "an empty final drops the line")
        XCTAssertNil(book.speakingLine)
    }

    func testPauseAndResumeOfTheCurrentRun() {
        let s = Screen()
        var f = LiveTranslateFollowing()
        let run = f.on(sink: s)
        f.pause(run: run, sink: s)
        XCTAssertFalse(f.following, "disconnected: the text model translates")
        let a = s.open()
        f.lineOpened(a)
        XCTAssertFalse(f.lineEnded(a, "Away.", now: ms(0), sink: s))
        f.resume(run: run)
        XCTAssertTrue(f.following)
        let b = s.open()
        f.lineOpened(b)
        XCTAssertTrue(f.lineEnded(b, "Back.", now: ms(100), sink: s))
        XCTAssertFalse(f.idle(run: run))
        f.translated(run: run, "回來了。", now: ms(200), sink: s)
        XCTAssertTrue(s.lines[b].zhDone)
        XCTAssertTrue(f.idle(run: run))
    }
}
