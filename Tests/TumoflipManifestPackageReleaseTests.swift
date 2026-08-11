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
                "base": [],
                "arf": [],
                "module_one": [],
                "protocol_packs": []
              },
              "cleanup": []
            }
            """.utf8
        )
    }
}
