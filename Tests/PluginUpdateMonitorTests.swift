import XCTest
@testable import UnleashedCompanion

final class PluginUpdateMonitorTests: XCTestCase {
    func testChangedTagIsStoredOnlyAfterNotificationSucceeds() async throws {
        let suite = "PluginUpdateMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = UpdateReleaseSource(
            repo: "owner/repo",
            lastTagKey: "lastTag",
            title: "Title",
            body: { $0 }
        )
        defaults.set("v1", forKey: source.lastTagKey)

        let failed = await PluginUpdateMonitor.check(
            defaults: defaults,
            sources: [source],
            latestTag: { _ in "v2" },
            deliver: { _, _ in throw URLError(.cannotConnectToHost) }
        )
        XCTAssertFalse(failed)
        XCTAssertEqual(defaults.string(forKey: source.lastTagKey), "v1")

        let succeeded = await PluginUpdateMonitor.check(
            defaults: defaults,
            sources: [source],
            latestTag: { _ in "v2" },
            deliver: { _, _ in }
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(defaults.string(forKey: source.lastTagKey), "v2")
    }

    func testFirstTagCreatesSilentBaseline() async throws {
        let suite = "PluginUpdateMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = UpdateReleaseSource(
            repo: "owner/repo",
            lastTagKey: "lastTag",
            title: "Title",
            body: { $0 }
        )
        var deliveries = 0

        let succeeded = await PluginUpdateMonitor.check(
            defaults: defaults,
            sources: [source],
            latestTag: { _ in "v1" },
            deliver: { _, _ in deliveries += 1 }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(defaults.string(forKey: source.lastTagKey), "v1")
    }
}
