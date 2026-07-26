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

        app.navigationBars["Dolphin Gallery"].buttons["Settings"].tap()
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
        channel.tap()

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
