import XCTest

final class LiveDeckHomeUITests: XCTestCase {
    func testHomeShowsIndependentLiveDeckSurfaces() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["TUMO LIVE DECK"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["CURRENT ACTIVITY"].exists)
        XCTAssertTrue(app.staticTexts["SOURCES"].exists)
        XCTAssertTrue(app.staticTexts["QUICK LAUNCH"].exists)
        XCTAssertTrue(app.buttons["Tools"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live Deck home"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
