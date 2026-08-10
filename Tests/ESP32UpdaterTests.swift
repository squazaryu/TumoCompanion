import XCTest
@testable import UnleashedCompanion

/// Tests for ESP32 Marauder image-name parsing — the version/board-key extraction
/// that matches a local manual-flash folder to a GitHub release asset. Regression
/// cover for the esp32-c5 board, whose filename places the 0x10000 offset before the
/// board name and whose release asset carries a build date.
final class ESP32UpdaterTests: XCTestCase {

    private func parse(_ name: String) -> (version: String, key: String)? {
        ESP32Updater.parseImageName(name)
    }

    func testReleaseAssetNames() {
        // Real justcallmekoko/ESP32Marauder v1.12.2 asset names (version + date + board).
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin")?.key, "esp32c5devkitc1")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_v6_1.bin")?.key, "v6_1")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_marauder_v7.bin")?.key, "marauder_v7")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_cyd_2432S028.bin")?.key, "cyd_2432S028")
        XCTAssertEqual(parse("esp32_marauder_v1_12_2_20260617_flipper.bin")?.version, "v1.12.2")
    }

    func testLocalManualFolderNames() {
        // Module One style: version + board + offset, no date.
        let moduleOne = parse("esp32_marauder_v1_12_1_v6_1_0x10000.bin")
        XCTAssertEqual(moduleOne?.version, "v1.12.1")
        XCTAssertEqual(moduleOne?.key, "v6_1")

        // The esp32-c5 bug case: offset BEFORE the board name, ".bin" not a clean suffix.
        // Old parser produced key "0x10000_esp32c5devkitc1.bin"; now it's clean.
        let c5 = parse("esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin")
        XCTAssertEqual(c5?.version, "v1.12.2")
        XCTAssertEqual(c5?.key, "esp32c5devkitc1")
    }

    func testWrittenBackNameRoundTrips() {
        // The name install() writes for a new manual folder must re-parse to the same key.
        let written = "esp32_marauder_v1_12_2_esp32c5devkitc1_0x10000.bin"
        XCTAssertEqual(parse(written)?.key, "esp32c5devkitc1")
        XCTAssertEqual(parse(written)?.version, "v1.12.2")
    }

    func testLocalKeyMatchesReleaseKey() {
        // The whole point: a local board matches its release asset by key.
        let local = parse("esp32_marauder_v1_12_2_0x10000_esp32c5devkitc1.bin")?.key
        let asset = parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.bin")?.key
        XCTAssertNotNil(local)
        XCTAssertEqual(local, asset)
    }

    func testRejectsNonMarauderNames() {
        XCTAssertNil(parse("bootloader_0x1000.bin"))
        XCTAssertNil(parse("partitions_0x8000.bin"))
        XCTAssertNil(parse("boot_app0_0xe000.bin"))
        XCTAssertNil(parse("esp32_marauder_no_version_here.bin"))
        XCTAssertNil(parse("esp32_marauder_v1_12_2_20260617_esp32c5devkitc1.txt"))
    }

    func testManualFolderDetection() {
        XCTAssertTrue(ESP32Updater.isManualFolder("module_one_v6_1_v1_12_3_manual"))
        XCTAssertFalse(ESP32Updater.isManualFolder("_archive"))
        XCTAssertFalse(ESP32Updater.isManualFolder("module_one_v6_1_v1_12_3"))
    }

    func testFolderNameExtraction() {
        XCTAssertEqual(
            ESP32Updater.folderName(from: "/ext/apps_data/esp_flasher/module_one_v6_1_v1_12_3_manual"),
            "module_one_v6_1_v1_12_3_manual")
        XCTAssertEqual(ESP32Updater.folderName(from: "plain_manual"), "plain_manual")
    }

    func testArchivedOnlyBoardRemainsAvailableForRedownload() {
        let archived = board(
            folder: "/ext/apps_data/esp_flasher/_archive/module_one_v6_1_v1_14_1_manual",
            version: "v1.14.1",
            key: "v6_1")

        let selected = ESP32Updater.selectStagingBoards(active: [], archived: [archived])

        XCTAssertEqual(selected, [archived])
    }

    func testActivePackageWinsOverNewerArchivedCopyAsLegacySource() {
        let active = board(
            folder: "/ext/apps_data/esp_flasher/module_one_v6_1_v1_13_0_manual",
            version: "v1.13.0",
            key: "v6_1")
        let archived = board(
            folder: "/ext/apps_data/esp_flasher/_archive/module_one_v6_1_v1_14_1_manual",
            version: "v1.14.1",
            key: "v6_1")

        let selected = ESP32Updater.selectStagingBoards(active: [active], archived: [archived])

        XCTAssertEqual(selected, [active])
    }

    func testNewestArchivedPackageIsUsedWhenNoActivePackageExists() {
        let old = board(
            folder: "/ext/apps_data/esp_flasher/_archive/module_one_v6_1_v1_13_0_manual",
            version: "v1.13.0",
            key: "v6_1")
        let latest = board(
            folder: "/ext/apps_data/esp_flasher/_archive/module_one_v6_1_v1_14_1_manual",
            version: "v1.14.1",
            key: "v6_1")

        let selected = ESP32Updater.selectStagingBoards(active: [], archived: [old, latest])

        XCTAssertEqual(selected, [latest])
    }

    func testAuthoritativeInstallerManifestProducesCompleteFactoryPackage() throws {
        let manifest = try ESP32Updater.decodeManifest(manifestData(), expectedVersion: "v1.14.1")
        let packageBoard = try ESP32Updater.packageBoard(for: "v6_1", manifest: manifest)
        let sizes = [
            "esp32_marauder_installer_v1_14_1_20260801_v6_1.bootloader.bin": 23_664,
            "esp32_marauder_installer_v1_14_1_20260801_v6_1.partition-table.bin": 3_072,
            "esp32_marauder_installer_v1_14_1_20260801_v6_1.ota-data.bin": 8_192,
            "esp32_marauder_installer_v1_14_1_20260801_v6_1.bin": 1_694_384,
        ]
        let digests = Dictionary(uniqueKeysWithValues: sizes.keys.map { ($0, String(repeating: "a", count: 64)) })
        let segments = try ESP32Updater.factorySegments(
            for: "v6_1",
            manifest: manifest,
            assetSizes: sizes,
            assetSHA256: digests)

        XCTAssertEqual(segments.map(\.offset), [0x1000, 0x8000, 0xe000, 0x10000])
        XCTAssertEqual(packageBoard.modelId, "marauder-v6-1")
        XCTAssertEqual(packageBoard.displayName, "Marauder v6.1")
        XCTAssertEqual(packageBoard.chipFamily, "esp32")
        XCTAssertEqual(
            segments.map { ESP32Updater.stagedFileName(for: $0, version: manifest.version, boardKey: "v6_1") },
            [
                "bootloader_0x1000.bin",
                "partitions_0x8000.bin",
                "boot_app0_0xe000.bin",
                "esp32_marauder_v1_14_1_v6_1_0x10000.bin",
            ])
    }

    func testC5InstallerManifestProducesHardwareAcceptedThreeFilePackage() throws {
        let manifest = try ESP32Updater.decodeManifest(c5ManifestData(), expectedVersion: "v1.14.1")
        let packageBoard = try ESP32Updater.packageBoard(for: "esp32c5devkitc1", manifest: manifest)
        let segments = try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: c5RequiredAssetSizes,
            assetSHA256: c5ReleaseAssetSHA256)

        XCTAssertEqual(segments.map(\.role), ["bootloader", "partition-table", "application"])
        XCTAssertEqual(packageBoard.modelId, "esp32-c5-devkitc-1")
        XCTAssertEqual(packageBoard.displayName, "ESP32-C5-DevKitC-1")
        XCTAssertEqual(packageBoard.chipFamily, "esp32c5")
        XCTAssertEqual(segments.map(\.offset), [0x2000, 0x8000, 0x10000])
        XCTAssertEqual(segments.first?.size, 20_464)
        XCTAssertEqual(
            segments.first?.sha256,
            "3e2b92a74cf406745dddc88ecb5193fd446f4b269b96d2b9991d84f41c810611")
        XCTAssertEqual(segments.last?.sha256, c5ReleaseAssetSHA256[
            "esp32_marauder_v1_14_1_20260801_esp32c5devkitc1.bin"])
        XCTAssertEqual(
            segments.map(\.fileName),
            [
                "c5_adapter_v1_13_0_bootloader.bin",
                "esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.partition-table.bin",
                "esp32_marauder_v1_14_1_20260801_esp32c5devkitc1.bin",
            ])
        XCTAssertEqual(
            segments.map {
                ESP32Updater.stagedFileName(
                    for: $0,
                    version: manifest.version,
                    boardKey: "esp32c5devkitc1")
            },
            [
                "bootloader_0x2000.bin",
                "partitions_0x8000.bin",
                "esp32_marauder_v1_14_1_esp32c5devkitc1_0x10000.bin",
            ])
    }

    func testC5InstallerManifestRejectsWrongPartitionOffset() throws {
        let manifest = try ESP32Updater.decodeManifest(
            c5ManifestData(partitionOffset: 0x9000),
            expectedVersion: "v1.14.1")

        XCTAssertThrowsError(try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: c5RequiredAssetSizes,
            assetSHA256: c5ReleaseAssetSHA256)) { error in
                XCTAssertEqual(error as? ESP32ManifestError, .invalidSegments("esp32c5devkitc1"))
            }
    }

    func testC5InstallerManifestDoesNotAdoptUnacceptedReleaseBootloader() throws {
        let manifest = try ESP32Updater.decodeManifest(
            c5ManifestData(bootloaderOffset: 0x1000),
            expectedVersion: "v1.14.1")
        let segments = try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: c5RequiredAssetSizes,
            assetSHA256: c5ReleaseAssetSHA256)

        XCTAssertEqual(segments.first?.offset, 0x2000)
        XCTAssertEqual(segments.first?.size, 20_464)
        XCTAssertEqual(segments.first?.fileName, "c5_adapter_v1_13_0_bootloader.bin")
    }

    func testC5InstallerManifestFailsClosedOnPartitionDigestMismatch() throws {
        let manifest = try ESP32Updater.decodeManifest(c5ManifestData(), expectedVersion: "v1.14.1")
        let partitions = "esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.partition-table.bin"
        var digests = c5ReleaseAssetSHA256
        digests[partitions] = String(repeating: "d", count: 64)

        XCTAssertThrowsError(try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: c5RequiredAssetSizes,
            assetSHA256: digests)) { error in
                XCTAssertEqual(error as? ESP32ManifestError, .assetMetadataMismatch(partitions))
            }
    }

    func testC5InstallerManifestFailsClosedWithoutNormalApplication() throws {
        let manifest = try ESP32Updater.decodeManifest(c5ManifestData(), expectedVersion: "v1.14.1")
        var sizes = c5RequiredAssetSizes
        sizes.removeValue(forKey: "esp32_marauder_v1_14_1_20260801_esp32c5devkitc1.bin")

        XCTAssertThrowsError(try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: sizes,
            assetSHA256: [:])) { error in
                XCTAssertEqual(
                    error as? ESP32ManifestError,
                    .missingAsset("normal v1.14.1 application for esp32c5devkitc1"))
            }
    }

    func testC5InstallerManifestFailsClosedWithoutNormalApplicationDigest() throws {
        let manifest = try ESP32Updater.decodeManifest(c5ManifestData(), expectedVersion: "v1.14.1")

        XCTAssertThrowsError(try ESP32Updater.factorySegments(
            for: "esp32c5devkitc1",
            manifest: manifest,
            assetSizes: c5RequiredAssetSizes,
            assetSHA256: [:])) { error in
                XCTAssertEqual(
                    error as? ESP32ManifestError,
                    .missingAsset("normal v1.14.1 application for esp32c5devkitc1"))
            }
    }

    func testInstallerManifestRejectsWrongVersion() {
        XCTAssertThrowsError(try ESP32Updater.decodeManifest(manifestData(), expectedVersion: "v1.14.0")) { error in
            XCTAssertEqual(
                error as? ESP32ManifestError,
                .versionMismatch(expected: "v1.14.0", actual: "v1.14.1"))
        }
    }

    func testPackageIdentityFailsClosedWhenAuthoritativeTargetIdentityIsMissing() throws {
        let manifest = try ESP32Updater.decodeManifest(
            manifestData(includeIdentity: false),
            expectedVersion: "v1.14.1")

        XCTAssertThrowsError(try ESP32Updater.packageBoard(for: "v6_1", manifest: manifest)) { error in
            XCTAssertEqual(error as? ESP32FlashPackageError, .invalidBoard("v6_1"))
        }
    }

    func testPackageIdentityRejectsChipFamilyMismatch() throws {
        let json = try XCTUnwrap(String(data: manifestData(), encoding: .utf8))
            .replacingOccurrences(of: "\"chipFamily\": \"ESP32\"", with: "\"chipFamily\": \"ESP32-S3\"")
        let manifest = try ESP32Updater.decodeManifest(Data(json.utf8), expectedVersion: "v1.14.1")

        XCTAssertThrowsError(try ESP32Updater.packageBoard(for: "v6_1", manifest: manifest)) { error in
            XCTAssertEqual(error as? ESP32FlashPackageError, .invalidBoard("v6_1"))
        }
    }

    func testAutomaticPackageSchemaV1SupportsOnlyFirmwareProfiles() {
        XCTAssertTrue(ESP32Updater.automaticPackageSupported(for: "esp32c5devkitc1"))
        XCTAssertTrue(ESP32Updater.automaticPackageSupported(for: "v6_1"))
        XCTAssertFalse(ESP32Updater.automaticPackageSupported(for: "marauder_v7"))
        XCTAssertFalse(ESP32Updater.automaticPackageSupported(for: "flipper"))

        XCTAssertTrue(ESP32Updater.shouldWriteAutomaticPackageManifest(
            hasAuthoritativeManifest: true,
            boardKey: "v6_1"))
        XCTAssertFalse(ESP32Updater.shouldWriteAutomaticPackageManifest(
            hasAuthoritativeManifest: false,
            boardKey: "v6_1"))
        XCTAssertFalse(ESP32Updater.shouldWriteAutomaticPackageManifest(
            hasAuthoritativeManifest: true,
            boardKey: "marauder_v7"))
    }

    func testPackageIdentityRejectsAuthoritativeButUnsupportedTarget() throws {
        let json = try XCTUnwrap(String(data: manifestData(), encoding: .utf8))
            .replacingOccurrences(of: "marauder-v6-1", with: "marauder-v7")
            .replacingOccurrences(of: "Marauder v6.1", with: "Marauder v7")
            .replacingOccurrences(of: "v6_1", with: "marauder_v7")
        let manifest = try ESP32Updater.decodeManifest(Data(json.utf8), expectedVersion: "v1.14.1")

        XCTAssertThrowsError(
            try ESP32Updater.packageBoard(for: "marauder_v7", manifest: manifest)
        ) { error in
            XCTAssertEqual(error as? ESP32FlashPackageError, .invalidBoard("marauder_v7"))
        }
    }

    func testInstallerManifestFailsClosedWhenReleaseAssetIsMissing() throws {
        let manifest = try ESP32Updater.decodeManifest(manifestData(), expectedVersion: "v1.14.1")
        XCTAssertThrowsError(try ESP32Updater.factorySegments(
            for: "v6_1",
            manifest: manifest,
            assetSizes: ["esp32_marauder_installer_v1_14_1_20260801_v6_1.bin": 1_694_384],
            assetSHA256: [:])) { error in
                XCTAssertEqual(
                    error as? ESP32ManifestError,
                    .missingAsset("esp32_marauder_installer_v1_14_1_20260801_v6_1.bootloader.bin"))
            }
    }

    private func manifestData(includeIdentity: Bool = true) -> Data {
        let identity = includeIdentity ? #"""
            "displayName": "Marauder v6.1",
            "chipFamily": "ESP32",
            "esptoolChip": "esp32",
        """# : ""
        return Data(#"""
        {
          "schemaVersion": 1,
          "channel": "stable",
          "kind": "esp32-marauder-installer-release",
          "metadataStatus": "authoritative",
          "sourceRepository": "justcallmekoko/ESP32Marauder",
          "version": "v1.14.1",
          "targets": [{
            "id": "marauder-v6-1",
            \#(identity)
            "assetSuffix": "v6_1",
            "flash": {"factory": {"segments": [
              {"role":"application","offset":65536,"size":1694384,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileName":"esp32_marauder_installer_v1_14_1_20260801_v6_1.bin"},
              {"role":"bootloader","offset":4096,"size":23664,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileName":"esp32_marauder_installer_v1_14_1_20260801_v6_1.bootloader.bin"},
              {"role":"partition-table","offset":32768,"size":3072,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileName":"esp32_marauder_installer_v1_14_1_20260801_v6_1.partition-table.bin"},
              {"role":"ota-data","offset":57344,"size":8192,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fileName":"esp32_marauder_installer_v1_14_1_20260801_v6_1.ota-data.bin"}
            ]}}
          }]
        }
        """#.utf8)
    }

    private func c5ManifestData(
        bootloaderOffset: Int = 0x2000,
        partitionOffset: Int = 0x8000
    ) -> Data {
        Data(#"""
        {
          "schemaVersion": 1,
          "channel": "stable",
          "kind": "esp32-marauder-installer-release",
          "metadataStatus": "authoritative",
          "sourceRepository": "justcallmekoko/ESP32Marauder",
          "version": "v1.14.1",
          "targets": [{
            "id": "esp32-c5-devkitc-1",
            "displayName": "ESP32-C5-DevKitC-1",
            "chipFamily": "ESP32-C5",
            "esptoolChip": "esp32c5",
            "assetSuffix": "esp32c5devkitc1",
            "flash": {"factory": {"segments": [
              {"role":"bootloader","offset":\#(bootloaderOffset),"size":20784,"sha256":"f0cc3970dbf6001eb398e589244047f0731acbc0ded1ccfa952cd7559c083b13","fileName":"esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.bootloader.bin"},
              {"role":"partition-table","offset":\#(partitionOffset),"size":3072,"sha256":"0a8b5720e7b77ff11f1462458c3a509dee79224e5279898f26d6a2e3ae0517b7","fileName":"esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.partition-table.bin"},
              {"role":"ota-data","offset":57344,"size":8192,"sha256":"f94c5d786a7a8fab06ac5d10e33bf37711a6697636dc037559ea19cc410a17f0","fileName":"esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.ota-data.bin"},
              {"role":"application","offset":65536,"size":1812752,"sha256":"de4a9d83d951db49829ee1e061689ba8b92daba7cf089622a7ad163100d39f84","fileName":"esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.bin"}
            ]}}
          }]
        }
        """#.utf8)
    }

    private var c5RequiredAssetSizes: [String: Int] {
        [
            "esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.partition-table.bin": 3_072,
            "esp32_marauder_v1_14_1_20260801_esp32c5devkitc1.bin": 1_812_752,
        ]
    }

    private var c5ReleaseAssetSHA256: [String: String] {
        [
            "esp32_marauder_installer_v1_14_1_20260801_esp32c5devkitc1.partition-table.bin":
                "0a8b5720e7b77ff11f1462458c3a509dee79224e5279898f26d6a2e3ae0517b7",
            "esp32_marauder_v1_14_1_20260801_esp32c5devkitc1.bin":
                "cd278319c3850fb615cf8fe432055c38c30cbaf59a80de7aa4d0c38aa928e95b",
        ]
    }

    private func board(folder: String, version: String, key: String) -> ESP32Updater.Board {
        ESP32Updater.Board(
            folder: folder,
            base: "module_one_\(key)_\(version.replacingOccurrences(of: ".", with: "_"))",
            display: "module_one_\(key)",
            key: key,
            currentVersion: version,
            appName: "esp32_marauder_\(version)_\(key)_0x10000.bin",
            bootFiles: ["bootloader_0x1000.bin", "partitions_0x8000.bin"])
    }
}
