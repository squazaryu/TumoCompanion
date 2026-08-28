import XCTest

final class DolphinGalleryUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()
    }

    func testDurationPersistsAndLongPressOpensAnimatedPreview() throws {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let personalization = app.buttons["settings-personalization"]
        XCTAssertTrue(personalization.waitForExistence(timeout: 5))
        personalization.tap()

        let gallery = app.buttons["Dolphin Gallery"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        gallery.tap()

        let timing = app.segmentedControls["dolphin-timing-picker"]
        XCTAssertTrue(timing.waitForExistence(timeout: 5))
        timing.buttons["Custom"].tap()

        let duration = app.buttons["dolphin-duration-link"]
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        duration.tap()

        let hourWheel = app.pickerWheels.element(boundBy: 0)
        let minuteWheel = app.pickerWheels.element(boundBy: 1)
        let secondWheel = app.pickerWheels.element(boundBy: 2)
        XCTAssertTrue(hourWheel.waitForExistence(timeout: 5))
        XCTAssertTrue(minuteWheel.waitForExistence(timeout: 5))
        XCTAssertTrue(secondWheel.waitForExistence(timeout: 5))
        hourWheel.adjust(toPickerWheelValue: "00")
        minuteWheel.adjust(toPickerWheelValue: "02")
        secondWheel.adjust(toPickerWheelValue: "00")
        app.buttons["dolphin-duration-save"].tap()
        XCTAssertEqual(duration.label, "Duration, 00:02:00")

        app.navigationBars["Dolphin Gallery"].buttons["Personalization"].tap()
        app.buttons["Dolphin Gallery"].tap()
        let persistedDuration = app.buttons["dolphin-duration-link"]
        XCTAssertTrue(persistedDuration.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedDuration.label, "Duration, 00:02:00")

        let legacy = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Legacy'"))
            .firstMatch
        XCTAssertTrue(legacy.waitForExistence(timeout: 5))
        legacy.tap()

        let artwork = app.otherElements["dolphin-preview-L1_Tv_128x47"]
        for _ in 0..<4 where !artwork.isHittable { app.swipeUp() }
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        artwork.press(forDuration: 0.5)

        XCTAssertTrue(app.navigationBars["Animation preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)

        let firstFrame = XCUIScreen.main.screenshot().pngRepresentation
        Thread.sleep(forTimeInterval: 0.65)
        let secondFrame = XCUIScreen.main.screenshot().pngRepresentation
        XCTAssertNotEqual(firstFrame, secondFrame, "The full-screen preview must advance frames")
    }
}

final class FWPackagesActionBarUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-fw-packages-action-bar-qa",
        ]
        app.launch()
    }

    func testActionsStayCompactAndTransactionsShowOneProgressSurface() throws {
        let drawer = app.buttons["fw-packages-details-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.staticTexts["Installed"].exists,
            "Package details must start collapsed"
        )
        let collapsedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        collapsedScreenshot.name = "FW Packages compact overview"
        collapsedScreenshot.lifetime = .keepAlways
        add(collapsedScreenshot)
        drawer.tap()
        XCTAssertTrue(
            app.staticTexts["fw-packages-revision"].waitForExistence(timeout: 2),
            "The compact catalog identity must remain available in the bottom drawer"
        )
        XCTAssertEqual(
            app.staticTexts["fw-packages-compatible-firmware"].label,
            "v1.0.4 · t-flppr-fw-004"
        )
        XCTAssertTrue(
            app.staticTexts["fw-packages-revision"].label.contains("1b0eba79c"),
            "Package revision must be independent from the compatible firmware tag"
        )
        XCTAssertTrue(app.staticTexts["fw-packages-apps-only"].exists)

        let revisionScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        revisionScreenshot.name = "FW Packages compatibility and revision"
        revisionScreenshot.lifetime = .keepAlways
        add(revisionScreenshot)
        let groupsScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        groupsScreenshot.name = "FW Packages compact groups drawer"
        groupsScreenshot.lifetime = .keepAlways
        add(groupsScreenshot)

        for group in ["base", "arf", "module_one", "protocol_packs"] {
            XCTAssertTrue(
                app.buttons["fw-packages-expand-\(group)"].waitForExistence(timeout: 2),
                "Every production package category must remain visible and expandable"
            )
        }
        XCTAssertEqual(
            app.staticTexts["fw-packages-status-base"].label,
            "Current"
        )
        XCTAssertEqual(
            app.staticTexts["fw-packages-status-module_one"].label,
            "1 update · 1 cleanup"
        )

        app.buttons["fw-packages-expand-module_one"].tap()
        XCTAssertTrue(
            app.switches[
                "fw-packages-file-module_one-tumoflip_xremote.fap"
            ].waitForExistence(timeout: 2),
            "Expanded categories must retain their per-file selection toggles"
        )

        drawer.tap()

        let install = app.buttons["fw-packages-install-action"]
        let cleanup = app.buttons["fw-packages-cleanup-action"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        XCTAssertTrue(cleanup.exists)
        XCTAssertLessThanOrEqual(
            install.frame.height,
            52,
            "Install must remain a compact action, not a full-width bottom sheet button"
        )
        selectScenario("Install only")
        XCTAssertTrue(install.waitForExistence(timeout: 2))
        XCTAssertFalse(cleanup.exists)
        XCTAssertLessThan(
            install.frame.width,
            220,
            "A single action should remain an intrinsic compact capsule"
        )

        selectScenario("Cleanup only")
        XCTAssertFalse(install.exists)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 2))

        selectScenario("Cleaning")
        XCTAssertFalse(install.exists)
        XCTAssertFalse(cleanup.exists)
        XCTAssertTrue(app.progressIndicators["fw-packages-progress"].waitForExistence(timeout: 2))
        XCTAssertEqual(
            app.progressIndicators.matching(identifier: "fw-packages-progress").count,
            1,
            "A live transaction must not repeat the same progress above the stop action"
        )
        XCTAssertTrue(app.buttons["fw-packages-stop-action"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "FW Packages cleaning progress"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func selectScenario(_ title: String) {
        let menu = app.buttons["fw-packages-qa-scenario"]
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()
        let option = app.buttons[title]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.tap()
    }
}

final class CommunityRouteCleanupUITests: XCTestCase {
    func testCleanupReportSeparatesRemovedPackRoutesFromPreservedCustomFiles() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-community-route-cleanup-qa",
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["community-cleanup-action"].waitForExistence(timeout: 3),
            "cleanup-only must stay available when there are no app updates to reinstall"
        )
        XCTAssertTrue(app.buttons["community-cleanup-action"].label.contains("Clean Up 1"))

        let details = app.buttons["community-apps-details-drawer-toggle"]
        XCTAssertTrue(details.waitForExistence(timeout: 3))
        details.tap()
        XCTAssertTrue(app.staticTexts["community-cleanup-removed"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["community-cleanup-removed-paths"].label.contains(
                "/ext/apps/Games/4inrow.fap"
            )
        )
        XCTAssertTrue(app.staticTexts["community-cleanup-kept"].exists)
        XCTAssertTrue(
            app.staticTexts["community-cleanup-kept-paths"].label.contains(
                "/ext/apps/GPIO/custom_sensor.fap"
            )
        )
    }
}

final class ESP32ArchivedRedownloadUITests: XCTestCase {
    func testArchivedPackageKeepsRedownloadActionVisible() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-esp32-archived-redownload-qa",
        ]
        app.launch()

        let drawer = app.buttons["esp32-packages-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["esp32-board-summary-esp32c5devkitc1"].exists)
        XCTAssertTrue(app.buttons["esp32-board-summary-v6_1"].exists)
        let overviewScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overviewScreenshot.name = "ESP32 compact overview"
        overviewScreenshot.lifetime = .keepAlways
        add(overviewScreenshot)
        drawer.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Archived")
            ).firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["v1.14.1"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Download again")
            ).firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Archived copy stays unchanged")
            ).firstMatch.exists
        )
        XCTAssertFalse(app.staticTexts["No Marauder flash folders found under esp_flasher."].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ESP32 archived package redownload"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

final class UpdateSourceLayoutUITests: XCTestCase {
    private func launch(_ route: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", appearance,
            route,
        ]
        app.launch()
        return app
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testFirmwareOverviewAndDrawerRenderInDarkMode() {
        let app = launch("-firmware-library-layout-qa", appearance: "dark")
        let drawer = app.buttons["firmware-releases-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["RELEASE CATALOG"].exists)
        XCTAssertFalse(app.segmentedControls["firmware-channel-picker"].exists)
        attach("Firmware compact overview - dark")

        drawer.tap()
        XCTAssertTrue(app.segmentedControls["firmware-channel-picker"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Version 008"].exists)
        XCTAssertTrue(app.staticTexts["Version 007"].exists)
        XCTAssertTrue(app.staticTexts["Installed"].isHittable)
        attach("Firmware release drawer - dark")

        app.buttons["Prepare t-flppr-fw-008"].tap()
        XCTAssertTrue(app.alerts["Prepare t-flppr-fw-008?"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.segmentedControls["firmware-channel-picker"].exists)
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        attach("Firmware preparation confirmation - dark")
    }

    func testFirmwareOverviewAndDrawerRenderInLightMode() {
        let app = launch("-firmware-library-layout-qa", appearance: "light")
        let drawer = app.buttons["firmware-releases-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))
        attach("Firmware compact overview - light")
        drawer.tap()
        XCTAssertTrue(app.segmentedControls["firmware-channel-picker"].waitForExistence(timeout: 3))
        attach("Firmware release drawer - light")

        app.buttons["Prepare t-flppr-fw-008"].tap()
        XCTAssertTrue(app.alerts["Prepare t-flppr-fw-008?"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.segmentedControls["firmware-channel-picker"].exists)
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        attach("Firmware preparation confirmation - light")
    }

    func testFirmwareFailureReplacesDrawerInDarkMode() {
        let app = launch("-firmware-library-error-qa", appearance: "dark")
        XCTAssertTrue(app.staticTexts["Firmware transfer failed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertFalse(app.staticTexts["Error"].exists)
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        attach("Firmware transfer failure - dark")
    }

    func testFirmwareFailureReplacesDrawerInLightMode() {
        let app = launch("-firmware-library-error-qa", appearance: "light")
        XCTAssertTrue(app.staticTexts["Firmware transfer failed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry"].exists)
        XCTAssertFalse(app.staticTexts["Error"].exists)
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        attach("Firmware transfer failure - light")
    }

    func testFirmwarePreparingReplacesDrawerInDarkMode() {
        let app = launch("-firmware-library-preparing-qa", appearance: "dark")
        XCTAssertTrue(app.staticTexts["Preparing t-dev-008-003"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach("Firmware transfer preparing - dark")
    }

    func testFirmwarePreparingReplacesDrawerInLightMode() {
        let app = launch("-firmware-library-preparing-qa", appearance: "light")
        XCTAssertTrue(app.staticTexts["Preparing t-dev-008-003"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["firmware-releases-drawer-toggle"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach("Firmware transfer preparing - light")
    }

    func testCommunityOverviewAndDrawerRenderInDarkMode() {
        let app = launch("-community-apps-layout-qa", appearance: "dark")
        let drawer = app.buttons["community-apps-details-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["COMMUNITY CATALOG"].exists)
        XCTAssertTrue(app.buttons["community-install-action"].exists)
        attach("Community apps compact overview - dark")

        drawer.tap()
        XCTAssertTrue(app.buttons["community-release-picker-action"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["GPIO"].exists)
        XCTAssertTrue(app.staticTexts["Tools"].exists)
        XCTAssertTrue(app.staticTexts["Games"].exists)
        attach("Community app details drawer - dark")
    }

    func testCommunityOverviewAndDrawerRenderInLightMode() {
        let app = launch("-community-apps-layout-qa", appearance: "light")
        let drawer = app.buttons["community-apps-details-drawer-toggle"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 3))
        attach("Community apps compact overview - light")
        drawer.tap()
        XCTAssertTrue(app.buttons["community-release-picker-action"].waitForExistence(timeout: 3))
        attach("Community app details drawer - light")
    }
}

final class ESP32DeviceInventoryUITests: XCTestCase {
    func testStagedPackagesShow150AsUpdateInLightMode() {
        verifyStagedPackages(appearance: "light")
    }

    func testStagedPackagesShow150AsUpdateInDarkMode() {
        verifyStagedPackages(appearance: "dark")
    }

    func testDeviceReadFailureIsActionableInLightMode() {
        verifyReadFailure(appearance: "light")
    }

    func testDeviceReadFailureIsActionableInDarkMode() {
        verifyReadFailure(appearance: "dark")
    }

    private func verifyStagedPackages(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", appearance,
            "-esp32-staged-update-qa",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Update available: v1.15.1"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["esp32-board-summary-v6_1"].exists)
        XCTAssertTrue(app.staticTexts["v1.15.0"].exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "No Marauder flash folders")
        ).firstMatch.exists)
        attach("ESP32 staged 1.15.0 update - \(appearance)")
    }

    private func verifyReadFailure(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", appearance,
            "-esp32-device-scan-failure-qa",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["esp32-retry-device-scan"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Couldn't read Flipper packages")
        ).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Latest"].exists)
        attach("ESP32 device scan failure - \(appearance)")
    }

    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

final class ProtectedAppsAuditUITests: XCTestCase {
    func testAuditedDifferencesDoNotAppearAsDiff() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-protected-apps-audit-qa",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Verified"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-esp_flasher"].label,
            "VERIFIED")
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-claude_remote_ble"].label,
            "REPLACED")
        XCTAssertTrue(app.staticTexts["Needs review"].exists)
        XCTAssertTrue(app.staticTexts["Missing"].exists)
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-subghz_raw_edit"].label,
            "DIFF")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Protected apps centralized audit statuses"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testProtectedRowOpensSingleDetailSheet() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-protected-apps-audit-qa",
        ]
        app.launch()

        let row = app.buttons["protected-app-row-esp_flasher"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.navigationBars["esp_flasher"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Expected MD5"].exists)
        XCTAssertTrue(app.staticTexts["Install target"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    func testUnavailableAuditIsOneGlobalFailureAndRowsAreUnverified() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-protected-apps-audit-unavailable-qa",
        ]
        app.launch()

        let global = app.staticTexts["protected-app-audit-global-status"]
        XCTAssertTrue(global.waitForExistence(timeout: 3))
        XCTAssertEqual(global.label, "AUDIT UNAVAILABLE")
        XCTAssertTrue(app.staticTexts["Needs review"].exists)
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-esp_flasher"].label,
            "UNVERIFIED")
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-subghz_raw_edit"].label,
            "UNVERIFIED")
        XCTAssertFalse(app.staticTexts["DIFF"].exists)
        XCTAssertFalse(app.staticTexts["Verified"].exists)
    }

    func testMalformedAuditIsGlobalInvalidInsteadOfPerFileDiff() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-protected-apps-audit-invalid-qa",
        ]
        app.launch()

        let global = app.staticTexts["protected-app-audit-global-status"]
        XCTAssertTrue(global.waitForExistence(timeout: 3))
        XCTAssertEqual(global.label, "AUDIT INVALID")
        XCTAssertEqual(
            app.staticTexts["protected-app-review-status-esp_flasher"].label,
            "UNVERIFIED")
        XCTAssertFalse(app.staticTexts["DIFF"].exists)
    }
}

final class QualityPassUITests: XCTestCase {
    func testGitHubAccessCardShowsAnonymousAllowance() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        let developer = app.buttons["settings-developer"]
        XCTAssertTrue(developer.waitForExistence(timeout: 5))
        developer.tap()

        let signIn = app.buttons["github-auth-sign-in"]
        for _ in 0..<4 where !signIn.isHittable { app.swipeUp() }
        XCTAssertTrue(signIn.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Anonymous GitHub access"].exists)
        XCTAssertTrue(app.staticTexts["60 / hour"].exists)
        app.swipeUp()
        XCTAssertTrue(signIn.isHittable)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Settings GitHub anonymous access"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLongFirmwareVersionWrapsWithoutClipping() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-device-info-layout-qa",
        ]
        app.launch()

        let firmware = app.staticTexts[
            "TUMOFLIP t-dev-001-004 (f8bd0710df, 2026-07-29 23:58:41)"
        ]
        XCTAssertTrue(firmware.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(
            firmware.frame.height,
            app.staticTexts["Flipper Zero v12"].frame.height,
            "The complete firmware identity should wrap instead of being clipped"
        )

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Device info long firmware identity"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDiagnosticsStartsCollapsedAndEveryRowHasHelp() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        let developer = app.buttons["settings-developer"]
        XCTAssertTrue(developer.waitForExistence(timeout: 5))
        developer.tap()

        let diagnostics = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "DIAGNOSTICS")
        ).firstMatch
        for _ in 0..<4 where !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["App Bridge Console"].exists)

        diagnostics.tap()
        for title in [
            "App Bridge Console",
            "TumoVM NFC Smoke",
            "TumoCard NFC Smoke",
            "TumoFabric Counter",
        ] {
            XCTAssertTrue(app.buttons["About \(title)"].exists)
        }

        app.buttons["About App Bridge Console"].tap()
        XCTAssertTrue(app.navigationBars["App Bridge Console"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "manual App Bridge v2")
            ).firstMatch.exists
        )
    }
}
