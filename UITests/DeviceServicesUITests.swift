import XCTest

final class DeviceServicesUITests: XCTestCase {
    func testDeviceServicesAreVisibleAndOptIn() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-deviceServices.locationEnabled.v1", "NO",
            "-deviceServices.networkEnabled.v1", "NO",
        ]
        app.launch()

        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()

        let location = app.switches["device-services-location"]
        for _ in 0..<5 where !location.isHittable { app.swipeUp() }
        XCTAssertTrue(location.waitForExistence(timeout: 3))
        XCTAssertTrue(app.switches["device-services-network"].exists)
        XCTAssertEqual(location.value as? String, "0")
        XCTAssertEqual(app.switches["device-services-network"].value as? String, "0")

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Device services opt-in settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
