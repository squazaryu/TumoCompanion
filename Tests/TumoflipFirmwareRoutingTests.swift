import XCTest
@testable import UnleashedCompanion

final class TumoflipFirmwareRoutingTests: XCTestCase {
    func testDevTumoflipVersionRoutesToDev() {
        let identity = makeIdentity(version: "t-dev-089-035-001", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .dev)
        XCTAssertEqual(route.detectedChannel, .dev)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testStableTumoflipVersionRoutesToStable() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testStandaloneStableTumoflipVersionRoutesToStable() {
        let identity = makeIdentity(version: "t-flppr-fw-001", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testLegacyStableTumoflipVersionStillRoutesToStable() {
        let identity = makeIdentity(version: "tmwhflpprarf089-034", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testMalformedNewStableVersionFallsBackWithWarning() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037-001", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .unknownTumoflipVersion("t-flppr-fw-089-037-001"))
    }

    func testUnknownTumoflipVersionFallsBackToStableWithWarning() {
        let identity = makeIdentity(version: "tumoflip-local-build", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .unknownTumoflipVersion("tumoflip-local-build"))
    }

    func testNonTumoflipFirmwareFallsBackToStableWithWarning() {
        let identity = makeIdentity(version: "unlshd-089", origin: "unleashed")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .nonTumoflip(origin: "unleashed"))
    }

    func testMissingIdentityFallsBackToStableWithWarning() {
        let route = TumoflipFirmwareRouter.route(identity: nil, manualOverride: nil)

        XCTAssertEqual(route.channel, .stable)
        XCTAssertNil(route.detectedChannel)
        XCTAssertEqual(route.warning, .identityUnavailable)
    }

    func testManualOverrideIsExplicitAndWarned() {
        let identity = makeIdentity(version: "t-flppr-fw-089-037", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: .dev)

        XCTAssertEqual(route.channel, .dev)
        XCTAssertEqual(route.detectedChannel, .stable)
        XCTAssertEqual(route.warning, .manualOverride(selected: .dev, detected: .stable))
        XCTAssertTrue(route.isManualOverride)
    }

    func testManualSelectionMatchingDetectedChannelIsNotWarnedAsOverride() {
        let identity = makeIdentity(version: "t-dev-004-015", origin: "tumoflip")
        let route = TumoflipFirmwareRouter.route(identity: identity, manualOverride: .dev)

        XCTAssertEqual(route.channel, .dev)
        XCTAssertEqual(route.detectedChannel, .dev)
        XCTAssertNil(route.warning)
        XCTAssertFalse(route.isManualOverride)
    }

    func testDeviceInfoParsingKeepsUsefulDiagnostics() {
        let identity = TumoflipDeviceIdentity(deviceInfo: [
            ("firmware_version", "t-dev-089-035-001"),
            ("firmware_origin_fork", "tumoflip"),
            ("firmware_commit", "abc123"),
            ("firmware_commit_dirty", "true"),
            ("firmware_api_major", "87"),
            ("firmware_api_minor", "16"),
            ("hardware_target", "7"),
        ])

        XCTAssertEqual(identity.inferredChannel, .dev)
        XCTAssertEqual(identity.firmwareAPI, "87.16")
        XCTAssertEqual(identity.hardwareTarget, 7)
        XCTAssertEqual(identity.firmwareCommit, "abc123")
        XCTAssertEqual(identity.firmwareCommitDirty, true)
        XCTAssertEqual(
            identity.compatibilityIdentity,
            TumoflipCompatibilityIdentity(apiMajor: 87, hardwareTarget: 7)
        )
    }

    func testIncompleteDeviceInfoDoesNotCreateCompatibilityIdentity() {
        let missingAPI = TumoflipDeviceIdentity(deviceInfo: [
            ("firmware_version", "t-dev-004-013"),
            ("firmware_origin_fork", "tumoflip"),
            ("hardware_target", "7"),
        ])
        let missingTarget = TumoflipDeviceIdentity(deviceInfo: [
            ("firmware_version", "t-dev-004-013"),
            ("firmware_origin_fork", "tumoflip"),
            ("firmware_api_major", "88"),
            ("firmware_api_minor", "0"),
        ])

        XCTAssertNil(missingAPI.compatibilityIdentity)
        XCTAssertNil(missingTarget.compatibilityIdentity)
    }

    func testConnectedIdentityNoticeIsNonBlocking() {
        let notice = FWPackagesIdentityNotice.verificationPending

        XCTAssertFalse(notice.isBlocking)
        XCTAssertEqual(notice.systemImage, "checkmark.shield")
        XCTAssertEqual(
            notice.text,
            "Connected. Firmware compatibility will be verified before installation."
        )
    }

    func testDisconnectedIdentityNoticeRequiresConnection() {
        let notice = FWPackagesIdentityNotice.connectionRequired(.ble)

        XCTAssertTrue(notice.isBlocking)
        XCTAssertEqual(notice.systemImage, "antenna.radiowaves.left.and.right.slash")
        XCTAssertEqual(
            notice.text,
            "Connect Flipper over BLE to validate apps before installing via BLE."
        )
    }

    func testLegacyPackageReleaseMatcherRequiresExactInstalledDevVersion() {
        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-058",
            channel: .dev,
            installedVersion: "t-dev-089-037-058"
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-012",
            channel: .dev,
            installedVersion: "t-dev-089-037-058"
        ))
    }

    func testIndependentPackageCatalogMatchesChannelWithoutExactFirmwareVersion() {
        let release = TumoflipManifest.PackageRelease(
            id: "fw-packages-dev-001",
            type: "package-only",
            sourceCommit: String(repeating: "a", count: 40),
            sourceDirty: false,
            sourceFirmwareVersion: "t-dev-004-014",
            targetReleaseTag: "t-dev-004-014",
            firmwareFlashUnchanged: true,
            catalogChannel: "dev",
            catalogRevision: 1,
            catalogReleaseTag: "fw-packages-dev-001"
        )

        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-004-014",
            packageRelease: release,
            channel: .dev,
            installedVersion: "t-dev-004-013"
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-004-014",
            packageRelease: release,
            channel: .stable,
            installedVersion: "t-flppr-fw-004"
        ))
    }

    func testIndependentStableCatalogMatchesAnotherStableFirmwareVersion() {
        let release = TumoflipManifest.PackageRelease(
            id: "fw-packages-stable-001",
            type: "package-only",
            sourceCommit: String(repeating: "b", count: 40),
            sourceDirty: false,
            sourceFirmwareVersion: "t-flppr-fw-004",
            targetReleaseTag: "v1.0.4",
            firmwareFlashUnchanged: true,
            catalogChannel: "stable",
            catalogRevision: 1,
            catalogReleaseTag: "fw-packages-stable-001"
        )

        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-flppr-fw-004",
            packageRelease: release,
            channel: .stable,
            installedVersion: "t-flppr-fw-005"
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-flppr-fw-004",
            packageRelease: release,
            channel: .dev,
            installedVersion: "t-dev-005-001"
        ))
    }

    func testIndependentCatalogReplacesLaterCreatedFirmwareManifest() {
        let catalog = packageRelease(channel: "dev", revision: 4)

        XCTAssertTrue(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: nil,
            with: catalog
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: catalog,
            with: nil
        ))
    }

    func testHighestIndependentCatalogRevisionWinsRegardlessOfAPIOrder() {
        let revisionThree = packageRelease(channel: "dev", revision: 3)
        let revisionFour = packageRelease(channel: "dev", revision: 4)

        XCTAssertTrue(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: revisionThree,
            with: revisionFour
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: revisionFour,
            with: revisionThree
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: revisionFour,
            with: revisionFour
        ))
    }

    func testLegacyPackageOrderRemainsStableWithoutIndependentCatalog() {
        XCTAssertFalse(TumoflipPackageReleaseMatcher.shouldReplaceSelection(
            current: nil,
            with: nil
        ))
    }

    func testPackageReleaseMatcherStillFiltersChannelWithoutIdentity() {
        XCTAssertTrue(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-dev-089-037-058",
            channel: .dev,
            installedVersion: nil
        ))
        XCTAssertFalse(TumoflipPackageReleaseMatcher.matches(
            manifestVersion: "t-flppr-fw-089-037",
            channel: .dev,
            installedVersion: nil
        ))
    }

    private func makeIdentity(version: String, origin: String) -> TumoflipDeviceIdentity {
        TumoflipDeviceIdentity(
            firmwareVersion: version,
            originFork: origin,
            firmwareCommit: nil,
            firmwareCommitDirty: nil,
            firmwareAPI: "87.16",
            hardwareTarget: 7
        )
    }

    private func packageRelease(
        channel: String,
        revision: Int
    ) -> TumoflipManifest.PackageRelease {
        TumoflipManifest.PackageRelease(
            id: String(format: "fw-packages-%@-%03d", channel, revision),
            type: "package-only",
            sourceCommit: String(repeating: "c", count: 40),
            sourceDirty: false,
            sourceFirmwareVersion: "t-dev-004-015",
            targetReleaseTag: "t-dev-004-015",
            firmwareFlashUnchanged: true,
            catalogChannel: channel,
            catalogRevision: revision,
            catalogReleaseTag: String(format: "fw-packages-%@-%03d", channel, revision)
        )
    }
}
