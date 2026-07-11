import XCTest
@testable import CodexResetsWindow

final class CodexWindowTests: XCTestCase {
    func testRemainingPercentageIsClamped() {
        let window = UsageWindow(limitWindowSeconds: 18_000, resetAfterSeconds: 60, resetAt: .now, usedPercent: 12)
        XCTAssertEqual(window.remainingPercent, 88)
    }
}
