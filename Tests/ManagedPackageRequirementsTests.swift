import XCTest
@testable import UnleashedCompanion

final class ManagedPackageRequirementsTests: XCTestCase {
    private let target = "/ext/apps/Bluetooth/hid_ble.fap"

    func testDeviceLibraryRequiresItsExportWithoutRaisingOtherRequirements() {
        let library = "/ext/apps/Tools/device_library.fap"
        for api in [nil, "", "88", "88.4", "88.bad", "88.5.0", "89.0", "88.-1",
                    "88.99999999999999999999999"] as [String?] {
            XCTAssertNotNil(ManagedPackageRequirements.blocked(
                targets: [library], originFork: "tumoflip", firmwareAPI: api, hardwareTarget: 7)[library])
        }
        for api in ["88.5", "88.13"] {
            XCTAssertTrue(ManagedPackageRequirements.blocked(
                targets: [library], originFork: "Tumoflip", firmwareAPI: api, hardwareTarget: 7).isEmpty)
        }
        for (fork, hardware) in [("unleashed", 7), ("tumoflip", 18)] {
            XCTAssertNotNil(ManagedPackageRequirements.blocked(
                targets: [library.uppercased()], originFork: fork, firmwareAPI: "88.13",
                hardwareTarget: hardware)[library.uppercased()])
        }
        let mixed = ManagedPackageRequirements.blocked(
            targets: [library, target, "/ext/apps_data/device_library/plugins/file_history.fal"],
            originFork: "tumoflip", firmwareAPI: "88.5", hardwareTarget: 7)
        XCTAssertEqual(Set(mixed.keys), [target])
    }

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
