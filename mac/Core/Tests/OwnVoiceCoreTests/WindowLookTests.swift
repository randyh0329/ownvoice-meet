import XCTest
@testable import OwnVoiceCore

final class WindowLookTests: XCTestCase {
    func testTextSizeStepsUpAndDown() {
        XCTAssertEqual(WindowLook.stepText(20, up: true), 22)
        XCTAssertEqual(WindowLook.stepText(20, up: false), 18)
        XCTAssertEqual(WindowLook.stepText(28, up: true), 32)
    }

    func testASizeBetweenStepsMovesToTheNearestStepThatWay() {
        XCTAssertEqual(WindowLook.stepText(25, up: true), 28)
        XCTAssertEqual(WindowLook.stepText(25, up: false), 24)
    }

    func testTheEndsStayPut() {
        XCTAssertEqual(WindowLook.stepText(48, up: true), 48)
        XCTAssertEqual(WindowLook.stepText(12, up: false), 12)
        XCTAssertEqual(WindowLook.stepText(60, up: true), 48)
        XCTAssertEqual(WindowLook.stepText(8, up: false), 12)
        XCTAssertEqual(WindowLook.textRange, 12...48)
    }

    func testOpacityStaysReadable() {
        XCTAssertEqual(WindowLook.clampOpacity(0.1), 0.4)
        XCTAssertEqual(WindowLook.clampOpacity(1.5), 1)
        XCTAssertEqual(WindowLook.clampOpacity(0.7), 0.7)
    }
}
