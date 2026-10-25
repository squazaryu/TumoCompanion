import Foundation
import Combine

/// App-facing health, not another BLE transport. Passive decoded RPC traffic
/// counts as proof; otherwise one low-priority ping is allowed while foregrounded.
/// No background polling, forced disconnect, or parallel storage command.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var evidence = ConnectionEvidence()
    var status: ConnectionStatus { evidence.status }

    private let probe: () async throws -> ConnectionProbeResult
    private let uptime: () -> TimeInterval
    private var subscriptions = Set<AnyCancellable>()
    private var verificationTask: Task<ConnectionProbeResult?, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var requestID: UInt64 = 0
    private var foregroundActive = true

    init(
        probe: @escaping () async throws -> ConnectionProbeResult,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.probe = probe
        self.uptime = uptime
    }

    convenience init(ble: FlipperBLE = .shared, rpc: FlipperRPC = .shared) {
        self.init(probe: { try await rpc.probeConnectionIfIdle() })
        ble.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transportChanged(
                    ready: state == .ready,
                    connecting: state == .connecting || state == .connected || state == .scanning
                )
                if state == .ready { await self.verifyNow() }
            }
        }.store(in: &subscriptions)
        ble.$serialOwner.removeDuplicates().sink { [weak self] owner in
            Task { @MainActor [weak self] in
                self?.serialOwnerChanged(isBuddy: owner == .claudeBuddy)
                if owner == .rpc { await self?.verifyNow() }
            }
        }.store(in: &subscriptions)
        rpc.validTraffic
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self, weak ble] sessionID in
                // A queued old frame must never verify a different BLE session.
                guard sessionID == ble?.activeSessionID else { return }
                self?.receivedRPC()
            }.store(in: &subscriptions)
    }

    deinit {
        verificationTask?.cancel()
        foregroundTask?.cancel()
    }

    func transportChanged(ready: Bool, connecting: Bool) {
        invalidateVerification()
        evidence.transportChanged(ready: ready, connecting: connecting)
    }

    func serialOwnerChanged(isBuddy: Bool) {
        let generation = evidence.generation
        evidence.setSerialOwnedByBuddy(isBuddy)
        if evidence.generation != generation { invalidateVerification() }
    }

    func receivedRPC() {
        evidence.receivedRPC(at: uptime())
    }

    func setForegroundActive(_ active: Bool) {
        foregroundTask?.cancel()
        foregroundTask = nil
        foregroundActive = active
        guard active else {
            invalidateVerification()
            return
        }
        foregroundTask = Task { [weak self] in
            await self?.verifyNow()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                if let response = self.evidence.lastResponseUptime,
                   self.status == .ready, self.uptime() - response < 10 { continue }
                await self.verifyNow()
            }
        }
    }

    func verifyNow() async {
        guard foregroundActive, verificationTask == nil,
              status != .offline, status != .connecting, status != .buddy else { return }
        evidence.beginVerification()
        let generation = evidence.generation
        let started = uptime()
        requestID &+= 1
        let request = requestID
        let probe = self.probe
        let task = Task<ConnectionProbeResult?, Never> {
            do { return try await probe() }
            catch is CancellationError { return nil }
            catch { return .failed }
        }
        verificationTask = task
        let result = await task.value
        guard requestID == request else { return }
        verificationTask = nil
        guard let result else { return }
        evidence.finishVerification(result, generation: generation, startedAt: started, now: uptime())
    }

    private func invalidateVerification() {
        requestID &+= 1
        verificationTask?.cancel()
        verificationTask = nil
    }
}
