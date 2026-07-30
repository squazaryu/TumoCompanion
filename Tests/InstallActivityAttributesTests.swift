import XCTest
import UnleashedShared

final class InstallActivityAttributesTests: XCTestCase {
    func testProgressNormalizesInvalidCounts() {
        let state = InstallActivityAttributes.ContentState(
            current: -3,
            total: 0,
            detail: "Starting",
            phase: .running
        )

        XCTAssertEqual(state.current, 0)
        XCTAssertEqual(state.total, 1)
        XCTAssertEqual(state.fraction, 0)
        XCTAssertEqual(state.progressText, "0%")
    }

    func testProgressCapsAtOneHundredPercent() {
        let state = InstallActivityAttributes.ContentState(
            current: 8,
            total: 4,
            detail: "Done",
            phase: .succeeded
        )

        XCTAssertEqual(state.fraction, 1)
        XCTAssertEqual(state.progressText, "Done")
        XCTAssertEqual(state.compactProgressText, "✓")
    }

    func testPartialFailureHasDistinctTerminalState() {
        let state = InstallActivityAttributes.ContentState(
            current: 3,
            total: 4,
            detail: "One failed",
            phase: .completedWithIssues
        )

        XCTAssertEqual(state.progressText, "Issues")
        XCTAssertEqual(state.compactProgressText, "!")
    }
}
