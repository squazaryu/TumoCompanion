import XCTest
@testable import UnleashedCompanion

@MainActor
final class TransferBackgroundTests: XCTestCase {
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
