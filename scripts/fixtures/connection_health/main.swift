import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
    checks += 1
}

var readiness = BLESessionReadiness()
readiness.hasSerialRX = true
readiness.hasSerialTX = true
readiness.hasSerialFlow = true
check(!readiness.takeSerialReady(), "Discovery alone must not publish ready")
readiness.serialTXNotifying = true
check(!readiness.takeSerialReady(), "Flow-control notification must also be confirmed")
readiness.serialFlowNotifying = true
check(readiness.takeSerialReady(), "Confirmed serial subscriptions make transport ready")
check(!readiness.takeSerialReady(), "Other service callbacks must not reinitialize TX credit")
readiness.hasBridgeCommand = true
check(!readiness.takeBridgeProbe(), "Do not probe before bridge notifications are confirmed")
readiness.bridgeNotifying = true
check(readiness.takeBridgeProbe(), "Late bridge subscription must still start negotiation")
check(!readiness.takeBridgeProbe(), "Probe only once per transport session")
readiness = BLESessionReadiness()
check(!readiness.serialReady, "New session must not reuse old GATT evidence")

var evidence = ConnectionEvidence()
evidence.transportChanged(ready: true, connecting: false)
check(evidence.status == .checking, "GATT ready must not mean RPC verified")
let generation = evidence.generation
evidence.receivedRPC(at: 10)
check(evidence.status == .ready, "Actual screen/response traffic proves RPC alive")
evidence.beginVerification()
check(evidence.status == .checking, "Foreground return must recheck a retained ready flag")
evidence.finishVerification(.busy, generation: generation, startedAt: 11, now: 12)
check(evidence.status == .waiting, "Do not interrupt a transfer or claim untested readiness")
evidence.receivedRPC(at: 13)
evidence.finishVerification(.failed, generation: generation, startedAt: 12, now: 15)
check(evidence.status == .ready, "Live screen frames outweigh a failed probe")
evidence.beginVerification()
evidence.finishVerification(.failed, generation: generation, startedAt: 16, now: 20)
check(evidence.status == .unresponsive, "A cached frame must not keep the UI green")
evidence.transportChanged(ready: false, connecting: false)
evidence.finishVerification(.verified, generation: generation, startedAt: 16, now: 21)
check(evidence.status == .offline, "A late probe must not resurrect a disconnected session")
evidence.receivedRPC(at: 22)
check(evidence.status == .offline, "Late frames while offline are not proof of a new link")
evidence.transportChanged(ready: true, connecting: false)
check(evidence.lastResponseUptime == nil, "New session must not inherit old traffic")
evidence.setSerialOwnedByBuddy(true)
check(evidence.status == .buddy, "Buddy owns serial; it is not a broken RPC connection")
evidence.setSerialOwnedByBuddy(false)
check(evidence.status == .checking, "RPC must be rechecked when Buddy releases serial")
evidence.finishVerification(.verified, generation: evidence.generation, startedAt: 23, now: 24)
check(evidence.status == .ready && evidence.lastResponseUptime == 24,
      "Successful correlated ping verifies the current session")
print("Connection policy: \(checks) checks passed")
