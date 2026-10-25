import XCTest
import Combine
@testable import UnleashedCompanion

final class RPCConnectionProbeTests: XCTestCase {
    func testCorrelatedPingRequiresMatchingNonce() async throws {
        let transport = ProbeTransport()
        let rpc = FlipperRPC(ble: transport)
        transport.onWrite = { bytes in transport.reply(to: bytes, matchingNonce: true) }
        let result = try await rpc.probeConnectionIfIdle(timeout: 0.1)
        XCTAssertEqual(result, .verified)
        XCTAssertEqual(transport.writes, 1)
    }

    func testMismatchedNonceFailsWithoutDisconnect() async throws {
        let transport = ProbeTransport()
        let rpc = FlipperRPC(ble: transport)
        transport.onWrite = { bytes in transport.reply(to: bytes, matchingNonce: false) }
        do {
            _ = try await rpc.probeConnectionIfIdle(timeout: 0.1)
            XCTFail("A mismatched pong must not verify the connection")
        } catch { XCTAssertTrue(error is FlipperRPCError) }
        XCTAssertEqual(transport.state, .ready)
    }

    func testMissingResponseIsBoundedAndReleasesGate() async throws {
        let transport = ProbeTransport()
        let rpc = FlipperRPC(ble: transport)
        do {
            _ = try await rpc.probeConnectionIfIdle(timeout: 0.02)
            XCTFail("Expected deadline")
        } catch { XCTAssertTrue(error is FlipperRPCError) }
        transport.onWrite = { bytes in transport.reply(to: bytes, matchingNonce: true) }
        let result = try await rpc.probeConnectionIfIdle(timeout: 0.1)
        XCTAssertEqual(result, .verified)
    }

    func testSecondProbeYieldsToInFlightRequest() async throws {
        let transport = ProbeTransport()
        let rpc = FlipperRPC(ble: transport)
        let first = Task { try await rpc.probeConnectionIfIdle(timeout: 0.1) }
        while transport.writes == 0 { await Task.yield() }
        let second = try await rpc.probeConnectionIfIdle(timeout: 0.1)
        XCTAssertEqual(second, .busy)
        _ = try? await first.value
        XCTAssertEqual(transport.writes, 1)
    }

    func testOfflineAndBuddyNeverSendRPCProbe() async throws {
        let transport = ProbeTransport()
        let rpc = FlipperRPC(ble: transport)
        transport.owner.send(.claudeBuddy)
        let buddy = try await rpc.probeConnectionIfIdle(timeout: 0.1)
        XCTAssertEqual(buddy, .unavailable)
        transport.owner.send(.rpc)
        transport.connection.send(.disconnected)
        let offline = try await rpc.probeConnectionIfIdle(timeout: 0.1)
        XCTAssertEqual(offline, .unavailable)
        XCTAssertEqual(transport.writes, 0)
    }
}

private final class ProbeTransport: FlipperRPCTransport {
    let connection = CurrentValueSubject<FlipperConnectionState, Never>(.ready)
    let owner = CurrentValueSubject<SerialChannelOwner, Never>(.rpc)
    let serialIn = PassthroughSubject<BLESerialPacket, Never>()
    let sessionID = UUID()
    var state: FlipperConnectionState { connection.value }
    var serialOwner: SerialChannelOwner { owner.value }
    var statePublisher: AnyPublisher<FlipperConnectionState, Never> { connection.eraseToAnyPublisher() }
    var ownerPublisher: AnyPublisher<SerialChannelOwner, Never> { owner.eraseToAnyPublisher() }
    var onWrite: ((Data) -> Void)?
    private let lock = NSLock()
    private var writeCount = 0
    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }

    func waitUntilReady(timeout: TimeInterval) async -> Bool { state == .ready }
    func writeSerial(_ data: Data, completion: (() -> Void)?) {
        lock.lock(); writeCount += 1; lock.unlock()
        completion?()
        onWrite?(data)
    }

    func reply(to bytes: Data, matchingNonce: Bool) {
        guard let (_, header) = FlipperRPC.readVarint(bytes),
              let request = try? PB_Main(serializedBytes: bytes.dropFirst(header)),
              case .systemPingRequest(let ping) = request.content else { return }
        var response = PB_Main()
        response.commandID = request.commandID
        var pong = PBSystem_PingResponse()
        pong.data = matchingNonce ? ping.data : Data([0])
        response.content = .systemPingResponse(pong)
        let frame = try! FlipperRPC.delimited(response)
        serialIn.send(BLESerialPacket(data: frame, sessionID: sessionID))
    }
}
