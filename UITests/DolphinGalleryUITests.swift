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

        let minuteWheel = app.pickerWheels.element(boundBy: 1)
        XCTAssertTrue(minuteWheel.waitForExistence(timeout: 5))
        minuteWheel.adjust(toPickerWheelValue: "02")
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

    func testActionsFillBottomBarAndTransactionsReplaceThemWithProgress() throws {
        let channel = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "PACKAGE CHANNEL")
        ).firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.staticTexts["Installed"].exists,
            "Package channel must start collapsed"
        )
        channel.tap()
        XCTAssertTrue(
            app.staticTexts["Installed"].waitForExistence(timeout: 2),
            "Package channel metadata must remain available after expansion"
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
        channel.tap()

        let groupsDrawer = app.buttons["fw-packages-groups-drawer-toggle"]
        XCTAssertTrue(
            groupsDrawer.waitForExistence(timeout: 2),
            "Package groups should be available from the compact drawer"
        )
        groupsDrawer.tap()

        for group in ["base", "arf", "module_one", "protocol_packs"] {
            XCTAssertTrue(
                app.buttons["fw-packages-expand-\(group)"].waitForExistence(timeout: 2),
                "Every production package category must remain visible and expandable"
            )
        }
        XCTAssertEqual(
            app.staticTexts["fw-packages-status-base"].label,
            "Up to date"
        )
        XCTAssertEqual(
            app.staticTexts["fw-packages-status-module_one"].label,
            "1 of 3 need updates"
        )
        XCTAssertEqual(
            app.staticTexts["fw-packages-cleanup-status-module_one"].label,
            "1 Cleanup required"
        )
        XCTAssertTrue(
            app.switches[
                "fw-packages-file-module_one-tumoflip_xremote.fap"
            ].waitForExistence(timeout: 2),
            "Expanded categories must retain their per-file selection toggles"
        )

        let install = app.buttons["fw-packages-install-action"]
        let cleanup = app.buttons["fw-packages-cleanup-action"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        XCTAssertTrue(cleanup.exists)
        let splitInstallWidth = install.frame.width

        selectScenario("Install only")
        XCTAssertTrue(install.waitForExistence(timeout: 2))
        XCTAssertFalse(cleanup.exists)
        XCTAssertGreaterThan(
            install.frame.width,
            splitInstallWidth * 1.7,
            "A single action should fill the pinned bar"
        )

        selectScenario("Cleanup only")
        XCTAssertFalse(install.exists)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 2))

        selectScenario("Cleaning")
        XCTAssertFalse(install.exists)
        XCTAssertFalse(cleanup.exists)
        XCTAssertTrue(app.progressIndicators["fw-packages-progress"].waitForExistence(timeout: 2))
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
        drawer.tap()
        XCTAssertTrue(app.staticTexts["Archived source"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["v1.14.1"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "Download again")
            ).firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["Creates a new active package. The archived copy stays unchanged."].exists)
        XCTAssertFalse(app.staticTexts["No Marauder flash folders found under esp_flasher."].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "ESP32 archived package redownload"
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
