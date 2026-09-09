import Foundation
import UIKit

/// The operation kinds that can be resumed or explained after iOS suspends the app.
/// Only metadata is persisted; package bytes never leave the existing cache and are
/// therefore not duplicated in UserDefaults.
enum TransferRecoveryKind: String, Codable, Equatable {
    case firmware
    case packages
    case communityApps
    case esp32
}

enum TransferRecoveryState: String, Codable, Equatable {
    case running
    case paused
}

struct TransferRecoveryCheckpoint: Codable, Equatable {
    let id: UUID
    let kind: TransferRecoveryKind
    let releaseID: String?
    var completed: Int
    var total: Int
    var detail: String
    var state: TransferRecoveryState

    init(
        id: UUID = UUID(),
        kind: TransferRecoveryKind,
        releaseID: String? = nil,
        completed: Int,
        total: Int,
        detail: String,
        state: TransferRecoveryState = .running
    ) {
        self.id = id
        self.kind = kind
        self.releaseID = releaseID
        self.completed = max(0, completed)
        self.total = max(1, total)
        self.detail = String(detail.prefix(160))
        self.state = state
    }
}

/// Small, crash-safe intent record for long transfers. The device-side package
/// journal remains the source of truth for file integrity; this record only lets the
/// app explain why the next foreground run needs a reconnect/retry.
final class TransferRecoveryStore {
    static let shared = TransferRecoveryStore()

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "transfer.recovery.checkpoint.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> TransferRecoveryCheckpoint? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TransferRecoveryCheckpoint.self, from: data)
    }

    @discardableResult
    func save(_ checkpoint: TransferRecoveryCheckpoint) -> Bool {
        guard let data = try? JSONEncoder().encode(checkpoint) else { return false }
        defaults.set(data, forKey: key)
        return defaults.synchronize() && load() == checkpoint
    }

    func clear() {
        defaults.removeObject(forKey: key)
        _ = defaults.synchronize()
    }

    /// A process can disappear without running an install's defer block. On the
    /// next launch a still-running checkpoint is therefore a recoverable pause, not
    /// evidence that the previous transfer completed.
    @discardableResult
    func markInterruptedAsPaused() -> TransferRecoveryCheckpoint? {
        guard var checkpoint = load(), checkpoint.state == .running else {
            return load()
        }
        checkpoint.state = .paused
        _ = save(checkpoint)
        return checkpoint
    }
}

/// The UIKit background assertion is finite. Its expiration callback must stop the
/// active transfer immediately; merely ending the assertion while a BLE write keeps
/// running makes iOS terminate the process in the middle of a transaction.
@MainActor
protocol BackgroundTransferApplication: AnyObject {
    var isIdleTimerDisabled: Bool { get set }
    func beginBackgroundTask(
        withName name: String?,
        expirationHandler: (() -> Void)?
    ) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
}

extension UIApplication: BackgroundTransferApplication {}

@MainActor
final class BackgroundTransferGuard {
    private static var activeAssertions = 0

    private let name: String
    private let application: any BackgroundTransferApplication
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var expirationHandler: (() -> Void)?
    private(set) var didExpire = false

    init(
        name: String,
        application: any BackgroundTransferApplication = UIApplication.shared
    ) {
        self.name = name
        self.application = application
    }

    var isActive: Bool { identifier != .invalid }

    func begin(onExpiration: @escaping () -> Void) {
        end()
        didExpire = false
        expirationHandler = onExpiration
        Self.activeAssertions += 1
        application.isIdleTimerDisabled = true
        identifier = application.beginBackgroundTask(withName: name) { [weak self] in
            self?.expire()
        }
        if identifier == .invalid {
            // UIKit can refuse an assertion (for example while the process is
            // already expiring). Treat that exactly like an immediate expiration so
            // the transfer receives its stop signal and the idle timer is restored.
            didExpire = true
            let callback = expirationHandler
            expirationHandler = nil
            Self.activeAssertions = max(0, Self.activeAssertions - 1)
            if Self.activeAssertions == 0 {
                application.isIdleTimerDisabled = false
            }
            callback?()
        }
    }

    func end() {
        guard identifier != .invalid else {
            expirationHandler = nil
            return
        }
        let current = identifier
        identifier = .invalid
        expirationHandler = nil
        application.endBackgroundTask(current)
        Self.activeAssertions = max(0, Self.activeAssertions - 1)
        if Self.activeAssertions == 0 {
            application.isIdleTimerDisabled = false
        }
    }

    private func expire() {
        guard identifier != .invalid, !didExpire else { return }
        didExpire = true
        let callback = expirationHandler
        // The callback is allowed to set a stop token, but the assertion is ended
        // regardless of whether the transfer has already unwound.
        callback?()
        end()
    }
}
