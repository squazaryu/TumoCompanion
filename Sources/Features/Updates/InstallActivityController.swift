import Foundation
import ActivityKit
import UnleashedShared
import os

private let activityLog = Logger(
    subsystem: "com.tumoflip.unleashedcompanion",
    category: "live-activity"
)

/// Drives the install Live Activity (Lock Screen + Dynamic Island). Every
/// ActivityKit operation is queued so a slow update can never overtake the
/// terminal state.
@MainActor
final class InstallActivityController {
    private var activity: Activity<InstallActivityAttributes>?
    private var pendingOperation: Task<Void, Never>?
    private static let staleInterval: TimeInterval = 90
    private static let dismissalDelay: TimeInterval = 8

    /// A relaunched app cannot resume an interrupted local install, so an Activity
    /// left by the previous process must not keep advertising stale progress.
    static func dismissOrphanedActivities() async {
        for orphan in Activity<InstallActivityAttributes>.activities {
            await orphan.end(nil, dismissalPolicy: .immediate)
        }
    }

    func start(total: Int, title: String = "Installing plugins") {
        enqueue { [weak self] in
            guard let self else { return }
            await Self.dismissOrphanedActivities()
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let state = InstallActivityAttributes.ContentState(
                current: 0,
                total: total,
                detail: "Starting…",
                phase: .running
            )
            do {
                self.activity = try Activity.request(
                    attributes: InstallActivityAttributes(title: title),
                    content: Self.content(state)
                )
            } catch {
                activityLog.error(
                    "Live Activity request failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func update(current: Int, total: Int, detail: String) {
        enqueue { [weak self] in
            guard let activity = self?.activity else { return }
            let state = InstallActivityAttributes.ContentState(
                current: current,
                total: total,
                detail: Self.shortDetail(detail),
                phase: .running
            )
            await activity.update(Self.content(state))
        }
    }

    func succeed(completed: Int, total: Int, detail: String = "Completed") {
        end(completed: completed, total: total, detail: detail, phase: .succeeded)
    }

    func completeWithIssues(completed: Int, total: Int, detail: String) {
        end(
            completed: completed,
            total: total,
            detail: detail,
            phase: .completedWithIssues
        )
    }

    func fail(completed: Int, total: Int, detail: String) {
        end(completed: completed, total: total, detail: detail, phase: .failed)
    }

    func stop(completed: Int, total: Int, detail: String = "Stopped") {
        end(completed: completed, total: total, detail: detail, phase: .stopped)
    }

    private func end(
        completed: Int,
        total: Int,
        detail: String,
        phase: InstallActivityAttributes.ContentState.Phase
    ) {
        enqueue { [weak self] in
            guard let self, let activity = self.activity else { return }
            let state = InstallActivityAttributes.ContentState(
                current: completed,
                total: total,
                detail: Self.shortDetail(detail),
                phase: phase
            )
            await activity.end(
                ActivityContent(state: state, staleDate: nil, relevanceScore: 0),
                dismissalPolicy: .after(Date().addingTimeInterval(Self.dismissalDelay))
            )
            self.activity = nil
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pendingOperation
        pendingOperation = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    private static func content(
        _ state: InstallActivityAttributes.ContentState
    ) -> ActivityContent<InstallActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleInterval),
            relevanceScore: 1
        )
    }

    private static func shortDetail(_ detail: String) -> String {
        let filename = (detail as NSString).lastPathComponent
        let display = filename.isEmpty ? detail : filename
        return String(display.prefix(120))
    }
}
