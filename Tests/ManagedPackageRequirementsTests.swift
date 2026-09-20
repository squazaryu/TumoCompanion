import XCTest
@testable import UnleashedCompanion

final class ManagedPackageRequirementsTests: XCTestCase {
    private let target = "/ext/apps/Bluetooth/hid_ble.fap"

    func testManagedRemoteRequiresTheCorrectForkAndAPI() {
        for api in [nil, "", "88", "88.10", "88.invalid", "88.11.0", "89.0"] as [String?] {
            XCTAssertNotNil(ManagedPackageRequirements.blocked(
                targets: [target], originFork: "tumoflip", firmwareAPI: api, hardwareTarget: 7)[target])
        }
        XCTAssertTrue(ManagedPackageRequirements.blocked(
            targets: [target], originFork: "Tumoflip", firmwareAPI: "88.11", hardwareTarget: 7).isEmpty)
        XCTAssertNotNil(ManagedPackageRequirements.blocked(
            targets: [target], originFork: "unleashed", firmwareAPI: "88.11", hardwareTarget: 7)[target])
        XCTAssertNotNil(ManagedPackageRequirements.blocked(
            targets: [target.uppercased()], originFork: "tumoflip", firmwareAPI: "88.10", hardwareTarget: 7)[target.uppercased()])
    }

    func testUnrelatedRemotesAreNotSubjectToThisRequirement() {
        XCTAssertTrue(ManagedPackageRequirements.blocked(
            targets: ["/ext/apps/USB/hid_usb.fap", "/ext/apps/Bluetooth/btremote_kodi.fap"],
            originFork: nil, firmwareAPI: nil, hardwareTarget: nil).isEmpty)
    }
}
