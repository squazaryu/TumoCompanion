import Foundation
import XCTest
@testable import UnleashedCompanion

final class ESP32FlashPackageMonitorTests: XCTestCase {
    func testLateManifestNotifiesKnownBoardOnceAndChangedRecipeRequiresReview() async throws {
        let suite = "ESP32FlashPackageMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var resolutions = 0
        var notifications = 0
        let resolve: (ESP32FlashPackageMonitor.Release, String) async throws -> String? = { _, board in
            resolutions += 1
            XCTAssertEqual(board, "v6_1")
            return "verified-plan"
        }
        let deliver: (ESP32FlashPackageMonitor.Release, String) async throws -> Void = { _, _ in
            notifications += 1
        }
        let manual = release(carrierID: nil)
        let baseline = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [manual], knownBoards: ["v6_1"],
            resolve: resolve, deliver: deliver)
        XCTAssertTrue(baseline)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(notifications, 0)

        let added = release(carrierID: 20)
        let available = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [added], knownBoards: ["v6_1"],
            resolve: resolve, deliver: deliver)
        XCTAssertTrue(available)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(notifications, 1)
        let unchanged = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [added], knownBoards: ["v6_1"],
            resolve: resolve, deliver: deliver)
        XCTAssertTrue(unchanged)
        XCTAssertEqual(notifications, 1)

        let changed = release(carrierID: 21)
        let reviewed = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [changed], knownBoards: ["v6_1"],
            resolve: resolve, deliver: deliver)
        XCTAssertTrue(reviewed)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(ESP32FlashPackageMonitor.requiresReview(
            releaseID: changed.id, boardKey: "v6_1", inventory: changed.inventory,
            defaults: defaults))
    }

    func testFirstSeenCarrierIsSilentAndOfflineDoesNotConsumeTransition() async throws {
        let suite = "ESP32FlashPackageMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notifications = 0
        let deliver: (ESP32FlashPackageMonitor.Release, String) async throws -> Void = { _, _ in
            notifications += 1
        }
        let first = release(carrierID: 20)
        let firstSeen = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [first], knownBoards: ["v6_1"],
            resolve: { _, _ in XCTFail("first sighting must not download"); return nil },
            deliver: deliver)
        XCTAssertTrue(firstSeen)
        XCTAssertEqual(notifications, 0)

        let manual = release(carrierID: nil)
        let manualSeen = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [manual], knownBoards: ["esp32c5devkitc1"],
            resolve: { _, _ in nil }, deliver: deliver)
        XCTAssertTrue(manualSeen)
        let added = release(carrierID: 22)
        let offline = await ESP32FlashPackageMonitor.reconcile(
            defaults: defaults, releases: [added], knownBoards: ["esp32c5devkitc1"],
            resolve: { _, _ in throw URLError(.notConnectedToInternet) }, deliver: deliver)
        XCTAssertFalse(offline)
        XCTAssertEqual(
            ESP32FlashPackageMonitor.observation(
                releaseID: added.id, boardKey: "esp32c5devkitc1", defaults: defaults)?.disposition,
            .manual)
    }

    private func release(carrierID: Int64?) -> ESP32FlashPackageMonitor.Release {
        let asset = carrierID.map {
            ESP32FlashPackageMonitor.Asset(
                id: $0, name: "marauder-installer-assets.zip", size: 128,
                digest: String(repeating: "a", count: 64),
                url: URL(string: "https://github.com/owner/repo/releases/download/v1/asset.zip"))
        }
        return ESP32FlashPackageMonitor.Release(
            id: 10, tag: "v1.17.0",
            assets: asset.map { ["marauder-installer-assets.zip": $0] } ?? [:])
    }
}
