import XCTest
@testable import UnleashedCompanion

final class RPCReadBudgetTests: XCTestCase {
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
