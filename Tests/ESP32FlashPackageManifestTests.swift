import CryptoKit
import XCTest
@testable import UnleashedCompanion

final class ESP32FlashPackageManifestTests: XCTestCase {
    func testC5ThreeSegmentManifestRoundTrips() throws {
        let manifest = makeManifest(boardKey: "esp32c5devkitc1")

        let encoded = try manifest.encoded()
        let decoded = try JSONDecoder().decode(ESP32FlashPackageManifest.self, from: encoded)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.erasePolicy, "segments")
        XCTAssertEqual(decoded.segments.map(\.offset), [0x2000, 0x8000, 0x10000])
        XCTAssertEqual(decoded.segments.map(\.role), ["bootloader", "partition-table", "application"])
    }

    func testModuleOneFourSegmentManifestRoundTrips() throws {
        let manifest = makeManifest(boardKey: "v6_1")

        let encoded = try manifest.encoded()
        let decoded = try JSONDecoder().decode(ESP32FlashPackageManifest.self, from: encoded)

        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.segments.map(\.offset), [0x1000, 0x8000, 0xe000, 0x10000])
        XCTAssertEqual(
            decoded.segments.map(\.role),
            ["bootloader", "partition-table", "ota-data", "application"])
    }

    func testRejectsMalformedRole() {
        var segments = makeManifest(boardKey: "v6_1").segments
        segments[2] = segment(role: "settings", fileName: "boot_app0_0xe000.bin", offset: 0xe000)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: segments))
    }

    func testRejectsWrongOffset() {
        var segments = makeManifest(boardKey: "v6_1").segments
        segments[0] = segment(role: "bootloader", fileName: "bootloader_0x2000.bin", offset: 0x2000)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: segments))
    }

    func testRejectsUnexpectedModelIDsForSupportedProfiles() {
        assertInvalid(makeManifest(
            boardKey: "esp32c5devkitc1",
            modelId: "esp32-c5-devkitc-1-clone"))
        assertInvalid(makeManifest(
            boardKey: "v6_1",
            modelId: "marauder-v6-2"))
    }

    func testRejectsTraversalAndDuplicateFileNames() {
        var traversal = makeManifest(boardKey: "v6_1").segments
        traversal[0] = segment(role: "bootloader", fileName: "../bootloader.bin", offset: 0x1000)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: traversal))

        var duplicate = makeManifest(boardKey: "v6_1").segments
        duplicate[1] = segment(
            role: "partition-table",
            fileName: duplicate[0].fileName,
            offset: 0x8000)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: duplicate))
    }

    func testRejectsZeroSizeAndMalformedDigests() {
        var zeroSize = makeManifest(boardKey: "v6_1").segments
        zeroSize[0] = segment(
            role: "bootloader",
            fileName: "bootloader_0x1000.bin",
            offset: 0x1000,
            size: 0)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: zeroSize))

        var badSHA = makeManifest(boardKey: "v6_1").segments
        badSHA[0] = segment(
            role: "bootloader",
            fileName: "bootloader_0x1000.bin",
            offset: 0x1000,
            sha256: String(repeating: "z", count: 64))
        assertInvalid(makeManifest(boardKey: "v6_1", segments: badSHA))

        var badMD5 = makeManifest(boardKey: "v6_1").segments
        badMD5[0] = segment(
            role: "bootloader",
            fileName: "bootloader_0x1000.bin",
            offset: 0x1000,
            md5: String(repeating: "a", count: 31))
        assertInvalid(makeManifest(boardKey: "v6_1", segments: badMD5))
    }

    func testRejectsUnknownBoardAndForeignProducer() {
        assertInvalid(makeManifest(boardKey: "marauder_v7"))
        assertInvalid(makeManifest(
            boardKey: "v6_1",
            createdByApplication: "OtherCompanion"))
    }

    func testRejectsUnsafeOrOversizedFileNames() {
        let invalidNames = [
            ".bootloader_0x1000.bin",
            "boot loader_0x1000.bin",
            "bootloader_ж_0x1000.bin",
            "boot..loader_0x1000.bin",
            String(repeating: "a", count: 92) + ".bin",
        ]
        for fileName in invalidNames {
            var segments = makeManifest(boardKey: "v6_1").segments
            segments[0] = segment(
                role: "bootloader",
                fileName: fileName,
                offset: 0x1000)
            assertInvalid(makeManifest(boardKey: "v6_1", segments: segments))
        }
    }

    func testRejectsValuesOutsideUInt32AndOverlappingSegments() {
        var oversizedOffset = makeManifest(boardKey: "v6_1").segments
        oversizedOffset[3] = segment(
            role: "application",
            fileName: oversizedOffset[3].fileName,
            offset: Int(UInt32.max) + 1)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: oversizedOffset))

        var oversizedSize = makeManifest(boardKey: "v6_1").segments
        oversizedSize[0] = segment(
            role: "bootloader",
            fileName: oversizedSize[0].fileName,
            offset: 0x1000,
            size: Int(UInt32.max) + 1)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: oversizedSize))

        var overlapping = makeManifest(boardKey: "v6_1").segments
        overlapping[0] = segment(
            role: "bootloader",
            fileName: overlapping[0].fileName,
            offset: 0x1000,
            size: 0x8000)
        assertInvalid(makeManifest(boardKey: "v6_1", segments: overlapping))
    }

    func testRejectsRenamedC5CompatibilityBootloader() {
        var segments = makeManifest(boardKey: "esp32c5devkitc1").segments
        segments[0] = segment(
            role: "bootloader",
            fileName: "c5_bootloader_0x2000.bin",
            offset: 0x2000,
            size: 20_464,
            sha256: "3e2b92a74cf406745dddc88ecb5193fd446f4b269b96d2b9991d84f41c810611")
        assertInvalid(makeManifest(boardKey: "esp32c5devkitc1", segments: segments))
    }

    func testAtomicReplacementMovesManifestWithPackage() async throws {
        let fixture = try makeStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = "/ext/apps_data/esp_flasher/module_one_v6_1_v1_14_1_manual"
        let staging = "\(target).partial-test"
        let manifestData = try makeManifest(boardKey: "v6_1").encoded()

        try await fixture.storage.makeDirectory(target)
        try await fixture.storage.write("\(target)/old.bin", data: Data("old".utf8))
        try await fixture.storage.makeDirectory(staging)
        try await fixture.storage.write("\(staging)/new.bin", data: Data("new".utf8))
        try await fixture.storage.write(
            "\(staging)/\(ESP32FlashPackageManifest.fileName)",
            data: manifestData)

        try await ESP32PackageTransaction.replaceAtomically(
            storage: fixture.storage,
            target: target,
            staging: staging,
            archiveDirectory: "/ext/apps_data/esp_flasher/_archive",
            replacementID: "test")

        let oldExists = await fixture.storage.exists("\(target)/old.bin")
        let newExists = await fixture.storage.exists("\(target)/new.bin")
        let installedManifest = try await fixture.storage.read(
            "\(target)/\(ESP32FlashPackageManifest.fileName)")
        XCTAssertFalse(oldExists)
        XCTAssertTrue(newExists)
        XCTAssertEqual(installedManifest, manifestData)
    }

    func testReplacementRollbackRestoresOriginalFolderAndManifest() async throws {
        let fixture = try makeStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = "/ext/apps_data/esp_flasher/module_one_v6_1_v1_14_1_manual"
        let staging = "\(target).partial-test"
        let oldManifest = Data("old manifest".utf8)

        try await fixture.storage.makeDirectory(target)
        try await fixture.storage.write(
            "\(target)/\(ESP32FlashPackageManifest.fileName)",
            data: oldManifest)
        try await fixture.storage.makeDirectory(staging)
        try await fixture.storage.write(
            "\(staging)/\(ESP32FlashPackageManifest.fileName)",
            data: Data("new manifest".utf8))
        let failing = FailingMoveStore(
            base: fixture.storage,
            failingSource: staging,
            failingDestination: target)

        do {
            try await ESP32PackageTransaction.replaceAtomically(
                storage: failing,
                target: target,
                staging: staging,
                archiveDirectory: "/ext/apps_data/esp_flasher/_archive",
                replacementID: "test")
            XCTFail("Expected replacement failure")
        } catch {
            XCTAssertEqual(error as? FailingMoveStore.TestError, .injected)
        }

        let restoredManifest = try await fixture.storage.read(
            "\(target)/\(ESP32FlashPackageManifest.fileName)")
        let stagingStillExists = await fixture.storage.exists(staging)
        XCTAssertEqual(restoredManifest, oldManifest)
        XCTAssertTrue(stagingStillExists)
    }

    func testCommitMarkerIsWrittenOnlyAfterExactBinarySetExists() async throws {
        let fixture = try makeStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = "/ext/apps_data/esp_flasher/package.partial-test"
        let manifest = makeManifest(boardKey: "v6_1")
        try await fixture.storage.makeDirectory(directory)
        for segment in manifest.segments {
            try await fixture.storage.write(
                "\(directory)/\(segment.fileName)",
                data: Data(segment.fileName.utf8))
        }

        try await ESP32PackageCommitMarker.writeManifestLast(
            storage: fixture.storage,
            directory: directory,
            manifest: manifest)

        let manifestData = try await fixture.storage.read(
            "\(directory)/\(ESP32FlashPackageManifest.fileName)")
        XCTAssertEqual(
            try JSONDecoder().decode(ESP32FlashPackageManifest.self, from: manifestData),
            manifest)
    }

    func testCommitMarkerFailsClosedOnExtraBinaryOrManifestMD5Mismatch() async throws {
        let fixture = try makeStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = "/ext/apps_data/esp_flasher/package.partial-test"
        let manifest = makeManifest(boardKey: "v6_1")
        try await fixture.storage.makeDirectory(directory)
        for segment in manifest.segments {
            try await fixture.storage.write(
                "\(directory)/\(segment.fileName)",
                data: Data(segment.fileName.utf8))
        }
        try await fixture.storage.write("\(directory)/unexpected.bin", data: Data())

        do {
            try await ESP32PackageCommitMarker.writeManifestLast(
                storage: fixture.storage,
                directory: directory,
                manifest: manifest)
            XCTFail("Expected unexpected staging contents")
        } catch {
            XCTAssertEqual(error as? ESP32FlashPackageError, .unexpectedStagingContents)
        }
        let manifestPath = "\(directory)/\(ESP32FlashPackageManifest.fileName)"
        let manifestExists = await fixture.storage.exists(manifestPath)
        XCTAssertFalse(manifestExists)

        try await fixture.storage.delete("\(directory)/unexpected.bin")
        let badReadback = FailingMoveStore(
            base: fixture.storage,
            failingSource: "",
            failingDestination: "",
            badMD5Path: manifestPath)
        do {
            try await ESP32PackageCommitMarker.writeManifestLast(
                storage: badReadback,
                directory: directory,
                manifest: manifest)
            XCTFail("Expected manifest readback failure")
        } catch {
            XCTAssertEqual(error as? ESP32FlashPackageError, .manifestReadbackFailed)
        }
    }

    func testArchiveOnlyRedownloadLeavesArchivedManifestUntouched() async throws {
        let fixture = try makeStorageFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let archiveDirectory = "/ext/apps_data/esp_flasher/_archive"
        let archive = "\(archiveDirectory)/module_one_v6_1_v1_13_0_manual"
        let active = "/ext/apps_data/esp_flasher/module_one_v6_1_v1_14_1_manual"
        let staging = "\(active).partial-test"
        let archivedManifest = Data("archived immutable manifest".utf8)
        let activeManifest = try makeManifest(boardKey: "v6_1").encoded()

        try await fixture.storage.makeDirectory(archive)
        try await fixture.storage.write(
            "\(archive)/\(ESP32FlashPackageManifest.fileName)",
            data: archivedManifest)
        try await fixture.storage.makeDirectory(staging)
        try await fixture.storage.write(
            "\(staging)/\(ESP32FlashPackageManifest.fileName)",
            data: activeManifest)

        try await ESP32PackageTransaction.replaceAtomically(
            storage: fixture.storage,
            target: active,
            staging: staging,
            archiveDirectory: archiveDirectory,
            replacementID: "test")

        let preservedArchive = try await fixture.storage.read(
            "\(archive)/\(ESP32FlashPackageManifest.fileName)")
        let installedManifest = try await fixture.storage.read(
            "\(active)/\(ESP32FlashPackageManifest.fileName)")
        XCTAssertEqual(preservedArchive, archivedManifest)
        XCTAssertEqual(installedManifest, activeManifest)
    }

    private func assertInvalid(
        _ manifest: ESP32FlashPackageManifest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try manifest.validate(), file: file, line: line)
    }

    private func makeManifest(
        boardKey: String,
        modelId: String? = nil,
        segments: [ESP32FlashPackageManifest.Segment]? = nil,
        createdByApplication: String = "TumoCompanion"
    ) -> ESP32FlashPackageManifest {
        let isC5 = boardKey == "esp32c5devkitc1"
        let resolvedSegments = segments ?? (isC5 ? [
            segment(
                role: "bootloader",
                fileName: "bootloader_0x2000.bin",
                offset: 0x2000,
                size: 20_464,
                sha256: "3e2b92a74cf406745dddc88ecb5193fd446f4b269b96d2b9991d84f41c810611"),
            segment(role: "partition-table", fileName: "partitions_0x8000.bin", offset: 0x8000),
            segment(
                role: "application",
                fileName: "esp32_marauder_v1_14_1_esp32c5devkitc1_0x10000.bin",
                offset: 0x10000),
        ] : [
            segment(role: "bootloader", fileName: "bootloader_0x1000.bin", offset: 0x1000),
            segment(role: "partition-table", fileName: "partitions_0x8000.bin", offset: 0x8000),
            segment(role: "ota-data", fileName: "boot_app0_0xe000.bin", offset: 0xe000),
            segment(
                role: "application",
                fileName: "esp32_marauder_v1_14_1_v6_1_0x10000.bin",
                offset: 0x10000),
        ])
        return ESP32FlashPackageManifest(
            schemaVersion: 1,
            packageKind: "tumoflip-esp32-flash-package",
            board: .init(
                key: boardKey,
                modelId: modelId ?? (isC5 ? "esp32-c5-devkitc-1" : "marauder-v6-1"),
                displayName: isC5 ? "ESP32-C5-DevKitC-1" : "Marauder v6.1",
                chipFamily: isC5 ? "esp32c5" : "esp32"),
            firmware: .init(
                version: "v1.14.1",
                sourceRepository: "justcallmekoko/ESP32Marauder",
                sourceRelease: "https://github.com/justcallmekoko/ESP32Marauder/releases/tag/v1.14.1"),
            recipe: .init(
                id: isC5 ? "c5-compat-v1" : "upstream-factory-v1",
                status: isC5 ? "hardware-accepted" : "authoritative"),
            erasePolicy: "segments",
            segments: resolvedSegments,
            createdAt: "2026-08-10T18:30:00.000Z",
            createdBy: .init(application: createdByApplication, version: "1.10.10"))
    }

    private func segment(
        role: String,
        fileName: String,
        offset: Int,
        size: Int = 1_024,
        sha256: String = String(repeating: "a", count: 64),
        md5: String = String(repeating: "b", count: 32)
    ) -> ESP32FlashPackageManifest.Segment {
        .init(
            role: role,
            fileName: fileName,
            offset: offset,
            size: size,
            sha256: sha256,
            md5: md5)
    }

    private func makeStorageFixture() throws -> (root: URL, storage: USBSDStorage) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tumocompanion-esp32-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, USBSDStorage(rootURL: root))
    }

}

private final class FailingMoveStore: DeviceFileStore {
    enum TestError: Error, Equatable { case injected }

    let base: USBSDStorage
    let failingSource: String
    let failingDestination: String
    let badMD5Path: String?
    var channel: TransferChannel { base.channel }

    init(
        base: USBSDStorage,
        failingSource: String,
        failingDestination: String,
        badMD5Path: String? = nil
    ) {
        self.base = base
        self.failingSource = failingSource
        self.failingDestination = failingDestination
        self.badMD5Path = badMD5Path
    }

    func list(_ path: String) async throws -> [FlipperFile] { try await base.list(path) }
    func read(_ path: String) async throws -> Data { try await base.read(path) }
    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)?
    ) async throws {
        try await base.write(path, data: data, progress: progress)
    }
    func makeDirectory(_ path: String) async throws { try await base.makeDirectory(path) }
    func delete(_ path: String, recursive: Bool) async throws {
        try await base.delete(path, recursive: recursive)
    }
    func move(_ from: String, to newPath: String) async throws {
        if from == failingSource && newPath == failingDestination { throw TestError.injected }
        try await base.move(from, to: newPath)
    }
    func md5(_ path: String) async -> String? {
        if path == badMD5Path { return String(repeating: "0", count: 32) }
        return await base.md5(path)
    }
    func checkedMD5(_ path: String) async throws -> String? { try await base.checkedMD5(path) }
    func exists(_ path: String) async -> Bool { await base.exists(path) }
}
