import Foundation

enum ConnectionStatus: String {
    case offline, connecting, checking, ready, waiting, unresponsive, buddy

    var title: String {
        switch self {
        case .offline: return "Offline"
        case .connecting: return "Connecting"
        case .checking: return "Checking"
        case .ready: return "Ready"
        case .waiting: return "In use"
        case .unresponsive: return "No response"
        case .buddy: return "Buddy"
        }
    }
}

enum ConnectionProbeResult { case verified, busy, failed, unavailable }

/// Presentation evidence, deliberately separate from the CoreBluetooth transport
/// state. Times are monotonic uptime values, never wall-clock dates.
struct ConnectionEvidence {
    private(set) var status: ConnectionStatus = .offline
    private(set) var generation: UInt64 = 0
    private(set) var lastResponseUptime: TimeInterval?
    private var transportReady = false
    private var buddy = false

    mutating func transportChanged(ready: Bool, connecting: Bool) {
        generation &+= 1
        transportReady = ready
        buddy = false
        lastResponseUptime = nil
        status = ready ? .checking : (connecting ? .connecting : .offline)
    }

    mutating func setSerialOwnedByBuddy(_ owned: Bool) {
        guard buddy != owned else { return }
        generation &+= 1
        buddy = owned
        lastResponseUptime = nil
        if transportReady { status = owned ? .buddy : .checking }
    }

    mutating func beginVerification() {
        guard transportReady, !buddy else { return }
        status = .checking
    }

    mutating func receivedRPC(at uptime: TimeInterval) {
        guard transportReady, !buddy else { return }
        lastResponseUptime = uptime
        status = .ready
    }

    mutating func finishVerification(
        _ result: ConnectionProbeResult,
        generation expected: UInt64,
        startedAt: TimeInterval,
        now: TimeInterval
    ) {
        guard generation == expected, transportReady, !buddy else { return }
        // A real screen/response frame received during this check is stronger
        // evidence than a probe failure (e.g. while the device is busy).
        if let response = lastResponseUptime, response >= startedAt {
            status = .ready
            return
        }
        switch result {
        case .verified: receivedRPC(at: now)
        case .busy: status = .waiting
        case .failed, .unavailable: status = .unresponsive
        }
    }
}
