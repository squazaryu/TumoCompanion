import XCTest
@testable import UnleashedCompanion

@MainActor
final class UpdateAssistantModelTests: XCTestCase {
    private final class Source: UpdateAssistantSource {
        var uid = "owned-device"
        var hash = String(repeating: "a", count: 32)
        var switchesDevice = false
        func deviceInfo() async throws -> [(String, String)] {
            [("hardware_uid", uid), ("hardware_target", "7"),
             ("firmware_version", "t-dev-009-018"), ("firmware_commit", "12345678"),
             ("firmware_api_major", "88"), ("firmware_api_minor", "15"),
             ("firmware_commit_dirty", "0")]
        }
        func sdSpace() async throws -> (free: UInt64, total: UInt64) { (1000, 2000) }
        func catalog(_ identity: TumoflipDeviceIdentity) async throws -> String { "Verified catalog" }
        func list(_ path: String) async throws -> [FlipperFile] {
            if path == "/ext" { return [.init(name: "subghz", path: "/ext/subghz", isDirectory: true, size: 0)] }
            if path == "/ext/subghz" { return [.init(name: "own.sub", path: "/ext/subghz/own.sub", isDirectory: false, size: 3)] }
            return []
        }
        func checkedMD5(_ path: String) async throws -> String? {
            if switchesDevice { uid = "another-device" }
            return hash
        }
        func read(_ path: String) async throws -> Data { Data() }
    }

    func testExplicitCheckpointIsComparedWithoutReplacingItOnRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = Source()
        let model = UpdateAssistantModel(source: source, checkpointDirectory: directory)
        await model.refresh()
        XCTAssertFalse(model.checkpointSaved)
        XCTAssertEqual(model.checks.first(where: { $0.id == "inventory" })?.state, .manual)
        model.saveCheckpoint()
        XCTAssertTrue(model.checkpointSaved)
        source.hash = String(repeating: "b", count: 32)
        await model.refresh()
        XCTAssertEqual(model.differences.first?.kind, .changed)
        await model.refresh()
        XCTAssertEqual(model.differences.first?.kind, .changed, "Refresh must not advance the baseline")
    }

    func testSwitchingDeviceDiscardsAllResults() async {
        let source = Source(); source.switchesDevice = true
        let model = UpdateAssistantModel(source: source)
        await model.refresh()
        XCTAssertTrue(model.checks.allSatisfy { $0.state == .unknown })
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.differences.isEmpty)
    }

    func testInvalidDeviceDigestCannotBecomeSuccessfulInventory() async {
        let source = Source(); source.hash = "short"
        let model = UpdateAssistantModel(source: source)
        await model.refresh()
        XCTAssertTrue(model.checks.allSatisfy { $0.state == .unknown })
        XCTAssertNotNil(model.errorMessage)
    }
}
