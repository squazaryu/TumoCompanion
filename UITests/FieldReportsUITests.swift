import XCTest

final class FieldReportsUITests: XCTestCase {
    func testReportsListAndSensorGraph() {
        let app = XCUIApplication()
        app.launchArguments = ["-field-reports-qa"]
        app.launch()
        let session = app.staticTexts["sensors_123_0.csv"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        XCTAssertTrue(app.staticTexts["Session history"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Objects · Garage"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Field Reports Sensor Watch"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp()
        XCTAssertTrue(app.buttons["field-report-export"].waitForExistence(timeout: 3))
    }

    func testOtherReportScreensAndLargeText() {
        for kind in ["power", "uhf", "varta"] {
            let app = XCUIApplication()
            app.launchArguments = ["-field-reports-qa", "-field-reports-large-qa"]
            app.launch()
            let session = app.staticTexts["\(kind)_123_0.csv"]
            for _ in 0..<5 where !session.isHittable { app.swipeUp() }
            XCTAssertTrue(session.waitForExistence(timeout: 5)); session.tap()
            XCTAssertTrue(app.navigationBars["Session report"].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Field Reports \(kind) large text"; shot.lifetime = .keepAlways; add(shot)
            for _ in 0..<8 where !app.buttons["field-report-export"].isHittable { app.swipeUp() }
            XCTAssertTrue(app.buttons["field-report-export"].isHittable)
            app.terminate()
        }
    }
}
