import Foundation
import Combine

/// The RPC layer depends on a byte channel, not on CoreBluetooth lifecycle or
/// CBPeripheral objects. Tests can exercise the real parser/probe without a radio.
protocol FlipperRPCTransport: AnyObject {
    var state: FlipperConnectionState { get }
    var serialOwner: SerialChannelOwner { get }
    var serialIn: PassthroughSubject<BLESerialPacket, Never> { get }
    var statePublisher: AnyPublisher<FlipperConnectionState, Never> { get }
    var ownerPublisher: AnyPublisher<SerialChannelOwner, Never> { get }
    func waitUntilReady(timeout: TimeInterval) async -> Bool
    func writeSerial(_ data: Data, completion: (() -> Void)?)
}

extension FlipperBLE: FlipperRPCTransport {
    var statePublisher: AnyPublisher<FlipperConnectionState, Never> { $state.eraseToAnyPublisher() }
    var ownerPublisher: AnyPublisher<SerialChannelOwner, Never> { $serialOwner.eraseToAnyPublisher() }
}
