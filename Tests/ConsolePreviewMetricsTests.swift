import XCTest
@testable import UnleashedCompanion

final class ConsolePreviewMetricsTests: XCTestCase {
    func testFractionalAndLargerControlHeightsAreExplicit() {
        XCTAssertEqual(ConsolePreviewMetrics.height(matchingControls: 119.6667), 120)
        XCTAssertEqual(ConsolePreviewMetrics.height(matchingControls: 132), 132)
        XCTAssertEqual(ConsolePreviewMetrics.height(matchingControls: 180.2), 181)
    }

    func testSmallOrTransientMeasurementsNeverShrinkBelowMinimum() {
        for height: CGFloat in [-1, 0, 80, 108] {
            XCTAssertEqual(ConsolePreviewMetrics.height(matchingControls: height), 108)
        }
    }

    func testNonfiniteMeasurementsCannotEscapeIntoLayout() {
        for height: CGFloat in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(ConsolePreviewMetrics.height(matchingControls: height), 108)
        }
    }
}
