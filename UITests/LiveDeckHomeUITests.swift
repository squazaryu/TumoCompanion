import XCTest

final class LiveDeckHomeUITests: XCTestCase {
    func testHomeShowsIndependentLiveDeckSurfaces() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["SOURCES"].exists)
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
        XCTAssertTrue(app.buttons["Open ESP32"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["3 available"].exists)
        XCTAssertTrue(app.buttons["Open Remotes"].exists)
        XCTAssertFalse(app.staticTexts["CURRENT ACTIVITY"].exists)
        XCTAssertFalse(app.staticTexts["Tap screen to open remote"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home - tools open"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testConnectedConsoleUsesCompactStatusRail() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-live-deck-connected-qa"]
        app.launch()

        XCTAssertTrue(app.staticTexts["FLIPPER CONSOLE"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Flipper TUMOFLIP"].exists)
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["Bridge v2"].exists)
        XCTAssertFalse(app.staticTexts["Connected & ready"].exists)
        XCTAssertFalse(app.staticTexts["Bridge v1"].exists)
        XCTAssertFalse(app.staticTexts["LIVE"].exists)
        XCTAssertFalse(app.staticTexts["BLE"].exists)

        let tools = app.buttons["Tools"]
        XCTAssertTrue(tools.exists)
        XCTAssertGreaterThan(tools.frame.minY, 0)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home - connected compact console"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
