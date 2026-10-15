import XCTest
import SwiftProtobuf
@testable import UnleashedCompanion

final class RPCReadBudgetTests: XCTestCase {
    func testRangeWireFieldsAndLegacyDefaults() throws {
        var request = PBStorage_ReadRequest()
        request.path = "/ext/example.sub"
        request.offset = 3
        request.size = 21
        let decoded = try PBStorage_ReadRequest(serializedBytes: request.serializedData())
        XCTAssertEqual(decoded.path, request.path)
        XCTAssertEqual(decoded.offset, 3)
        XCTAssertEqual(decoded.size, 21)
        let legacy = try PBStorage_ReadRequest(serializedBytes: Data([0x0A, 2, 47, 120]))
        XCTAssertEqual(legacy.path, "/x")
        XCTAssertEqual(legacy.offset, 0)
        XCTAssertEqual(legacy.size, 0)
    }

    func testRangeAcknowledgementRoundTripAndLegacyRejection() throws {
        var response = PBStorage_ReadResponse()
        response.file.data = Data([1, 2, 3])
        response.ranged = true
        let decoded = try PBStorage_ReadResponse(serializedBytes: response.serializedData())
        XCTAssertTrue(decoded.ranged && decoded.hasFile)
        XCTAssertEqual(decoded.file.data, Data([1, 2, 3]))
        response.ranged = false
        let legacy = try PBStorage_ReadResponse(serializedBytes: response.serializedData())
        var budget = RPCReadBudget(maximumBytes: 3, requireRangedRead: true)
        XCTAssertFalse(budget.accept(legacy.file.data.count, rangeAcknowledged: legacy.ranged))
        XCTAssertTrue(budget.rangeUnsupported)
    }

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
