import ActivityKit
import Foundation
import UnleashedShared
import os

private let activityLog = Logger(
    subsystem: "com.tumoflip.unleashedcompanion",
    category: "live-activity"
)

/// Domain content passed to the ActivityKit adapter. Keeping ActivityKit out of
/// the controller makes the install lifecycle deterministic in unit tests.
struct InstallActivityPayload: Equatable {
    let state: InstallActivityAttributes.ContentState
    let staleDate: Date?
    let relevanceScore: Double
}

enum InstallActivityDismissal: Equatable {
    case immediate
    case after(TimeInterval)
}

/// A single immutable ActivityKit run. The controller captures this handle for
/// every queued operation, so an old run can never update a newer activity.
@MainActor
protocol InstallActivitySession: AnyObject {
    func update(payload: InstallActivityPayload) async
    func end(payload: InstallActivityPayload, dismissal: InstallActivityDismissal) async
}

/// The ActivityKit creation boundary. A fake client can provide isolated
/// sessions without creating a real Live Activity in XCTest.
@MainActor
protocol InstallActivityClient: AnyObject {
    func start(title: String, payload: InstallActivityPayload) -> (any InstallActivitySession)?
}

@MainActor
private final class ActivityKitInstallActivityClient: InstallActivityClient {
    func start(
        title: String,
        payload: InstallActivityPayload
    ) -> (any InstallActivitySession)? {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        do {
            let activity = try Activity.request(
                attributes: InstallActivityAttributes(title: title),
                content: ActivityKitInstallActivitySession.content(payload)
            )
            return ActivityKitInstallActivitySession(activity: activity)
        } catch {
            activityLog.error(
                "Live Activity request failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}

@MainActor
private final class ActivityKitInstallActivitySession: InstallActivitySession {
    private let activity: Activity<InstallActivityAttributes>
    private var ended = false

    init(activity: Activity<InstallActivityAttributes>) {
        self.activity = activity
    }

    func update(payload: InstallActivityPayload) async {
        guard !ended else { return }
        await activity.update(Self.content(payload))
    }

    func end(payload: InstallActivityPayload, dismissal: InstallActivityDismissal) async {
        guard !ended else { return }
        ended = true
        await activity.end(
            ActivityContent(
                state: payload.state,
                staleDate: payload.staleDate,
                relevanceScore: payload.relevanceScore
            ),
            dismissalPolicy: dismissalPolicy(dismissal)
        )
    }

    static func content(
        _ payload: InstallActivityPayload
    ) -> ActivityContent<InstallActivityAttributes.ContentState> {
        ActivityContent(
            state: payload.state,
            staleDate: payload.staleDate,
            relevanceScore: payload.relevanceScore
        )
    }

    private func dismissalPolicy(
        _ dismissal: InstallActivityDismissal
    ) -> ActivityUIDismissalPolicy {
        switch dismissal {
        case .immediate:
            .immediate
        case let .after(interval):
            .after(Date().addingTimeInterval(interval))
        }
    }
}

/// Drives the install Live Activity (Lock Screen + Dynamic Island).
///
/// Progress is coalesced to the latest state instead of creating an unbounded
/// FIFO of ActivityKit updates. Terminal calls are async so a local controller
/// cannot disappear before ActivityKit receives its final `end` operation.
@MainActor
final class InstallActivityController {
    private enum Lifecycle {
        case idle
        case running
        case ending
        case ended
    }

    private static let defaultStaleInterval: TimeInterval = 90
    private static let defaultProgressInterval: TimeInterval = 1
    private static let defaultHeartbeatInterval: TimeInterval = 30
    private static let defaultTerminalUpdateTimeout: TimeInterval = 2

    private let client: any InstallActivityClient
    private let staleInterval: TimeInterval
    private let progressInterval: TimeInterval
    private let heartbeatInterval: TimeInterval
    private let terminalUpdateTimeout: TimeInterval

    private var lifecycle: Lifecycle = .idle
    private var runID = UUID()
    private var session: (any InstallActivitySession)?
    private var latestState: InstallActivityAttributes.ContentState?
    private var pendingState: InstallActivityAttributes.ContentState?
    private var nextFlushDate = Date.distantPast
    private var flushTask: Task<Void, Never>?
    private var inFlightUpdate: Task<Void, Never>?
    private var inFlightUpdateID: UUID?
    private var heartbeatTask: Task<Void, Never>?

    init() {
        client = ActivityKitInstallActivityClient()
        staleInterval = Self.defaultStaleInterval
        progressInterval = Self.defaultProgressInterval
        heartbeatInterval = Self.defaultHeartbeatInterval
        terminalUpdateTimeout = Self.defaultTerminalUpdateTimeout
    }

    init(
        client: any InstallActivityClient,
        staleInterval: TimeInterval = 90,
        progressInterval: TimeInterval = 1,
        heartbeatInterval: TimeInterval = 30,
        terminalUpdateTimeout: TimeInterval = 2
    ) {
        self.client = client
        self.staleInterval = max(0, staleInterval)
        self.progressInterval = max(0, progressInterval)
        self.heartbeatInterval = max(0, heartbeatInterval)
        self.terminalUpdateTimeout = max(0, terminalUpdateTimeout)
    }

    /// A relaunched app cannot resume an interrupted local install, so an Activity
    /// left by the previous process must not keep advertising stale progress.
    /// This is intentionally called only during app launch, never when another
    /// install starts: parallel flows must not dismiss each other's activity.
    static func dismissOrphanedActivities() async {
        for orphan in Activity<InstallActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
    }

    func start(total: Int, title: String = "Installing plugins") {
        guard lifecycle == .idle || lifecycle == .ended else { return }

        lifecycle = .running
        runID = UUID()
        nextFlushDate = .distantPast
        let state = InstallActivityAttributes.ContentState(
            current: 0,
            total: total,
            detail: "Starting…",
            phase: .running
        )
        latestState = state
        session = client.start(title: title, payload: runningPayload(for: state))
        startHeartbeat(for: runID)
    }

    /// Records only the newest progress state. At most one ActivityKit update is
    /// active, and no more than one starts per `progressInterval`.
    func update(current: Int, total: Int, detail: String) {
        guard lifecycle == .running else { return }
        let state = InstallActivityAttributes.ContentState(
            current: current,
            total: total,
            detail: Self.shortDetail(detail),
            phase: .running
        )
        latestState = state
        pendingState = state
        scheduleFlushIfNeeded(for: runID)
    }

    func succeed(completed: Int, total: Int, detail: String = "Completed") async {
        await end(
            completed: completed,
            total: total,
            detail: detail,
            phase: .succeeded,
            dismissal: .immediate
        )
    }

    func completeWithIssues(completed: Int, total: Int, detail: String) async {
        await end(
            completed: completed,
            total: total,
            detail: detail,
            phase: .completedWithIssues,
            dismissal: .immediate
        )
    }

    func fail(completed: Int, total: Int, detail: String) async {
        await end(
            completed: completed,
            total: total,
            detail: detail,
            phase: .failed,
            dismissal: .immediate
        )
    }

    func stop(completed: Int, total: Int, detail: String = "Stopped") async {
        await end(
            completed: completed,
            total: total,
            detail: detail,
            phase: .stopped,
            dismissal: .immediate
        )
    }

    private func end(
        completed: Int,
        total: Int,
        detail: String,
        phase: InstallActivityAttributes.ContentState.Phase,
        dismissal: InstallActivityDismissal
    ) async {
        guard lifecycle == .running else { return }

        // Reject late callbacks before the first suspension. Old progress must never
        // overtake the terminal state, even while an ActivityKit update is in flight.
        lifecycle = .ending
        runID = UUID()
        pendingState = nil
        flushTask?.cancel()
        flushTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // ActivityKit updates normally finish quickly, but a single stalled update
        // must not retain the Live Activity forever. Cancel it, allow a bounded
        // cooperative settle, then let the terminal end take precedence.
        let updateID = inFlightUpdateID
        inFlightUpdate?.cancel()
        await waitForInFlightUpdateToSettle(id: updateID)
        inFlightUpdate = nil
        inFlightUpdateID = nil

        let state = InstallActivityAttributes.ContentState(
            current: completed,
            total: total,
            detail: Self.shortDetail(detail),
            phase: phase
        )
        let session = session
        self.session = nil
        await session?.end(
            payload: InstallActivityPayload(state: state, staleDate: nil, relevanceScore: 0),
            dismissal: dismissal
        )
        latestState = nil
        lifecycle = .ended
    }

    private func startHeartbeat(for runID: UUID) {
        guard heartbeatInterval > 0 else { return }
        heartbeatTask?.cancel()
        let delay = Self.nanoseconds(for: heartbeatInterval)
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.refreshStaleDate(for: runID)
            }
        }
    }

    /// Refreshes the stale date using the last known running state. The periodic
    /// heartbeat calls this while long BLE writes are otherwise quiet.
    func refreshStaleDate() {
        refreshStaleDate(for: runID)
    }

    private func refreshStaleDate(for runID: UUID) {
        guard lifecycle == .running, self.runID == runID, let latestState else { return }
        pendingState = latestState
        scheduleFlushIfNeeded(for: runID)
    }

    private func scheduleFlushIfNeeded(for runID: UUID) {
        guard lifecycle == .running,
              self.runID == runID,
              flushTask == nil,
              inFlightUpdate == nil,
              pendingState != nil else { return }

        let delay = max(0, nextFlushDate.timeIntervalSinceNow)
        flushTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            self?.flushPending(for: runID)
        }
    }

    private func flushPending(for runID: UUID) {
        flushTask = nil
        guard lifecycle == .running,
              self.runID == runID,
              let state = pendingState else { return }

        pendingState = nil
        nextFlushDate = Date().addingTimeInterval(progressInterval)
        let payload = runningPayload(for: state)
        guard let session else { return }
        let updateID = UUID()
        let update = Task { @MainActor in
            await session.update(payload: payload)
        }
        inFlightUpdate = update
        inFlightUpdateID = updateID
        Task { @MainActor [weak self] in
            await update.value
            self?.completeUpdate(id: updateID, runID: runID)
        }
    }

    private func completeUpdate(id: UUID, runID: UUID) {
        guard inFlightUpdateID == id else { return }
        inFlightUpdate = nil
        inFlightUpdateID = nil
        guard lifecycle == .running, self.runID == runID else { return }
        scheduleFlushIfNeeded(for: runID)
    }

    private func waitForInFlightUpdateToSettle(id: UUID?) async {
        guard let id, terminalUpdateTimeout > 0 else { return }
        let deadline = Date().addingTimeInterval(terminalUpdateTimeout)
        while inFlightUpdateID == id, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return
            }
        }
    }

    private func runningPayload(
        for state: InstallActivityAttributes.ContentState
    ) -> InstallActivityPayload {
        InstallActivityPayload(
            state: state,
            staleDate: Date().addingTimeInterval(staleInterval),
            relevanceScore: 1
        )
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }

    private static func shortDetail(_ detail: String) -> String {
        let filename = (detail as NSString).lastPathComponent
        let display = filename.isEmpty ? detail : filename
        return String(display.prefix(120))
    }
}
