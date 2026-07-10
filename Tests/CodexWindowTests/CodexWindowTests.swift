import XCTest
@testable import CodexWindow

final class CodexWindowTests: XCTestCase {
    func testRemainingPercentageIsClamped() {
        let window = UsageWindow(limitWindowSeconds: 18_000, resetAfterSeconds: 60, resetAt: .now, usedPercent: 12)
        XCTAssertEqual(window.remainingPercent, 88)
    }
}
