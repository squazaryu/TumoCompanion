import XCTest

final class CommunityCleanupUITests: XCTestCase {
    func testReviewIsNotOfferedAsCleanupInLightMode() { assertReview("light") }
    func testReviewIsNotOfferedAsCleanupInDarkMode() { assertReview("dark") }
    func testReviewWithLargeType() { assertReview("light", largeType: true) }

    func testConfirmationCountsOnlyVerifiedPathsAndCanBeCancelled() {
        let app = launch(mode: "ready", appearance: "dark")
        let cleanup = app.buttons["community-cleanup-action"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        XCTAssertEqual(cleanup.label, "Clean Up 2")
        XCTAssertTrue(app.buttons["community-cleanup-recheck"].exists)
        cleanup.tap()
        XCTAssertTrue(app.staticTexts["2 verified old routes"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Cancel Community apps cleanup"].exists)
        capture("Cleanup confirmation - two verified, one review")
        app.buttons["Cancel Community apps cleanup"].tap()
        XCTAssertTrue(cleanup.exists)
        XCTAssertFalse(app.staticTexts["2 verified old routes"].exists)
    }

    func testIdenticalBytesNeedAMoveNotAnotherCleanup() {
        let app = launch(mode: "migration", appearance: "light")
        XCTAssertTrue(app.buttons["community-install-action"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["community-cleanup-action"].exists)
        app.buttons["community-apps-details-drawer-toggle"].tap()
        let sensors = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sensors")).firstMatch
        XCTAssertTrue(sensors.waitForExistence(timeout: 5))
        sensors.tap()
        XCTAssertTrue(app.staticTexts["community-route-move"].waitForExistence(timeout: 3))
        capture("Community identical binary - explicit route MOVE")
    }

    private func assertReview(_ appearance: String, largeType: Bool = false) {
        let app = launch(mode: "review", appearance: appearance, largeType: largeType)
        XCTAssertTrue(app.buttons["community-cleanup-recheck"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["community-cleanup-action"].exists,
                       "A kept/unverified route must not advertise another destructive action")
        app.buttons["community-apps-details-drawer-toggle"].tap()
        let review = app.descendants(matching: .any).matching(identifier: "community-cleanup-review-count").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Install the current app at its new path first."].firstMatch.exists)
        app.swipeUp()
        capture("Community cleanup review - \(appearance)\(largeType ? " - large text" : "")")
    }

    private func launch(mode: String, appearance: String, largeType: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingDone", "YES", "-appearanceMode", appearance,
                               "-community-route-cleanup-qa", mode]
        if largeType {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        }
        app.launch()
        let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "Don’t Allow", "Don't Allow")
        ).firstMatch
        if deny.waitForExistence(timeout: 2) { deny.tap() }
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
