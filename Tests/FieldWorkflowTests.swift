import CryptoKit
import XCTest
@testable import UnleashedCompanion

final class FieldWorkflowTests: XCTestCase {
    func testRoundPreservesManualResultsAndPendingState() throws {
        let text = "Field round\nStarted UTC epoch: 100\nExplicit user results; opening a file is not a test.\nObject\tResult\tUTC epoch\tNote\nGate\tPROBLEM\t101\tNo response\nSensor\tPENDING\t0\t\n"
        let report = try FieldRoundDocument.parse(Data(text.utf8))
        XCTAssertEqual(report.pending,1)
        XCTAssertEqual(report.rows.first?.result,.problem)
        XCTAssertThrowsError(try FieldRoundDocument.parse(Data(text.replacingOccurrences(of:"PROBLEM",with:"OPENED").utf8)))
    }
    func testComparisonTextDoesNotProveCompletedOrCleanScan() throws {
        let report = try FieldComparisonDocument.parse(Data())
        XCTAssertFalse(report.provesCompleteScan)
        XCTAssertTrue(report.rows.isEmpty)
        XCTAssertThrowsError(try FieldComparisonDocument.parse(Data("MISSING\t/ext/subghz/../file.sub\n".utf8)))
    }
}
