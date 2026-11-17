import XCTest
@testable import UnleashedCompanion

@MainActor
final class TransferBackgroundTests: XCTestCase {
    private func recoveryDefaults() throws -> (UserDefaults, String) {
        let name = "transfer-recovery-isolation-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testRecoveryKindsAndStorePrefixesDoNotOverwriteEachOther() throws {
        let (defaults, name) = try recoveryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = TransferRecoveryStore(defaults: defaults, key: "first")
        let second = TransferRecoveryStore(defaults: defaults, key: "second")
        let firmware = TransferRecoveryCheckpoint(kind: .firmware, completed: 1, total: 3, detail: "firmware")
        let packages = TransferRecoveryCheckpoint(kind: .packages, completed: 2, total: 4, detail: "packages")
        XCTAssertTrue(first.save(firmware))
        XCTAssertTrue(first.save(packages))
        XCTAssertEqual(first.load(kind: .firmware), firmware)
        XCTAssertEqual(first.load(kind: .packages), packages)
        XCTAssertEqual(Set(first.loadAll().map { $0.kind.rawValue }), ["firmware", "packages"])
        XCTAssertTrue(second.loadAll().isEmpty)
        first.clear(kind: .firmware)
        XCTAssertNil(first.load(kind: .firmware))
        XCTAssertEqual(first.load(kind: .packages), packages)
    }

    func testKnownBrokenLegacyKeyIsReadOnlyForDefaultStoreAndMatchingKind() throws {
        let (defaults, name) = try recoveryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let checkpoint = TransferRecoveryCheckpoint(kind: .packages, completed: 1, total: 2, detail: "old")
        let broken = "(key).(kind.rawValue)"
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: broken)
        let standard = TransferRecoveryStore(defaults: defaults)
        let custom = TransferRecoveryStore(defaults: defaults, key: "other")
        XCTAssertEqual(standard.load(kind: .packages), checkpoint)
        XCTAssertNil(standard.load(kind: .firmware))
        XCTAssertTrue(custom.loadAll().isEmpty)
        standard.clear(kind: .firmware)
        XCTAssertNotNil(defaults.data(forKey: broken))
        standard.clear(kind: .packages)
        XCTAssertNil(defaults.data(forKey: broken))
    }

    func testScopedCheckpointRejectsWrongKindAndClearAllDropsOwnedLegacyKeys() throws {
        let (defaults, name) = try recoveryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let checkpoint = TransferRecoveryCheckpoint(kind: .packages, completed: 1, total: 2, detail: "old")
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: "checkpoint.firmware")
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: "checkpoint")
        let store = TransferRecoveryStore(defaults: defaults, key: "checkpoint")
        XCTAssertNil(store.load(kind: .firmware))
        XCTAssertEqual(store.load(kind: .packages), checkpoint)
        store.clear()
        XCTAssertTrue(store.loadAll().isEmpty)
        XCTAssertNil(defaults.data(forKey: "checkpoint"))
    }

    func testBackgroundAssertionBalancesBeginAndEnd() {
        let application = FakeBackgroundApplication()
        let guarder = BackgroundTransferGuard(
            name: "test-transfer",
            application: application
        )

        guarder.begin {}

        XCTAssertTrue(application.isIdleTimerDisabled)
        XCTAssertNotEqual(application.lastStarted, .invalid)

        guarder.end()

        XCTAssertFalse(application.isIdleTimerDisabled)
        XCTAssertEqual(application.ended, [application.lastStarted])
    }

    func testExpirationCallsHandlerAndEndsAssertion() {
        let application = FakeBackgroundApplication()
        let guarder = BackgroundTransferGuard(
            name: "test-transfer",
            application: application
        )
        var expired = false

        guarder.begin { expired = true }
        application.expire()

        XCTAssertTrue(expired)
        XCTAssertFalse(application.isIdleTimerDisabled)
        XCTAssertEqual(application.ended, [application.lastStarted])
        XCTAssertFalse(guarder.isActive)
    }

    func testExpirationIsIdempotent() {
        let application = FakeBackgroundApplication()
        let guarder = BackgroundTransferGuard(
            name: "test-transfer",
            application: application
        )
        var callbacks = 0

        guarder.begin { callbacks += 1 }
        application.expire()
        application.expire()

        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(application.ended.count, 1)
    }

    func testRecoveryCheckpointRoundTripsAndCanBeCleared() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "transfer-background-tests"))
        defaults.removePersistentDomain(forName: "transfer-background-tests")
        let store = TransferRecoveryStore(
            defaults: defaults,
            key: "checkpoint"
        )
        let checkpoint = TransferRecoveryCheckpoint(
            id: UUID(),
            kind: .packages,
            releaseID: "t-dev-008-022",
            completed: 2,
            total: 7,
            detail: "large.fap",
            state: .paused
        )

        XCTAssertTrue(store.save(checkpoint))
        XCTAssertEqual(store.load(), checkpoint)

        var running = checkpoint
        running.state = .running
        XCTAssertTrue(store.save(running))
        XCTAssertEqual(store.markInterruptedAsPaused()?.state, .paused)

        store.clear()
        XCTAssertNil(store.load())
    }
}

@MainActor
private final class FakeBackgroundApplication: BackgroundTransferApplication {
    var isIdleTimerDisabled = false
    var lastStarted: UIBackgroundTaskIdentifier = .invalid
    var ended: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (@MainActor @Sendable () -> Void)?

    func beginBackgroundTask(
        withName name: String?,
        expirationHandler: (@MainActor @Sendable () -> Void)?
    ) -> UIBackgroundTaskIdentifier {
        lastStarted = UIBackgroundTaskIdentifier(rawValue: 42)
        self.expirationHandler = expirationHandler
        return lastStarted
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        ended.append(identifier)
    }

    func expire() {
        expirationHandler?()
    }
}

@MainActor
final class BLEKeepAliveReconnectPolicyTests: XCTestCase {
    func testRetryRequiresKeepAliveAndTheExpectedPeripheral() {
        let expected = UUID()

        XCTAssertTrue(BLEReconnectPolicy.shouldRetry(
            keepAlive: true,
            userInitiatedDisconnect: false,
            centralPoweredOn: true,
            expectedPeripheralID: expected,
            failedPeripheralID: expected
        ))
        XCTAssertFalse(BLEReconnectPolicy.shouldRetry(
            keepAlive: false,
            userInitiatedDisconnect: false,
            centralPoweredOn: true,
            expectedPeripheralID: expected,
            failedPeripheralID: expected
        ))
        XCTAssertFalse(BLEReconnectPolicy.shouldRetry(
            keepAlive: true,
            userInitiatedDisconnect: true,
            centralPoweredOn: true,
            expectedPeripheralID: expected,
            failedPeripheralID: expected
        ))
        XCTAssertFalse(BLEReconnectPolicy.shouldRetry(
            keepAlive: true,
            userInitiatedDisconnect: false,
            centralPoweredOn: true,
            expectedPeripheralID: UUID(),
            failedPeripheralID: expected
        ))
        XCTAssertFalse(BLEReconnectPolicy.shouldRetry(
            keepAlive: true,
            userInitiatedDisconnect: false,
            centralPoweredOn: true,
            expectedPeripheralID: nil,
            failedPeripheralID: expected
        ))
        XCTAssertFalse(BLEReconnectPolicy.shouldRetry(
            keepAlive: true,
            userInitiatedDisconnect: false,
            centralPoweredOn: false,
            expectedPeripheralID: expected,
            failedPeripheralID: expected
        ))
    }

    func testRetryDelayStartsImmediatelyThenUsesCappedBackoff() {
        let expected: [(attempt: Int, delay: TimeInterval)] = [
            (1, 0), (2, 1), (3, 2), (4, 4), (5, 8), (6, 16), (7, 30), (20, 30),
        ]

        for item in expected {
            XCTAssertEqual(
                BLEReconnectPolicy.retryDelay(forFailureAttempt: item.attempt),
                item.delay,
                accuracy: 0.001,
                "unexpected delay for failure attempt \(item.attempt)"
            )
        }
    }
}
