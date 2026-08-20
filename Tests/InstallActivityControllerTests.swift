import XCTest
@testable import UnleashedCompanion
import UnleashedShared

@MainActor
final class InstallActivityControllerTests: XCTestCase {
    func testBurstIsCoalescedAndTerminalDoesNotWaitForStalledUpdate() async {
        let client = RecordingActivityClient()
        client.blocksUpdates = true
        let firstUpdate = expectation(description: "first update starts")
        client.onUpdate = { firstUpdate.fulfill() }
        let controller = InstallActivityController(
            client: client,
            progressInterval: 60,
            heartbeatInterval: 0,
            terminalUpdateTimeout: 0
        )

        controller.start(total: 10_000, title: "Packages")
        controller.update(current: 1, total: 10_000, detail: "first.fap")
        await fulfillment(of: [firstUpdate], timeout: 1)

        for current in 2...10_000 {
            controller.update(current: current, total: 10_000, detail: "latest.fap")
        }
        let terminal = Task { @MainActor in
            await controller.succeed(completed: 10_000, total: 10_000)
        }
        await terminal.value

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(client.ends.count, 1)
        XCTAssertEqual(client.ends[0].payload.state.phase, .succeeded)
        XCTAssertEqual(client.ends[0].dismissal, .immediate)
        XCTAssertEqual(client.events.last, .end(client.ends[0]))
        client.resumeUpdate()
    }

    func testTerminalWaitsForAResponsiveInFlightUpdate() async {
        let client = RecordingActivityClient()
        client.blocksUpdates = true
        let firstUpdate = expectation(description: "first update starts")
        client.onUpdate = { firstUpdate.fulfill() }
        let controller = InstallActivityController(
            client: client,
            progressInterval: 0,
            heartbeatInterval: 0,
            terminalUpdateTimeout: 1
        )

        controller.start(total: 1)
        controller.update(current: 1, total: 1, detail: "one.fap")
        await fulfillment(of: [firstUpdate], timeout: 1)
        let terminal = Task { @MainActor in
            await controller.succeed(completed: 1, total: 1)
        }
        await Task.yield()

        XCTAssertTrue(client.ends.isEmpty)
        client.resumeUpdate()
        await terminal.value
        XCTAssertEqual(client.ends.count, 1)
    }

    func testStalledRunCannotUpdateAReplacementSession() async {
        let client = RecordingActivityClient()
        client.blocksUpdates = true
        let firstUpdate = expectation(description: "first run update starts")
        client.onUpdate = { firstUpdate.fulfill() }
        let controller = InstallActivityController(
            client: client,
            progressInterval: 0,
            heartbeatInterval: 0,
            terminalUpdateTimeout: 0
        )

        controller.start(total: 1)
        controller.update(current: 1, total: 1, detail: "old.fap")
        await fulfillment(of: [firstUpdate], timeout: 1)
        await controller.succeed(completed: 1, total: 1)

        controller.start(total: 1)
        XCTAssertEqual(client.sessions.count, 2)
        client.resumeUpdate(in: 0)
        await Task.yield()

        XCTAssertEqual(client.sessions[0].updateCount, 1)
        XCTAssertEqual(client.sessions[1].updateCount, 0)
        await controller.stop(completed: 0, total: 1)
    }

    func testTerminalIsIdempotentAndRejectsLateUpdates() async {
        let client = RecordingActivityClient()
        let firstUpdate = expectation(description: "first update starts")
        client.onUpdate = { firstUpdate.fulfill() }
        let controller = InstallActivityController(
            client: client,
            progressInterval: 0,
            heartbeatInterval: 0
        )

        controller.start(total: 2)
        controller.update(current: 1, total: 2, detail: "first.fap")
        await fulfillment(of: [firstUpdate], timeout: 1)
        await controller.fail(completed: 1, total: 2, detail: "Write failed")

        controller.update(current: 2, total: 2, detail: "late.fap")
        await controller.succeed(completed: 2, total: 2)
        await Task.yield()

        XCTAssertEqual(client.updates.count, 1)
        XCTAssertEqual(client.ends.count, 1)
        XCTAssertEqual(client.ends[0].payload.state.phase, .failed)
    }

    func testRefreshStaleDateUsesTheLastKnownRunningState() async {
        let client = RecordingActivityClient()
        let heartbeat = expectation(description: "stale-date refresh")
        client.onUpdate = { heartbeat.fulfill() }
        let controller = InstallActivityController(
            client: client,
            staleInterval: 90,
            progressInterval: 0,
            heartbeatInterval: 0
        )

        controller.start(total: 4)
        controller.refreshStaleDate()
        await fulfillment(of: [heartbeat], timeout: 1)
        await controller.stop(completed: 0, total: 4)

        XCTAssertEqual(client.updates.last?.state.phase, .running)
        XCTAssertNotNil(client.updates.last?.staleDate)
        XCTAssertEqual(client.ends.count, 1)
    }

    func testByteProgressReportsStartFinishAndBoundedCadence() {
        let clock = TestClock()
        var reports: [(Int, String)] = []
        let progress = TumoflipByteProgress(
            totalBytes: 100,
            completedUnits: 200,
            totalUnits: 400,
            name: "large.fap",
            report: { done, _, detail in reports.append((done, detail)) },
            minimumInterval: 1,
            now: { clock.now }
        )

        progress.update(0)
        progress.update(20)
        clock.advance(by: 0.9)
        progress.update(60)
        clock.advance(by: 0.2)
        progress.update(70)
        progress.update(100)

        XCTAssertEqual(reports.map(\.0), [200, 270, 300])
        XCTAssertEqual(
            reports.map(\.1),
            ["Uploading large.fap · 0%", "Uploading large.fap · 70%", "Uploading large.fap · 100%"]
        )
    }

}

@MainActor
private final class RecordingActivityClient: InstallActivityClient {
    struct End: Equatable {
        let payload: InstallActivityPayload
        let dismissal: InstallActivityDismissal
    }

    enum Event: Equatable {
        case start(String, InstallActivityPayload)
        case update(InstallActivityPayload)
        case end(End)
    }

    var events: [Event] = []
    var updates: [InstallActivityPayload] = []
    var ends: [End] = []
    var blocksUpdates = false
    var onUpdate: (() -> Void)?
    private(set) var sessions: [RecordingActivitySession] = []

    func start(
        title: String,
        payload: InstallActivityPayload
    ) -> (any InstallActivitySession)? {
        events.append(.start(title, payload))
        let session = RecordingActivitySession(client: self, blocksUpdates: blocksUpdates)
        sessions.append(session)
        return session
    }

    func resumeUpdate(in sessionIndex: Int = 0) {
        sessions[sessionIndex].resumeUpdate()
    }

    fileprivate func recordUpdate(_ payload: InstallActivityPayload) {
        updates.append(payload)
        events.append(.update(payload))
        onUpdate?()
    }

    fileprivate func recordEnd(
        payload: InstallActivityPayload,
        dismissal: InstallActivityDismissal
    ) {
        let end = End(payload: payload, dismissal: dismissal)
        ends.append(end)
        events.append(.end(end))
    }
}

@MainActor
private final class RecordingActivitySession: InstallActivitySession {
    private weak var client: RecordingActivityClient?
    private let blocksUpdates: Bool
    private var ended = false
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private(set) var updateCount = 0

    init(client: RecordingActivityClient, blocksUpdates: Bool) {
        self.client = client
        self.blocksUpdates = blocksUpdates
    }

    func update(payload: InstallActivityPayload) async {
        guard !ended else { return }
        updateCount += 1
        client?.recordUpdate(payload)
        guard blocksUpdates else { return }
        await withCheckedContinuation { continuation in
            updateContinuation = continuation
        }
    }

    func end(payload: InstallActivityPayload, dismissal: InstallActivityDismissal) async {
        guard !ended else { return }
        ended = true
        client?.recordEnd(payload: payload, dismissal: dismissal)
    }

    func resumeUpdate() {
        updateContinuation?.resume()
        updateContinuation = nil
    }
}

private final class TestClock {
    var now = Date(timeIntervalSinceReferenceDate: 0)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
