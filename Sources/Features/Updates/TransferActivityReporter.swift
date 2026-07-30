import Foundation
import os

private let tlog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "transfer")

/// Reports long BLE file-transfer activity to tumoflip firmware so the Flipper
/// statusbar can show a small transfer spinner next to the BLE icon.
@MainActor
final class TransferActivityReporter {
    private let channel: TransferChannel
    private let heartbeatInterval: TimeInterval
    private let reasonProvider: () -> String?
    private let commandSender: (_ command: String, _ label: String) -> Void
    private var lastPulse = Date.distantPast
    private var loggedSkipReason: String?
    private var heartbeatTask: Task<Void, Never>?
    private var currentLabel = ""

    init(
        channel: TransferChannel,
        ble: FlipperBLE = .shared,
        heartbeatInterval: TimeInterval = 10
    ) {
        self.channel = channel
        self.heartbeatInterval = heartbeatInterval
        self.reasonProvider = {
            guard channel == .ble else { return "not BLE" }
            guard ble.state == .ready else { return "not ready" }
            guard ble.supportsAppBridge else { return "no App Bridge" }
            guard ble.appBridgeV2 else { return "FAB2 not negotiated" }
            guard RuntimeCapabilities(ble.appBridgeCapabilities).supportsTransferActivity else {
                return "capability missing"
            }
            return nil
        }
        self.commandSender = { command, label in
            ble.sendAppBridge(
                appID: "runtime",
                command: command,
                payload: Data(String(label.prefix(96)).utf8)
            )
        }
    }

    /// Injectable transport used by the heartbeat tests. The production initializer
    /// above remains the only call site in the app.
    init(
        channel: TransferChannel,
        heartbeatInterval: TimeInterval,
        reasonProvider: @escaping () -> String?,
        commandSender: @escaping (_ command: String, _ label: String) -> Void
    ) {
        self.channel = channel
        self.heartbeatInterval = heartbeatInterval
        self.reasonProvider = reasonProvider
        self.commandSender = commandSender
    }

    /// Waits briefly for FAB2 to finish negotiating after the link reaches
    /// `.ready` — there's a real gap (up to a few seconds) where `ble.state ==
    /// .ready` but `appBridgeV2`/capabilities haven't landed yet from the
    /// firmware's async capability probe. Calling `begin()` during that gap
    /// silently drops the event and the on-device indicator never appears for
    /// the rest of the transfer (companion issue #18).
    ///
    /// Only that specific gap is worth waiting out: every other unavailable
    /// reason (no App Bridge service at all, capability missing, …) is
    /// permanent for this connection, so waiting the full timeout would just
    /// add dead time to every BLE install on firmware that doesn't support
    /// this — those return immediately instead. `send()` logs the final
    /// reason once `begin()` runs. Never fails the install: callers should
    /// proceed regardless of the result.
    func prepare(timeout: TimeInterval = 3) async -> Bool {
        guard channel == .ble else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reason = unavailableReason()
            guard reason == "FAB2 not negotiated" else { return reason == nil }
            guard Date() < deadline else { return false }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false   // task cancelled — don't busy-spin re-checking a dead deadline
            }
        }
    }

    func begin(_ label: String) {
        heartbeatTask?.cancel()
        currentLabel = label
        lastPulse = .distantPast
        loggedSkipReason = nil
        send("transfer_begin", label: label)
        heartbeatTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delay = UInt64(max(0.005, self.heartbeatInterval) * 1_000_000_000)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                // The firmware clears the header wave after 30 seconds without a
                // transfer event. A heartbeat keeps it active even while one large
                // FAP is still inside a single DeviceFileStore.write call.
                self.send("transfer_progress", label: self.currentLabel)
            }
        }
    }

    func progress(_ label: String, force: Bool = false) {
        currentLabel = label
        let now = Date()
        guard force || now.timeIntervalSince(lastPulse) >= 2 else { return }
        lastPulse = now
        send("transfer_progress", label: label)
    }

    func end() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        send("transfer_end", label: "")
    }

    /// Why a `send()` would currently be dropped, or nil if reporting is available.
    /// Shared by `prepare()` (to know when to stop waiting) and `send()` (to log
    /// once why an event was skipped) so the two can't drift out of sync.
    private func unavailableReason() -> String? {
        reasonProvider()
    }

    private func send(_ command: String, label: String) {
        guard channel == .ble else { return }
        if let reason = unavailableReason() {
            if reason != loggedSkipReason {
                loggedSkipReason = reason
                tlog.notice("transfer activity \(command, privacy: .public) skipped: \(reason, privacy: .public)")
            }
            return
        }
        loggedSkipReason = nil
        commandSender(command, label)
    }
}
