import XCTest
@testable import UnleashedCompanion

@MainActor
final class DeviceInfoViewTests: XCTestCase {
    func testRuntimeFirmwareDisplayExpandsCompactRuntimePrefix() {
        let viewModel = DeviceInfoViewModel()
        viewModel.info = [("firmware_version", "t-flppr-fw-007")]

        XCTAssertEqual(viewModel.runtimeFirmwareDisplay("t-flppr-"), "t-flppr-fw-007")
    }

    func testRuntimeFirmwareDisplayFallsBackToRuntimeValueWithoutSystemIdentity() {
        let viewModel = DeviceInfoViewModel()

        XCTAssertEqual(viewModel.runtimeFirmwareDisplay("t-flppr-"), "t-flppr-")
    }

    func testRuntimeFirmwareDisplayDoesNotMixUnrelatedIdentities() {
        let viewModel = DeviceInfoViewModel()
        viewModel.info = [("firmware_version", "unleashed-091")]

        XCTAssertEqual(viewModel.runtimeFirmwareDisplay("t-flppr-"), "t-flppr-")
    }
}
