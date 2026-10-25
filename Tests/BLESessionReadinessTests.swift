import XCTest
import CoreBluetooth
@testable import UnleashedCompanion

final class BLESessionReadinessTests: XCTestCase {
    func testActualFlipperTXUsesIndicationsWithoutNotify() {
        let properties: CBCharacteristicProperties = [.read, .indicate]
        XCTAssertFalse(properties.contains(.notify))
        XCTAssertTrue(BLECharacteristicSupport.supportsValueUpdates(properties))
    }

    func testActualFlipperFlowUsesNotifications() {
        XCTAssertTrue(BLECharacteristicSupport.supportsValueUpdates([.read, .notify]))
        XCTAssertTrue(BLECharacteristicSupport.supportsValueUpdates([.read, .notify, .indicate]))
        XCTAssertFalse(BLECharacteristicSupport.supportsValueUpdates([.read, .writeWithoutResponse]))
    }

    func testIndicationsDoNotBypassAcknowledgementOrReinitializeTheSession() {
        var session = BLESessionReadiness()
        session.hasSerialRX = true
        session.hasSerialTX = BLECharacteristicSupport.supportsValueUpdates([.read, .indicate])
        session.hasSerialFlow = BLECharacteristicSupport.supportsValueUpdates([.read, .notify])
        XCTAssertFalse(session.takeSerialReady())
        session.serialTXNotifying = true
        XCTAssertFalse(session.takeSerialReady())
        session.serialFlowNotifying = true
        XCTAssertTrue(session.takeSerialReady())
        XCTAssertFalse(session.takeSerialReady())
    }

    func testEveryPrerequisiteIsRequiredAndReadinessIsIdempotent() {
        for mask in 0..<32 {
            var session = BLESessionReadiness()
            session.hasSerialRX = mask & 1 != 0
            session.hasSerialTX = mask & 2 != 0
            session.hasSerialFlow = mask & 4 != 0
            session.serialTXNotifying = mask & 8 != 0
            session.serialFlowNotifying = mask & 16 != 0
            XCTAssertEqual(session.takeSerialReady(), mask == 31)
            XCTAssertFalse(session.takeSerialReady())
        }
    }

    func testBridgeMayArriveBeforeOrAfterSerialWithoutResettingSerial() {
        var session = BLESessionReadiness()
        session.hasBridgeCommand = true
        session.bridgeNotifying = true
        XCTAssertFalse(session.takeBridgeProbe())
        session.hasSerialRX = true; session.hasSerialTX = true; session.hasSerialFlow = true
        session.serialTXNotifying = true; session.serialFlowNotifying = true
        XCTAssertTrue(session.takeSerialReady())
        XCTAssertTrue(session.takeBridgeProbe())
        XCTAssertFalse(session.takeSerialReady())
        XCTAssertFalse(session.takeBridgeProbe())
        session.serialTXNotifying = false
        XCTAssertFalse(session.takeSerialReady())
        session.serialTXNotifying = true
        XCTAssertTrue(session.takeSerialReady())
    }

    func testEveryUserFacingStateHasAReadableTitleAndExplanation() {
        for state: ConnectionStatus in [.offline, .connecting, .checking, .ready, .waiting, .unresponsive, .buddy] {
            XCTAssertFalse(state.title.isEmpty)
            XCTAssertFalse(state.detail.isEmpty)
            _ = state.color
        }
    }
}
