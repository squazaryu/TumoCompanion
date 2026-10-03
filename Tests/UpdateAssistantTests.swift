import XCTest
@testable import UnleashedCompanion

final class UpdateAssistantTests: XCTestCase {
    func testInventoryDiffIsReadOnlyAndDoesNotInventDeletionCause() throws {
        let old = try CaptureInventory(files: [
            .init(path: "subghz/one.sub", size: 10, md5: String(repeating: "a", count: 32)),
            .init(path: "subghz/two.sub", size: 11, md5: String(repeating: "b", count: 32))])
        let current = try CaptureInventory(files: [
            .init(path: "subghz/one.sub", size: 10, md5: String(repeating: "c", count: 32)),
            .init(path: "subghz/new.sub", size: 12, md5: String(repeating: "d", count: 32))])
        let diff = old.compare(to: current)
        XCTAssertEqual(diff.map(\.path), ["subghz/new.sub", "subghz/one.sub", "subghz/two.sub"])
        XCTAssertEqual(diff.map(\.kind), [.added, .changed, .missing])
    }

    func testUnknownDigestDoesNotCountAsEqual() throws {
        let unknown = try CaptureInventory(files: [.init(path: "subghz/one.sub", size: 1, md5: nil)])
        XCTAssertEqual(unknown.compare(to: unknown).first?.kind, .unverified)
        XCTAssertThrowsError(try CaptureInventory(files: [.init(path: "../outside", size: 1, md5: nil)]))
        XCTAssertThrowsError(try CaptureInventory(files: [.init(path: "subghz/one.sub", size: 1, md5: "short")]))
    }

    func testUnknownOrManualEvidenceCannotBecomePassed() {
        XCTAssertFalse(UpdateCheck.unknown.isPassed)
        XCTAssertFalse(UpdateCheck.manual.isPassed)
        XCTAssertTrue(UpdateCheck.passed.isPassed)
    }

    func testAcceptanceReportIsBoundToFirmwareAndLeavesManualItemsPending() throws {
        let data = Data("Tumoflip Hardware Acceptance Suite\nSchema: 1\nVersion: t-dev-009-017\nCommit: 12345678\nTarget: 7\n[PASS] SD read/write\n[PENDING] own radio\n".utf8)
        let summary = try AcceptanceSummary.parse(data, version: "t-dev-009-017", commit: "12345678")
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.manual, 1)
        XCTAssertThrowsError(try AcceptanceSummary.parse(data, version: "t-dev-009-018", commit: "12345678"))
        XCTAssertThrowsError(try AcceptanceSummary.parse(data, version: "t-dev-009-017", commit: "87654321"))
    }
}
