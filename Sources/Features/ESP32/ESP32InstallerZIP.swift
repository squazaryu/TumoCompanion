import CryptoKit
import Foundation
import ZIPFoundation

enum ESP32InstallerZIPError: LocalizedError, Equatable {
    case carrierMismatch
    case unsafeEntry(String)
    case duplicateEntry(String)
    case oversized
    case missingManifest
    case unexpectedEntries
    case segmentMismatch(String)

    var errorDescription: String? {
        switch self {
        case .carrierMismatch: return "Installer ZIP does not match its release digest or size."
        case .unsafeEntry(let name): return "Unsafe installer ZIP entry: \(name)."
        case .duplicateEntry(let name): return "Duplicate installer ZIP entry: \(name)."
        case .oversized: return "Installer ZIP exceeds the allowed size."
        case .missingManifest: return "Installer ZIP has no firmware manifest."
        case .unexpectedEntries: return "Installer ZIP contents do not match its manifest."
        case .segmentMismatch(let name): return "Installer segment failed verification: \(name)."
        }
    }
}

/// Inspects an upstream installer archive without extracting anything to disk.
/// The full entry inventory must match the authoritative manifest before any
/// board-specific data can be staged on the Flipper.
struct ESP32InstallerZIP {
    private static let maxArchiveBytes = 64 * 1024 * 1024
    private static let maxEntryBytes: UInt64 = 16 * 1024 * 1024
    private static let maxExpandedBytes: UInt64 = 128 * 1024 * 1024
    private static let maxEntryCount = 256
    private static let manifestName = "firmware-manifest.json"

    private let archive: Archive
    private let entries: [String: Entry]
    let manifestData: Data

    init(data: Data, expectedSize: Int, expectedSHA256: String) throws {
        guard expectedSize > 0,
              expectedSize <= Self.maxArchiveBytes,
              data.count == expectedSize,
              Self.validSHA(expectedSHA256),
              Self.sha256(data).caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            throw ESP32InstallerZIPError.carrierMismatch
        }

        let archive: Archive
        do { archive = try Archive(data: data, accessMode: .read) }
        catch { throw ESP32InstallerZIPError.carrierMismatch }

        var entries: [String: Entry] = [:]
        var expandedBytes: UInt64 = 0
        for entry in archive {
            guard entry.type == .file, Self.safeName(entry.path) else {
                throw ESP32InstallerZIPError.unsafeEntry(entry.path)
            }
            guard entries[entry.path] == nil else {
                throw ESP32InstallerZIPError.duplicateEntry(entry.path)
            }
            guard entry.uncompressedSize <= Self.maxEntryBytes,
                  expandedBytes <= Self.maxExpandedBytes - entry.uncompressedSize,
                  entries.count < Self.maxEntryCount else {
                throw ESP32InstallerZIPError.oversized
            }
            expandedBytes += entry.uncompressedSize
            entries[entry.path] = entry
        }
        guard let manifest = entries[Self.manifestName] else {
            throw ESP32InstallerZIPError.missingManifest
        }
        guard manifest.uncompressedSize <= 1024 * 1024 else {
            throw ESP32InstallerZIPError.oversized
        }

        self.archive = archive
        self.entries = entries
        self.manifestData = try Self.extract(manifest, from: archive)
    }

    func verifyEntries(expectedSegmentNames: Set<String>) throws {
        guard !expectedSegmentNames.isEmpty,
              expectedSegmentNames.count < Self.maxEntryCount,
              expectedSegmentNames.allSatisfy(Self.safeName),
              Set(entries.keys) == expectedSegmentNames.union([Self.manifestName]) else {
            throw ESP32InstallerZIPError.unexpectedEntries
        }
    }

    func verifiedData(name: String, size: Int, sha256: String) throws -> Data {
        guard name != Self.manifestName,
              size > 0,
              size <= Int(Self.maxEntryBytes),
              Self.validSHA(sha256),
              let entry = entries[name],
              entry.uncompressedSize == UInt64(size) else {
            throw ESP32InstallerZIPError.segmentMismatch(name)
        }
        let data = try Self.extract(entry, from: archive)
        guard data.count == size,
              Self.sha256(data).caseInsensitiveCompare(sha256) == .orderedSame else {
            throw ESP32InstallerZIPError.segmentMismatch(name)
        }
        return data
    }

    private static func safeName(_ name: String) -> Bool {
        if name == manifestName { return true }
        guard name.hasPrefix("esp32_marauder_installer_"),
              name.hasSuffix(".bin"),
              name.utf8.count <= 128,
              !name.contains("..") else { return false }
        return name.utf8.allSatisfy { byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func validSHA(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }
}
