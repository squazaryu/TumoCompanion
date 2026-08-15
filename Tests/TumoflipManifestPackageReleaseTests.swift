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
}
