import XCTest

final class LiveDeckHomeUITests: XCTestCase {
    func testHomeSourceListRendersInDarkMode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", "dark",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["updates-source-esp32"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Tools"].exists)
        XCTAssertFalse(app.buttons["Open ESP32"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home - dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeShowsIndependentLiveDeckSurfaces() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", "light"]
        app.launch()

        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SOURCES"].exists)
        XCTAssertTrue(app.buttons["updates-open-center"].exists)
        XCTAssertTrue(app.buttons["updates-source-firmware"].exists)
        XCTAssertTrue(app.buttons["updates-source-packages"].exists)
        XCTAssertTrue(app.buttons["updates-source-community"].exists)
        XCTAssertTrue(app.buttons["updates-source-esp32"].exists)
        XCTAssertTrue(app.buttons["Info"].exists)
        XCTAssertTrue(app.buttons["Open Files"].exists)
        XCTAssertTrue(app.buttons["Open Apps"].exists)
        XCTAssertTrue(app.buttons["Open Backup"].exists)
        XCTAssertFalse(app.buttons["Open Remotes"].exists)
        XCTAssertTrue(app.buttons["Open Field Services"].exists)
        XCTAssertTrue(app.staticTexts["QUICK ACCESS"].exists)
        XCTAssertFalse(app.staticTexts["6/6"].exists)
        XCTAssertTrue(app.buttons["Tools"].exists)

        let closedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closedScreenshot.name = "Live Deck home - closed"
        closedScreenshot.lifetime = .keepAlways
        add(closedScreenshot)

        app.buttons["Tools"].tap()
        XCTAssertFalse(app.buttons["Open ESP32"].exists)
        XCTAssertTrue(app.staticTexts["2 available"].exists)
        XCTAssertTrue(app.buttons["Open Remotes"].exists)
        XCTAssertFalse(app.staticTexts["CURRENT ACTIVITY"].exists)
        XCTAssertFalse(app.staticTexts["Tap screen to open remote"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home - tools open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSourceRowsRouteToDedicatedUpdateScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", "light"]

        app.launch()
        XCTAssertTrue(app.buttons["updates-source-firmware"].waitForExistence(timeout: 5))
        app.buttons["updates-source-firmware"].tap()
        XCTAssertTrue(app.navigationBars["Firmware"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["updates-source-packages"].waitForExistence(timeout: 5))
        app.buttons["updates-source-packages"].tap()
        XCTAssertTrue(app.navigationBars["Firmware packages"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["updates-source-community"].waitForExistence(timeout: 5))
        app.buttons["updates-source-community"].tap()
        XCTAssertTrue(app.navigationBars["Community apps"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["updates-source-esp32"].waitForExistence(timeout: 5))
        app.buttons["updates-source-esp32"].tap()
        XCTAssertTrue(app.navigationBars["ESP32 Firmware"].waitForExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["updates-open-center"].waitForExistence(timeout: 5))
        app.buttons["updates-open-center"].tap()
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 3))
    }

    func testConnectedConsoleUsesCompactStatusRail() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", "light",
            "-live-deck-connected-qa",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Flipper TUMOFLIP"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["BLE"].exists)
        XCTAssertTrue(app.staticTexts["Bridge v2"].exists)
        XCTAssertFalse(app.buttons["Ready"].exists)
        XCTAssertFalse(app.staticTexts["Connected & ready"].exists)
        XCTAssertFalse(app.staticTexts["Bridge v1"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)

        let tools = app.buttons["Tools"]
        XCTAssertTrue(tools.exists)
        XCTAssertGreaterThan(tools.frame.minY, 0)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home - connected compact console"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeKeepsNavigationChromeStableAfterSmallScroll() {
        assertNavigationChromeStaysStable(
            appearance: "light",
            screenshotPrefix: "Live Deck home - light navigation"
        )
    }

    func testHomeKeepsNavigationChromeStableAfterSmallScrollInDarkMode() {
        assertNavigationChromeStaysStable(
            appearance: "dark",
            screenshotPrefix: "Live Deck home - dark navigation"
        )
    }

    private func assertNavigationChromeStaysStable(
        appearance: String,
        screenshotPrefix: String
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-appearanceMode", appearance,
            "-live-deck-connected-qa",
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].exists)

        let initialScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        initialScreenshot.name = "\(screenshotPrefix) - initial"
        initialScreenshot.lifetime = .keepAlways
        add(initialScreenshot)

        let screen = app.windows.firstMatch
        let start = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.58))
        let end = screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(app.navigationBars["Home"].exists)
        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "\(screenshotPrefix) - lightly scrolled"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testHomeLayoutSettingsMatchCurrentDashboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", "light"]
        app.launch()

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let homeLayout = app.buttons["settings-home-dashboard"]
        XCTAssertTrue(homeLayout.waitForExistence(timeout: 5))
        homeLayout.tap()

        XCTAssertTrue(app.staticTexts["Flipper Console"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Quick Access"].exists)
        XCTAssertFalse(app.staticTexts["Revision"].exists)
        XCTAssertFalse(app.staticTexts["Tools Quick Access"].exists)

        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Drawer"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Add ESP32"].exists)
        XCTAssertFalse(app.staticTexts["Add (tool.title)"].exists)
        XCTAssertTrue(app.staticTexts["More Tools"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Home layout current settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testBuildVersionLivesInAboutInsteadOfHome() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", "light"]
        app.launch()

        XCTAssertFalse(app.staticTexts["Ready for field work"].exists)
        XCTAssertFalse(app.staticTexts["about-app-version"].exists)

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let about = app.buttons["settings-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        about.tap()

        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertTrue(app.staticTexts["about-app-version"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "About with app version"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
