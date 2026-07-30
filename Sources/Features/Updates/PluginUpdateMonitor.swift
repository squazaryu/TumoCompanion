import BackgroundTasks
import Foundation
import UserNotifications

struct UpdateReleaseSource: Equatable {
    let repo: String
    let lastTagKey: String
    let title: String
    let body: (String) -> String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repo == rhs.repo
            && lhs.lastTagKey == rhs.lastTagKey
            && lhs.title == rhs.title
    }
}

enum UpdateNotificationError: Error {
    case notificationsDisabled
}

/// Watches release tags in two complementary ways:
///
/// - an immediate, throttled check whenever the app becomes active;
/// - an opportunistic BGAppRefresh check when iOS grants background time.
///
/// BGAppRefresh's earliestBeginDate is not a delivery deadline, so the foreground
/// check removes the common one-day delay. Guaranteed server-time alerts would still
/// require a webhook + APNs backend.
enum PluginUpdateMonitor {
    static let taskID = "com.tumoflip.unleashedcompanion.plugincheck"
    static let foregroundCheckKey = "releaseMonitorLastForegroundCheck"
    static let foregroundCheckInterval: TimeInterval = 20 * 60

    static let sources: [UpdateReleaseSource] = [
        UpdateReleaseSource(
            repo: "xMasterX/all-the-plugins",
            lastTagKey: "pluginLastNotifiedTag",
            title: "New Flipper plugin pack",
            body: {
                "all-the-plugins \($0) is available — open Updates to install the changes."
            }
        ),
        UpdateReleaseSource(
            repo: "justcallmekoko/ESP32Marauder",
            lastTagKey: "esp32LastNotifiedTag",
            title: "New ESP32 Marauder firmware",
            body: {
                "ESP32Marauder \($0) is out — open Home → ESP32 Firmware to flash it."
            }
        ),
    ]

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func applicationDidBecomeActive() {
        enableIfNeeded()
        schedule()
        Task { await checkForegroundIfNeeded() }
    }

    static func enableIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                schedule()
                return
            }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                schedule()
            }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func checkForegroundIfNeeded(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async {
        let last = defaults.object(forKey: foregroundCheckKey) as? Date
        guard last.map({ now.timeIntervalSince($0) >= foregroundCheckInterval }) ?? true else {
            return
        }
        defaults.set(now, forKey: foregroundCheckKey)
        _ = await check()
    }

    @discardableResult
    static func check() async -> Bool {
        await check(
            defaults: .standard,
            sources: sources,
            latestTag: latestTag,
            deliver: deliver
        )
    }

    /// Injectable core used by unit tests. A changed tag is persisted only after the
    /// notification request is accepted, so a temporary notification failure cannot
    /// consume the release and postpone the alert until the next tag.
    @discardableResult
    static func check(
        defaults: UserDefaults,
        sources: [UpdateReleaseSource],
        latestTag: (String) async throws -> String,
        deliver: (UpdateReleaseSource, String) async throws -> Void
    ) async -> Bool {
        var allSucceeded = true
        for source in sources {
            do {
                let tag = try await latestTag(source.repo)
                let last = defaults.string(forKey: source.lastTagKey)
                if last == nil {
                    defaults.set(tag, forKey: source.lastTagKey)
                } else if tag != last {
                    try await deliver(source, tag)
                    defaults.set(tag, forKey: source.lastTagKey)
                }
            } catch {
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task {
            let success = await check()
            task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func latestTag(_ repo: String) async throws -> String {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 30
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              !tag.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return tag
    }

    private static func deliver(
        source: UpdateReleaseSource,
        tag: String
    ) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            throw UpdateNotificationError.notificationsDisabled
        }

        let content = UNMutableNotificationContent()
        content.title = source.title
        content.body = source.body(tag)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(source.repo)-\(tag)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

/// Shows immediately-detected release notifications while TumoCompanion is open.
final class UpdateNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotificationPresenter()

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
