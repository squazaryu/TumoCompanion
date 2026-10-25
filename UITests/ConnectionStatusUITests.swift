import XCTest

final class ConnectionStatusUITests: XCTestCase {
    func testCheckingDoesNotClaimLiveOrReady() {
        assertStatus("checking", title: "Checking", appearance: "light", lastFrame: true)
    }

    func testUnresponsiveHasRetryAndLastFrameInDarkMode() {
        assertStatus("unresponsive", title: "No response", appearance: "dark", lastFrame: true)
    }

    func testBusyTransferHasNonintrusiveStatus() {
        assertStatus("waiting", title: "In use", appearance: "light", lastFrame: true)
    }

    func testVerifiedConnectionInDarkMode() {
        assertStatus("ready", title: "Ready", appearance: "dark", lastFrame: false)
    }

    func testLargeTypeStatusFitsWithoutOverlappingActions() {
        assertStatus("unresponsive", title: "No response", appearance: "light", lastFrame: true,
                     largeType: true)
    }

    private func assertStatus(
        _ state: String, title: String, appearance: String, lastFrame: Bool,
        largeType: Bool = false
    ) {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", appearance,
                               "-connection-status-qa", state]
        if largeType { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"] }
        app.launch()
        let status = app.staticTexts["connection-status-title"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, title)
        let check = app.buttons["connection-check"]
        XCTAssertTrue(check.exists)
        XCTAssertGreaterThanOrEqual(check.frame.height, 44)
        XCTAssertTrue(app.staticTexts["Last frame"].exists == lastFrame)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Connection \(state) - \(appearance)\(largeType ? " - large type" : "")"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
