import Foundation

/// Queue-confined evidence for ONE GATT session. Discovery is not subscription
/// confirmation. Taking either transition is idempotent across service callbacks.
struct BLESessionReadiness {
    var hasSerialRX = false
    var hasSerialTX = false
    var hasSerialFlow = false
    var serialTXNotifying = false
    var serialFlowNotifying = false
    var hasBridgeCommand = false
    var bridgeNotifying = false
    private var publishedSerialReady = false
    private var startedBridgeProbe = false

    var serialReady: Bool {
        hasSerialRX && hasSerialTX && hasSerialFlow &&
            serialTXNotifying && serialFlowNotifying
    }

    mutating func takeSerialReady() -> Bool {
        guard serialReady, !publishedSerialReady else { return false }
        publishedSerialReady = true
        return true
    }

    mutating func takeBridgeProbe() -> Bool {
        guard serialReady, hasBridgeCommand, bridgeNotifying,
              !startedBridgeProbe else { return false }
        startedBridgeProbe = true
        return true
    }
}
