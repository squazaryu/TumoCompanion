import XCTest
@testable import UnleashedCompanion

final class RPCReadBudgetTests: XCTestCase {
    func testRangedReadRequiresAcknowledgementOnEveryChunk() {
        var budget = RPCReadBudget(maximumBytes: 10, requireRangedRead: true)
        XCTAssertTrue(budget.accept(2, rangeAcknowledged: true))
        XCTAssertFalse(budget.accept(2, rangeAcknowledged: false))
        XCTAssertTrue(budget.rangeUnsupported)
        XCTAssertFalse(budget.accept(1, rangeAcknowledged: true))
        XCTAssertEqual(budget.acceptedBytes, 2)
    }

    func testLegacyReplyIsDrainedWithoutRetainingItsData() {
        var budget = RPCReadBudget(maximumBytes: 1, requireRangedRead: true)
        XCTAssertFalse(budget.accept(512, rangeAcknowledged: false))
        XCTAssertTrue(budget.rangeUnsupported)
        XCTAssertEqual(budget.acceptedBytes, 0)
        XCTAssertFalse(budget.accept(512, rangeAcknowledged: false))
    }

    func testFreshBudgetStartsEmptyAndNotExceeded() {
        let budget = RPCReadBudget(maximumBytes: 128)
        XCTAssertEqual(budget.maximumBytes, 128)
        XCTAssertEqual(budget.acceptedBytes, 0)
        XCTAssertFalse(budget.exceeded)
    }

    func testOversizedReplyStaysFailedWhileRemainingFramesDrain() {
        var budget = RPCReadBudget(maximumBytes: 3)
        XCTAssertTrue(budget.accept(2))
        XCTAssertFalse(budget.accept(2))
        XCTAssertTrue(budget.exceeded)
        XCTAssertFalse(budget.accept(0))
        XCTAssertEqual(budget.acceptedBytes, 2)
    }
    func testArithmeticDoesNotOverflow() {
        var budget = RPCReadBudget(maximumBytes: Int.max)
        XCTAssertTrue(budget.accept(Int.max))
        XCTAssertFalse(budget.accept(1))
        var empty = RPCReadBudget(maximumBytes: 0)
        XCTAssertTrue(empty.accept(0))
        XCTAssertFalse(empty.accept(-1))
    }
}
