import CryptoKit
import Foundation
import XCTest
import ZIPFoundation
@testable import UnleashedCompanion

final class ESP32InstallerZIPTests: XCTestCase {
    private let segmentName = "esp32_marauder_installer_v1_17_0_20260916_v6_1.bin"

    func testVerifiedArchiveExposesOnlySelectedSegments() throws {
        let manifest = Data("{\"schemaVersion\":1}".utf8)
        let image = Data("owned module image".utf8)
        let data = try makeArchive([
            "firmware-manifest.json": manifest,
            segmentName: image,
        ])

        let zip = try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data))
        try zip.verifyEntries(expectedSegmentNames: [segmentName])
        XCTAssertEqual(zip.manifestData, manifest)
        XCTAssertEqual(
            try zip.verifiedData(name: segmentName, size: image.count, sha256: sha256(image)),
            image)
    }

    func testCarrierDigestAndSegmentHashMustMatch() throws {
        let image = Data("image".utf8)
        let data = try makeArchive([
            "firmware-manifest.json": Data("{}".utf8),
            segmentName: image,
        ])
        XCTAssertThrowsError(try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: String(repeating: "0", count: 64)))
        let zip = try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data))
        XCTAssertThrowsError(try zip.verifiedData(
            name: segmentName, size: image.count, sha256: String(repeating: "0", count: 64)))
    }

    func testUnexpectedOrNestedEntryFailsClosed() throws {
        let data = try makeArchive([
            "firmware-manifest.json": Data("{}".utf8),
            segmentName: Data("image".utf8),
            "nested/extra.bin": Data("other".utf8),
        ])
        XCTAssertThrowsError(try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data)))
    }

    func testMissingDeclaredSegmentFailsClosed() throws {
        let data = try makeArchive([
            "firmware-manifest.json": Data("{}".utf8),
            segmentName: Data("image".utf8),
        ])
        let zip = try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data))
        XCTAssertThrowsError(try zip.verifyEntries(expectedSegmentNames: [
            segmentName, "esp32_marauder_installer_v1_17_0_20260916_v6_1.bootloader.bin",
        ]))
    }

    private func makeArchive(_ files: [String: Data]) throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("esp32-installer-test-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        for (name, bytes) in files.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(bytes.count),
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = Int(position)
                    return bytes.subdata(in: start..<min(start + size, bytes.count))
                })
        }
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
