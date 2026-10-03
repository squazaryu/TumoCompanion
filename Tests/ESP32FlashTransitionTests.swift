import XCTest
@testable import UnleashedCompanion

final class ESP32FlashTransitionTests: XCTestCase {
    func testFirstSeenReleaseIsSilentBaseline() {
        let result = ESP32FlashTransition.evaluate(
            previous: nil, inventory: "asset-1", verifiedPlan: "plan-1")
        XCTAssertEqual(result.state.disposition, .unverified)
        XCTAssertFalse(result.notify)
    }

    func testManifestAddedToOlderManualReleaseNotifiesOnce() {
        let manual = ESP32FlashTransition.evaluate(
            previous: nil, inventory: "none", verifiedPlan: nil).state
        let eligible = ESP32FlashTransition.evaluate(
            previous: manual, inventory: "asset-2", verifiedPlan: "plan-2")
        XCTAssertEqual(eligible.state.disposition, .eligible)
        XCTAssertTrue(eligible.notify)
        XCTAssertFalse(ESP32FlashTransition.evaluate(
            previous: eligible.state, inventory: "asset-2", verifiedPlan: "plan-2").notify)
    }

    func testChangedAcceptedRecipeRequiresReview() {
        let accepted = ESP32FlashObservation(
            inventory: "asset-1", disposition: .eligible, planFingerprint: "plan-1")
        let changed = ESP32FlashTransition.evaluate(
            previous: accepted, inventory: "asset-2", verifiedPlan: "plan-2")
        XCTAssertEqual(changed.state.disposition, .reviewRequired)
        XCTAssertFalse(changed.notify)
    }

    func testInvalidCarrierCanBecomeEligible() {
        let invalid = ESP32FlashObservation(
            inventory: "asset-invalid", disposition: .invalid, planFingerprint: nil)
        let repaired = ESP32FlashTransition.evaluate(
            previous: invalid, inventory: "asset-fixed", verifiedPlan: "plan-fixed")
        XCTAssertEqual(repaired.state.disposition, .eligible)
        XCTAssertTrue(repaired.notify)
    }
}
