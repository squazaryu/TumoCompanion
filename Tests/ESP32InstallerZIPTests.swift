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

    func testEncryptedCentralDirectoryEntryFailsClosed() throws {
        var data = try makeArchive([
            "firmware-manifest.json": Data("{}".utf8),
            segmentName: Data("image".utf8),
        ])
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let header = data.indices.first { index in
            index + 10 < data.count && Array(data[index..<(index + 4)]) == signature
        }
        let offset = try XCTUnwrap(header)
        data[offset + 8] |= 1 // ZIP general-purpose encrypted bit.

        XCTAssertThrowsError(try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data)))
    }

    func testSymlinkEntryFailsClosed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("esp32-installer-symlink-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        let target = Data("../escape".utf8)
        try archive.addEntry(
            with: segmentName, type: .symlink, uncompressedSize: Int64(target.count),
            provider: { position, size in
                let start = Int(position)
                return target.subdata(in: start..<min(start + size, target.count))
            })
        try archive.addEntry(
            with: "firmware-manifest.json", type: .file,
            uncompressedSize: Int64(2),
            provider: { position, size in
                let value = Data("{}".utf8)
                let start = Int(position)
                return value.subdata(in: start..<min(start + size, value.count))
            })
        let data = try Data(contentsOf: url)
        XCTAssertThrowsError(try ESP32InstallerZIP(
            data: data, expectedSize: data.count, expectedSHA256: sha256(data)))
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
