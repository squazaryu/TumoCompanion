import XCTest

final class FieldWorkflowsUITests: XCTestCase {
  func testRoundsInventoriesAndIncompleteLogInBothAppearances() {
    for appearance in ["dark", "light"] {
      let app = launch(appearance)
      app.buttons["field-kit-evidence"].tap()
      let round = app.buttons["field-evidence-round-100-0123456789abcdef.txt"]
      reveal(round, in: app)
      XCTAssertTrue(round.waitForExistence(timeout: 5))
      round.tap()
      reveal(app.staticTexts["Front gate"], in: app)
      XCTAssertTrue(app.staticTexts["Front gate"].waitForExistence(timeout: 5))
      shot("Manual round \(appearance)")
      app.navigationBars.buttons.element(boundBy: 0).tap()
      let inventory = app.buttons["field-evidence-102-00.tinv"]
      reveal(inventory, in: app)
      inventory.tap()
      reveal(app.staticTexts["/ext/nfc/Office.nfc"], in: app)
      XCTAssertTrue(app.staticTexts["/ext/nfc/Office.nfc"].waitForExistence(timeout: 5))
      shot("Inventory \(appearance)")
      app.navigationBars.buttons.element(boundBy: 0).tap()
      let log = app.buttons["field-evidence-102-00.txt"]
      reveal(log, in: app)
      log.tap()
      XCTAssertTrue(app.staticTexts["Completeness unknown"].waitForExistence(timeout: 5))
      shot("Incomplete difference log \(appearance)")
      app.terminate()
    }
  }

  func testProfilePreviewAndCheckedApplyOnSyntheticDevice() {
    let app = launch("light")
    app.buttons["field-kit-profile"].tap()
    let review = app.buttons["field-profile-review"]
    reveal(review, in: app)
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    review.tap()
    let confirm = app.buttons["field-profile-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    shot("Profile confirmation before write")
    confirm.tap()
    XCTAssertTrue(
      app.staticTexts["Profile readback verified. The original backup is retained on this iPhone."]
        .waitForExistence(timeout: 5))
    shot("Verified profile apply")
    app.terminate()
  }

  func testObjectEditorLargeTextAndUnavailableEvidence() {
    let app = launch("dark", extra: ["-field-workflows-large-qa"])
    app.buttons["field-kit-objects"].tap()
    XCTAssertTrue(app.textFields["field-object-name"].waitForExistence(timeout: 5))
    shot("Object card large text")
    let review = app.buttons["field-object-review"]
    reveal(review, in: app)
    review.tap()
    XCTAssertTrue(app.navigationBars["Review object package"].waitForExistence(timeout: 5))
    shot("Object package large text")
    app.terminate()
    let failed = launch("light", extra: ["-field-workflows-fail-qa"])
    failed.buttons["field-kit-evidence"].tap()
    XCTAssertTrue(
      failed.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "synthetic unavailable")
      ).firstMatch.waitForExistence(timeout: 5))
    shot("Field evidence unavailable")
    failed.terminate()
  }

  func testSelectiveRecoveryConfirmsNewCopyOnly() {
    let app = XCUIApplication()
    app.launchArguments = ["-field-workflows-qa", "-field-restore-qa", "-field-workflows-light-qa"]
    app.launch()
    let capture = app.buttons["field-backup-capture-subghz/Owned_gate.sub"]
    XCTAssertTrue(capture.waitForExistence(timeout: 8))
    capture.tap()
    let confirm = app.buttons["field-capture-restore-confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    shot("Selective recovery preview")
    confirm.tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "New copy verified: /ext/subghz/Restored/")
      ).firstMatch.waitForExistence(timeout: 5))
    shot("Selective recovery verified")
    app.terminate()
  }

  private func launch(_ appearance: String, extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-field-workflows-qa"] + extra
    if appearance == "light" { app.launchArguments.append("-field-workflows-light-qa") }
    app.launch()
    XCTAssertTrue(app.buttons["field-kit-evidence"].waitForExistence(timeout: 5))
    return app
  }
  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<14 where !element.isHittable { app.swipeUp() }
  }
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
