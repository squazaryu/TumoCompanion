import XCTest

final class DeviceServicesUITests: XCTestCase {
    func testLiveMapClusterShowsDetailedMembers() {
        let app = XCUIApplication()
        app.launchArguments = ["-wifi-live-map-cluster-qa"]
        app.launch()

        XCTAssertTrue(app.staticTexts["6 nearby estimates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TUMO LAB"].exists)
        XCTAssertTrue(app.staticTexts["Office 5G"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Live map detailed cluster"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testLiveMapSelectionCanBeCleared() {
        let app = XCUIApplication()
        app.launchArguments = ["-wifi-live-map-selection-qa"]
        app.launch()

        let clearSelection = app.buttons["Clear network selection"]
        XCTAssertTrue(clearSelection.waitForExistence(timeout: 5))

        let selected = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        selected.name = "Live map selected network"
        selected.lifetime = .keepAlways
        add(selected)

        let nextNetwork = app.buttons["Next network in cluster"]
        XCTAssertTrue(nextNetwork.waitForExistence(timeout: 2))
        nextNetwork.tap()
        XCTAssertTrue(app.staticTexts["Studio WiFi"].waitForExistence(timeout: 2))

        let switched = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        switched.name = "Live map switched cluster network"
        switched.lifetime = .keepAlways
        add(switched)

        clearSelection.tap()
        XCTAssertFalse(clearSelection.waitForExistence(timeout: 1))

        let cleared = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        cleared.name = "Live map cleared selection"
        cleared.lifetime = .keepAlways
        add(cleared)
    }

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

    func testFieldServicesRouteIsCompactAndOptIn() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingDone", "YES",
            "-fieldServices.rememberLocation.v1", "NO",
            "-fieldServices.journalEnabled.v1", "NO",
            "-fieldServices.webhookEnabled.v1", "NO",
        ]
        app.launch()

        let tile = app.buttons["Field Services"]
        for _ in 0..<6 where !tile.isHittable { app.swipeUp() }
        if !tile.exists {
            let tools = app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "TOOLS")
            ).firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 3))
            tools.tap()
        }
        for _ in 0..<4 where !tile.isHittable { app.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 3))
        tile.tap()

        XCTAssertTrue(app.navigationBars["Field Services"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.switches["field-services-remember-location"].value as? String, "0")
        for _ in 0..<5 where !app.switches["field-services-journal"].isHittable {
            app.swipeUp()
        }
        XCTAssertEqual(app.switches["field-services-journal"].value as? String, "0")
        XCTAssertTrue(app.staticTexts["Weather"].exists)
        XCTAssertTrue(app.staticTexts["Place"].exists)
        XCTAssertTrue(app.staticTexts["Release"].exists)

        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Field Services opt-in route"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
