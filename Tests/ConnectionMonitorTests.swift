import XCTest
@testable import UnleashedCompanion

@MainActor
final class ConnectionMonitorTests: XCTestCase {
    func testReadyRequiresAResponseNotJustGATT() async {
        let monitor = ConnectionMonitor(probe: { .verified }, uptime: { 20 })
        monitor.transportChanged(ready: true, connecting: false)
        XCTAssertEqual(monitor.status, .checking)
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .ready)
    }

    func testBusyTransferDoesNotGetDisconnectedOrProbedAgain() async {
        var probes = 0
        let monitor = ConnectionMonitor(probe: { probes += 1; return .busy })
        monitor.transportChanged(ready: true, connecting: false)
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .waiting)
        XCTAssertEqual(probes, 1)
    }

    func testCachedScreenDoesNotMakeFailedProbeReady() async {
        var now: TimeInterval = 1
        let monitor = ConnectionMonitor(probe: { .failed }, uptime: { now })
        monitor.transportChanged(ready: true, connecting: false)
        monitor.receivedRPC()
        now = 20
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .unresponsive)
    }

    func testRealScreenTrafficOutweighsProbeFailure() async {
        var monitor: ConnectionMonitor!
        monitor = ConnectionMonitor(probe: {
            monitor.receivedRPC()
            return .failed
        })
        monitor.transportChanged(ready: true, connecting: false)
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .ready)
    }

    func testLateProbeCannotResurrectDisconnectedSession() async {
        var monitor: ConnectionMonitor!
        monitor = ConnectionMonitor(probe: {
            monitor.transportChanged(ready: false, connecting: false)
            return .verified
        })
        monitor.transportChanged(ready: true, connecting: false)
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .offline)
    }

    func testBuddyDoesNotReceiveRPCProbe() async {
        var probes = 0
        let monitor = ConnectionMonitor(probe: { probes += 1; return .verified })
        monitor.transportChanged(ready: true, connecting: false)
        monitor.serialOwnerChanged(isBuddy: true)
        await monitor.verifyNow()
        XCTAssertEqual(monitor.status, .buddy)
        XCTAssertEqual(probes, 0)
    }

    func testConcurrentChecksAreCoalesced() async {
        var probes = 0
        let monitor = ConnectionMonitor(probe: {
            probes += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return .verified
        })
        monitor.transportChanged(ready: true, connecting: false)
        async let first: Void = monitor.verifyNow()
        async let second: Void = monitor.verifyNow()
        _ = await (first, second)
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(monitor.status, .ready)
    }

    func testBackgroundDoesNotPoll() async throws {
        var probes = 0
        let monitor = ConnectionMonitor(probe: { probes += 1; return .verified })
        monitor.transportChanged(ready: true, connecting: false)
        monitor.setForegroundActive(false)
        await monitor.verifyNow()
        XCTAssertEqual(probes, 0)
        monitor.setForegroundActive(true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(probes, 1)
        monitor.setForegroundActive(false)
    }

    func testGateTryAcquireNeverJumpsAheadOfActiveOperation() async {
        let gate = RPCCommandGate()
        await gate.acquire()
        XCTAssertFalse(gate.tryAcquire())
        gate.release()
        XCTAssertTrue(gate.tryAcquire())
        gate.release()
    }
}
