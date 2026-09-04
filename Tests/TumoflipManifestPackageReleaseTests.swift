import Foundation
import XCTest
@testable import UnleashedCompanion

final class TumoflipManifestPackageReleaseTests: XCTestCase {
    func testDecodesAndValidatesPackageOnlyRevisionMetadata() throws {
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: packageRelease))

        try manifest.validate()
        XCTAssertEqual(manifest.packageRelease?.type, "package-only")
        XCTAssertEqual(
            manifest.packageRelease?.sourceCommit,
            "1b0eba79c6c02a7c3307db604233aefe76cdd042"
        )
        XCTAssertEqual(manifest.packageRelease?.targetReleaseTag, "v1.0.4")
        XCTAssertEqual(manifest.packageRelease?.firmwareFlashUnchanged, true)
    }

    func testLegacyManifestWithoutPackageRevisionStillDecodes() throws {
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: nil))

        try manifest.validate()
        XCTAssertNil(manifest.packageRelease)
    }

    func testDecodesIndependentCatalogRevision() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 1,
              "catalog_release_tag": "fw-packages-dev-001"
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))

        try manifest.validate()
        XCTAssertTrue(manifest.packageRelease?.isIndependentCatalog == true)
        XCTAssertEqual(manifest.packageRelease?.catalogChannel, "dev")
        XCTAssertEqual(manifest.packageRelease?.catalogRevision, 1)
        XCTAssertEqual(manifest.packageRelease?.catalogReleaseTag, "fw-packages-dev-001")
    }

    func testIndependentCatalogScopesStatusAndInstallToAutomationDelta() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 8,
              "catalog_release_tag": "fw-packages-dev-008",
              "catalog_install_scope": "delta",
              "catalog_modified_targets": ["apps/esp.fap"],
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        let managed = manifest.packageManagedManifest()
        XCTAssertEqual(managed.packages["base"]?.map(\.source), ["apps/esp.fap"])
        XCTAssertEqual(managed.cleanup.map(\.canonical), ["/ext/apps/esp.fap"])
    }

    func testIndependentCompatibilityDisplayIgnoresHistoricalSourceFirmwareVersion() throws {
        let independent = packageRelease
            .replacingOccurrences(
                of: "\"source_firmware_version\": \"t-dev-004-014\"",
                with: "\"source_firmware_version\": \"t-dev-004-015\""
            )
            .replacingOccurrences(
                of: "\"firmware_flash_unchanged\": true",
                with: """
                "firmware_flash_unchanged": true,
                  "catalog_channel": "dev",
                  "catalog_revision": 8,
                  "catalog_release_tag": "fw-packages-dev-008",
                  "catalog_install_scope": "delta",
                  "catalog_modified_targets": ["apps/esp.fap"],
                  "overlay_targets": ["apps/esp.fap"]
                """
            )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        XCTAssertEqual(
            manifest.independentCompatibilityDisplay,
            "Tumoflip Dev · API 88.0 · f7"
        )
        XCTAssertFalse(
            manifest.independentCompatibilityDisplay?.contains("t-dev-004-015") == true
        )
    }

    func testIndependentDeltaSeparatesFirmwareOwnedBaselineFromInstallSurface() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 8,
              "catalog_release_tag": "fw-packages-dev-008",
              "catalog_install_scope": "delta",
              "catalog_modified_targets": ["apps/esp.fap"],
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        let surface = manifest.packageSurface()
        XCTAssertEqual(surface.managed.packages["base"]?.map(\.source), ["apps/esp.fap"])
        XCTAssertEqual(surface.firmwareOwnedFiles(in: "base").map(\.source), ["apps/base.fap"])
        XCTAssertEqual(surface.firmwareOwnedFileCount, 1)
        XCTAssertTrue(surface.firmwareOwnedFiles(in: "arf").isEmpty)
    }

    func testIndependentBaselineManagesNoFilesAndExposesReferenceSurface() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "stable",
              "catalog_revision": 4,
              "catalog_release_tag": "fw-packages-stable-004",
              "catalog_install_scope": "baseline",
              "catalog_modified_targets": [],
              "overlay_targets": [],
              "compatible_releases": []
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        XCTAssertTrue(manifest.isIndependentBaselineCatalog)
        XCTAssertTrue(manifest.isReferenceOnlyCatalog)
        XCTAssertTrue(manifest.packageManagedManifest().packages.values.allSatisfy(\.isEmpty))
        XCTAssertEqual(manifest.packageSurface().firmwareOwnedFileCount, 2)
    }

    func testIndependentDeltaWithOverlayIsNotReferenceOnly() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 8,
              "catalog_release_tag": "fw-packages-dev-008",
              "catalog_install_scope": "delta",
              "catalog_modified_targets": ["apps/esp.fap"],
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        XCTAssertFalse(manifest.isReferenceOnlyCatalog)
    }

    func testIndependentDeltaAcceptsCumulativeModifiedTargets() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 9,
              "catalog_release_tag": "fw-packages-dev-009",
              "catalog_install_scope": "delta",
              "catalog_modified_targets": ["apps/base.fap", "apps/esp.fap"],
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))

        XCTAssertNoThrow(try manifest.validate())
        XCTAssertEqual(
            manifest.packageManagedManifest().packages["base"]?.map(\.source),
            ["apps/base.fap", "apps/esp.fap"]
        )
    }

    func testQuacDevDeltaPromotesCanonicalTargetToManagedSurface() throws {
        let manifest = try TumoflipManifest.decode(quacMigrationFixture())

        try manifest.validate()

        let surface = manifest.packageSurface()
        let quac = try XCTUnwrap(surface.managed.packages["base"]?.only)
        XCTAssertEqual(quac.source, "apps/Tools/quac.fap")
        XCTAssertEqual(quac.target, "/ext/apps/Tools/quac.fap")
        XCTAssertFalse(quac.preserveExisting)
        XCTAssertEqual(
            manifest.packageRelease?.catalogModifiedTargets,
            ["apps/Tools/quac.fap"]
        )
        XCTAssertEqual(
            manifest.packageRelease?.overlayTargets,
            ["apps/Tools/quac.fap"]
        )
        XCTAssertTrue(surface.firmwareOwnedFiles(in: "base").isEmpty)
        XCTAssertTrue(surface.managed.cleanup.isEmpty)
        XCTAssertFalse(manifest.isReferenceOnlyCatalog)

        let plan = try TumoflipInstallPlan.make(
            manifest: surface.managed,
            groups: ["base"]
        ).installationOnly
        XCTAssertEqual(plan.files.map(\.target), ["/ext/apps/Tools/quac.fap"])
        XCTAssertTrue(plan.cleanup.isEmpty)

        let protectedDataRoot = "/ext/apps_data/quac"
        let packageFiles = manifest.packages.values.flatMap { $0 }
        XCTAssertFalse(packageFiles.contains {
            $0.source == "apps_data/quac" || $0.source.hasPrefix("apps_data/quac/")
        })
        XCTAssertFalse(packageFiles.contains {
            $0.target == protectedDataRoot || $0.target.hasPrefix(protectedDataRoot + "/")
        })
        XCTAssertFalse(manifest.cleanup.contains {
            [$0.canonical, $0.legacy].contains {
                $0 == protectedDataRoot || $0.hasPrefix(protectedDataRoot + "/")
            }
        })
    }

    func testQuacDevDeltaRejectsCaseChangedManagedSource() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: quacMigrationFixture()) as? [String: Any]
        )
        var packageRelease = try XCTUnwrap(object["package_release"] as? [String: Any])
        packageRelease["catalog_modified_targets"] = ["apps/tools/quac.fap"]
        packageRelease["overlay_targets"] = ["apps/tools/quac.fap"]
        object["package_release"] = packageRelease
        let manifest = try TumoflipManifest.decode(
            JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? TumoflipManifestError,
                .invalidPackageRelease("quac-fw-package-migration")
            )
        }
    }

    func testIndependentDeltaRejectsOverlayOutsideCumulativeTargets() throws {
        let invalid = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 9,
              "catalog_release_tag": "fw-packages-dev-009",
              "catalog_install_scope": "delta",
              "catalog_modified_targets": ["apps/base.fap"],
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: invalid))

        XCTAssertThrowsError(try manifest.validate())
    }

    func testLegacyManifestIsNotReferenceOnly() throws {
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: nil))

        XCTAssertFalse(manifest.isReferenceOnlyCatalog)
    }

    func testOlderCatalogUsesOverlayAllowlistAndNeverExposesBaseline() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 4,
              "catalog_release_tag": "fw-packages-dev-004",
              "overlay_targets": ["apps/esp.fap"]
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        let managed = manifest.packageManagedManifest()
        XCTAssertEqual(managed.packages["base"]?.map(\.source), ["apps/esp.fap"])
    }

    func testMismatchedCatalogWithoutAllowlistFailsClosedToNoFiles() throws {
        let independent = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 1,
              "catalog_release_tag": "fw-packages-dev-001"
            """
        )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
        try manifest.validate()

        let managed = manifest.packageManagedManifest()
        XCTAssertTrue(managed.packages.values.allSatisfy(\.isEmpty))
        XCTAssertTrue(managed.cleanup.isEmpty)
    }

    func testProducerFirmwareSnapshotFixtureExposesCompleteManifest() throws {
        let manifest = try TumoflipManifest.decode(
            fixture(packageRelease: firmwareSnapshotPackageRelease(explicitScope: true))
        )

        try manifest.validate()
        XCTAssertTrue(manifest.isFirmwareSnapshotCatalog)
        XCTAssertEqual(manifest.packageManagedManifest().packages["base"]?.count, 2)
        XCTAssertEqual(manifest.packageManagedManifest().cleanup.count, 2)
    }

    func testStable002And003LegacySnapshotShapeRemainsInstallable() throws {
        let manifest = try TumoflipManifest.decode(
            fixture(packageRelease: firmwareSnapshotPackageRelease(explicitScope: false))
        )

        try manifest.validate()
        XCTAssertTrue(manifest.isFirmwareSnapshotCatalog)
        XCTAssertEqual(manifest.packageManagedManifest().packages["base"]?.count, 2)
    }

    func testExplicitEmptyDeltaCannotMasqueradeAsSnapshot() throws {
        let invalid = firmwareSnapshotPackageRelease(explicitScope: true)
            .replacingOccurrences(
                of: "\"catalog_install_scope\": \"firmwareSnapshot\"",
                with: "\"catalog_install_scope\": \"delta\""
            )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: invalid))

        XCTAssertThrowsError(try manifest.validate())
    }

    func testExplicitSnapshotRequiresExactFirmwareEvidence() throws {
        let invalid = firmwareSnapshotPackageRelease(explicitScope: true)
            .replacingOccurrences(
                of: "\"target_firmware_commit\": \"\(String(repeating: "1", count: 40))\"",
                with: "\"target_firmware_commit\": \"\(String(repeating: "2", count: 40))\""
            )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: invalid))

        XCTAssertThrowsError(try manifest.validate())
    }

    func testRejectsUnknownOrNonCanonicalCatalogDeltaSource() throws {
        for source in ["apps/missing.fap", "apps/../esp.fap", "/apps/esp.fap"] {
            let independent = packageRelease.replacingOccurrences(
                of: "\"firmware_flash_unchanged\": true",
                with: """
                "firmware_flash_unchanged": true,
                  "catalog_channel": "dev",
                  "catalog_revision": 8,
                  "catalog_release_tag": "fw-packages-dev-008",
                  "catalog_modified_targets": ["\(source)"],
                  "overlay_targets": ["apps/esp.fap"]
                """
            )
            let manifest = try TumoflipManifest.decode(fixture(packageRelease: independent))
            XCTAssertThrowsError(try manifest.validate(), "source=\(source)")
        }
    }

    func testRejectsPartialOrMismatchedIndependentCatalogMetadata() throws {
        let partial = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: "\"firmware_flash_unchanged\": true, \"catalog_channel\": \"dev\""
        )
        XCTAssertThrowsError(
            try TumoflipManifest.decode(fixture(packageRelease: partial)).validate()
        )

        let wrongTag = packageRelease.replacingOccurrences(
            of: "\"firmware_flash_unchanged\": true",
            with: """
            "firmware_flash_unchanged": true,
              "catalog_channel": "dev",
              "catalog_revision": 1,
              "catalog_release_tag": "fw-packages-dev-999"
            """
        )
        XCTAssertThrowsError(
            try TumoflipManifest.decode(fixture(packageRelease: wrongTag)).validate()
        )
    }

    func testRejectsDirtyOrFirmwareChangingPackageOverlay() throws {
        let unsafe = packageRelease
            .replacingOccurrences(of: "\"source_dirty\": false", with: "\"source_dirty\": true")
            .replacingOccurrences(
                of: "\"firmware_flash_unchanged\": true",
                with: "\"firmware_flash_unchanged\": false"
            )
        let manifest = try TumoflipManifest.decode(fixture(packageRelease: unsafe))

        XCTAssertThrowsError(try manifest.validate()) { error in
            guard case TumoflipManifestError.invalidPackageRelease = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private var packageRelease: String {
        """
        "package_release": {
          "id": "t-flppr-fw-004-packages-1b0eba79c",
          "type": "package-only",
          "source_commit": "1b0eba79c6c02a7c3307db604233aefe76cdd042",
          "source_dirty": false,
          "source_firmware_version": "t-dev-004-014",
          "target_release_tag": "v1.0.4",
          "firmware_flash_unchanged": true
        },
        """
    }

    /// Consumer fixture matching the native publisher's package_release payload.
    /// Stable002/003 are the same shape without `catalog_install_scope`.
    private func firmwareSnapshotPackageRelease(explicitScope: Bool) -> String {
        let commit = String(repeating: "1", count: 40)
        let scope = explicitScope
            ? "\"catalog_install_scope\": \"firmwareSnapshot\","
            : ""
        return """
        "package_release": {
          "id": "fw-packages-stable-003",
          "type": "package-only",
          "source_commit": "\(commit)",
          "source_dirty": false,
          "source_firmware_version": "t-flppr-fw-004",
          "target_release_tag": "v1.0.4",
          "target_release_id": "\(String(repeating: "e", count: 64))",
          "target_source_commit": "\(commit)",
          "target_firmware_commit": "\(commit)",
          "firmware_flash_unchanged": true,
          "catalog_channel": "stable",
          "catalog_revision": 3,
          "catalog_release_tag": "fw-packages-stable-003",
          \(scope)
          "overlay_targets": [],
          "compatible_releases": []
        },
        """
    }

    private func fixture(packageRelease: String?) -> Data {
        Data(
            """
            {
              "schema": 2,
              "release_id": "\(String(repeating: "a", count: 64))",
              "firmware": {
                "api": "88.0",
                "name": "tumoflip",
                "version": "t-flppr-fw-004",
                "target": 7
              },
              \(packageRelease ?? "")
              "artifacts": {},
              "packages": {
                "base": [
                  {
                    "bytes": 1,
                    "sha256": "\(String(repeating: "b", count: 64))",
                    "md5": "\(String(repeating: "b", count: 32))",
                    "source": "apps/base.fap",
                    "target": "/ext/apps/base.fap"
                  },
                  {
                    "bytes": 1,
                    "sha256": "\(String(repeating: "c", count: 64))",
                    "md5": "\(String(repeating: "c", count: 32))",
                    "source": "apps/esp.fap",
                    "target": "/ext/apps/esp.fap"
                  }
                ],
                "arf": [],
                "module_one": [],
                "protocol_packs": []
              },
              "cleanup": [
                {"canonical": "/ext/apps/base.fap", "legacy": "/ext/apps/old-base.fap"},
                {"canonical": "/ext/apps/esp.fap", "legacy": "/ext/apps/old-esp.fap"}
              ]
            }
            """.utf8
        )
    }

    private func quacMigrationFixture() throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quac-fw-package-migration.json")
        return try Data(contentsOf: fixtureURL)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
