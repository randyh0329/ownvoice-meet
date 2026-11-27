import XCTest
@testable import OwnVoiceCore

final class ServerModelsTests: XCTestCase {
    func testTheModelsAddressComesFromTheServerAddress() {
        XCTAssertEqual(ServerModels.url(base: "http://localhost:8000/v1")?.absoluteString, "http://localhost:8000/v1/models")
        XCTAssertEqual(ServerModels.url(base: "  https://example.com/v1// ")?.absoluteString, "https://example.com/v1/models")
        XCTAssertNil(ServerModels.url(base: ""))
        XCTAssertNil(ServerModels.url(base: "localhost:8000/v1"))
        XCTAssertNil(ServerModels.url(base: "ftp://example.com"))
    }

    func testAnOpenAIStyleListGivesItsIDsInOrder() throws {
        let body = #"{"object":"list","data":[{"id":"qwen3-8b","object":"model"},{"id":"large-v3"},{"id":"qwen3-8b"},{"id":" "}]}"#
        XCTAssertEqual(try ServerModels.ids(Data(body.utf8), status: 200), ["qwen3-8b", "large-v3"])
    }

    func testOllamaAndBareListsAreReadToo() throws {
        let ollama = #"{"models":[{"name":"gemma4:e4b","model":"gemma4:e4b"},{"model":"qwen3:1.7b"}]}"#
        XCTAssertEqual(try ServerModels.ids(Data(ollama.utf8), status: 200), ["gemma4:e4b", "qwen3:1.7b"])
        XCTAssertEqual(try ServerModels.ids(Data(#"["a",{"id":"b"}]"#.utf8), status: 200), ["a", "b"])
        XCTAssertEqual(try ServerModels.ids(Data(#"{"data":[]}"#.utf8), status: 200), [])
    }

    func testAnErrorOrAPageIsNotAList() {
        XCTAssertThrowsError(try ServerModels.ids(Data(#"{"error":{"message":"bad key"}}"#.utf8), status: 401)) { error in
            XCTAssertEqual(error as? ServiceError, ServiceError("401：bad key"))
        }
        XCTAssertThrowsError(try ServerModels.ids(Data("<html>hello</html>".utf8), status: 200)) { error in
            XCTAssertEqual(error as? ServerModels.NotAList, ServerModels.NotAList())
        }
        XCTAssertThrowsError(try ServerModels.ids(Data(#"{"ok":true}"#.utf8), status: 200))
    }
}

final class DemoTests: XCTestCase {
    func testADozenLinesInBothScripts() {
        XCTAssertEqual(Demo.lines.count, 12)
        for line in Demo.lines + [Demo.reply] {
            XCTAssertFalse(line.english.isEmpty)
            XCTAssertNotEqual(line.traditional, line.simplified, line.english)
            XCTAssertFalse(ChineseScript.isSimplified(line.traditional), line.traditional)
            XCTAssertEqual(line.chinese(.traditionalTaiwan), line.traditional)
            XCTAssertEqual(line.chinese(.simplified), line.simplified)
        }
    }

    func testPartialsGrowThreeWordsAtATime() {
        XCTAssertEqual(Demo.partials("one two three four five six seven"), ["one two three", "one two three four five six"])
        XCTAssertEqual(Demo.partials("too short"), [])
    }

    func testTheChineseStreamsInAndEndsWhole() {
        XCTAssertEqual(Demo.translationSteps("一二三四五六七八九"), ["一二三四", "一二三四五六七八", "一二三四五六七八九"])
        XCTAssertEqual(Demo.translationSteps("一二三四"), ["一二三四"])
        XCTAssertEqual(Demo.translationSteps(""), [])
    }
}
