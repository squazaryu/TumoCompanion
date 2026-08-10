import CryptoKit
import Foundation

struct ESP32FlashPackageManifest: Codable, Equatable {
    struct Board: Codable, Equatable {
        let key: String
        let modelId: String
        let displayName: String
        let chipFamily: String
    }

    struct Firmware: Codable, Equatable {
        let version: String
        let sourceRepository: String
        let sourceRelease: String
    }

    struct Recipe: Codable, Equatable {
        let id: String
        let status: String
    }

    struct Segment: Codable, Equatable {
        let role: String
        let fileName: String
        let offset: Int
        let size: Int
        let sha256: String
        let md5: String
    }

    struct CreatedBy: Codable, Equatable {
        let application: String
        let version: String
    }

    static let fileName = "tumoflip-flash-package.json"
    static let currentSchemaVersion = 1
    static let currentPackageKind = "tumoflip-esp32-flash-package"

    let schemaVersion: Int
    let packageKind: String
    let board: Board
    let firmware: Firmware
    let recipe: Recipe
    let erasePolicy: String
    let segments: [Segment]
    let createdAt: String
    let createdBy: CreatedBy

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ESP32FlashPackageError.unsupportedSchema(schemaVersion)
        }
        guard packageKind == Self.currentPackageKind else {
            throw ESP32FlashPackageError.invalidPackageKind(packageKind)
        }
        guard Self.isIdentifier(board.key),
              Self.isIdentifier(board.modelId),
              Self.isIdentifier(board.chipFamily),
              !board.displayName.isEmpty else {
            throw ESP32FlashPackageError.invalidBoard(board.key)
        }
        let expectedRelease = "https://github.com/\(firmware.sourceRepository)/releases/tag/\(firmware.version)"
        guard !firmware.version.isEmpty,
              firmware.sourceRepository == ESP32Updater.repo,
              let releaseURL = URL(string: firmware.sourceRelease),
              releaseURL.scheme == "https",
              releaseURL.host == "github.com",
              firmware.sourceRelease == expectedRelease else {
            throw ESP32FlashPackageError.invalidSource
        }
        guard erasePolicy == "segments" else {
            throw ESP32FlashPackageError.invalidErasePolicy(erasePolicy)
        }
        guard Self.isISO8601(createdAt),
              !createdBy.application.isEmpty,
              !createdBy.version.isEmpty else {
            throw ESP32FlashPackageError.invalidCreationMetadata
        }

        let c5 = board.key == "esp32c5devkitc1"
        let expectedRoles = c5
            ? Set(["bootloader", "partition-table", "application"])
            : Set(["bootloader", "partition-table", "ota-data", "application"])
        let roles = Set(segments.map(\.role))
        let names = Set(segments.map(\.fileName))
        let offsets = Set(segments.map(\.offset))
        guard segments.count == expectedRoles.count,
              roles == expectedRoles,
              names.count == segments.count,
              offsets.count == segments.count,
              segments.map(\.offset) == segments.map(\.offset).sorted() else {
            throw ESP32FlashPackageError.invalidSegments(board.key)
        }

        for segment in segments {
            guard Self.isRelativeFileName(segment.fileName),
                  segment.fileName.hasSuffix(".bin"),
                  segment.offset >= 0,
                  segment.size > 0,
                  Self.isHexDigest(segment.sha256, length: 64),
                  Self.isHexDigest(segment.md5, length: 32),
                  segment.sha256 == segment.sha256.lowercased(),
                  segment.md5 == segment.md5.lowercased() else {
                throw ESP32FlashPackageError.invalidSegment(segment.fileName)
            }
        }

        if c5 {
            let expectedOffsets = [
                "bootloader": 0x2000,
                "partition-table": 0x8000,
                "application": 0x10000,
            ]
            let bootloader = segments.first { $0.role == "bootloader" }
            guard board.chipFamily == "esp32c5",
                  recipe.id == "c5-compat-v1",
                  recipe.status == "hardware-accepted",
                  bootloader?.size == 20_464,
                  bootloader?.sha256 ==
                    "3e2b92a74cf406745dddc88ecb5193fd446f4b269b96d2b9991d84f41c810611",
                  segments.allSatisfy({ expectedOffsets[$0.role] == $0.offset }) else {
                throw ESP32FlashPackageError.invalidSegments(board.key)
            }
        } else {
            guard recipe.id == "upstream-factory-v1",
                  recipe.status == "authoritative" else {
                throw ESP32FlashPackageError.invalidRecipe(recipe.status)
            }
            if board.key == "v6_1" {
                let expectedOffsets = [
                    "bootloader": 0x1000,
                    "partition-table": 0x8000,
                    "ota-data": 0xe000,
                    "application": 0x10000,
                ]
                guard board.chipFamily == "esp32",
                      segments.allSatisfy({ expectedOffsets[$0.role] == $0.offset }) else {
                    throw ESP32FlashPackageError.invalidSegments(board.key)
                }
            }
        }
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let valid = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(valid.contains)
    }

    private static func isRelativeFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private static func isHexDigest(_ value: String, length: Int) -> Bool {
        value.count == length && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains)
    }

    private static func isISO8601(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        return ISO8601DateFormatter().date(from: value) != nil
    }
}

enum ESP32FlashPackageError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case invalidPackageKind(String)
    case invalidBoard(String)
    case invalidSource
    case invalidErasePolicy(String)
    case invalidRecipe(String)
    case invalidCreationMetadata
    case invalidSegments(String)
    case invalidSegment(String)
    case unexpectedStagingContents
    case manifestReadbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported flash package schema \(version)."
        case .invalidPackageKind(let kind): return "Unexpected flash package kind: \(kind)."
        case .invalidBoard(let key): return "Invalid flash package board: \(key)."
        case .invalidSource: return "Invalid flash package source release."
        case .invalidErasePolicy(let policy): return "Unsupported erase policy: \(policy)."
        case .invalidRecipe(let status): return "Unsupported package recipe status: \(status)."
        case .invalidCreationMetadata: return "Flash package creation metadata is incomplete."
        case .invalidSegments(let key): return "Flash package layout for \(key) is incomplete or ambiguous."
        case .invalidSegment(let name): return "Invalid flash package segment: \(name)."
        case .unexpectedStagingContents: return "Flash package staging directory contains unexpected files."
        case .manifestReadbackFailed: return "Couldn't verify the flash package manifest after writing it."
        }
    }
}

enum ESP32PackageTransaction {
    static func replaceAtomically(
        storage: any DeviceFileStore,
        target: String,
        staging: String,
        archiveDirectory: String,
        replacementID: String = UUID().uuidString.lowercased()
    ) async throws {
        let hadTarget = await storage.exists(target)
        let targetName = target.split(separator: "/").last.map(String.init) ?? target
        let backup = "\(archiveDirectory)/.\(targetName).replacement-\(replacementID)"

        if hadTarget {
            try await storage.makeDirectory(archiveDirectory)
            try await storage.move(target, to: backup)
        }
        do {
            try await storage.move(staging, to: target)
        } catch {
            if hadTarget {
                do {
                    try await storage.move(backup, to: target)
                } catch let rollbackError {
                    throw CocoaError(.fileWriteUnknown, userInfo: [
                        NSLocalizedDescriptionKey:
                            "Package replacement failed and rollback failed: \(rollbackError.localizedDescription)"
                    ])
                }
            }
            throw error
        }
        if hadTarget {
            try? await storage.delete(backup, recursive: true)
        }
    }
}

enum ESP32PackageCommitMarker {
    static func writeManifestLast(
        storage: any DeviceFileStore,
        directory: String,
        manifest: ESP32FlashPackageManifest
    ) async throws {
        let manifestData = try manifest.encoded()
        let binaryNames = Set(manifest.segments.map(\.fileName))
        try await verifyContents(storage: storage, directory: directory, expectedNames: binaryNames)

        let path = "\(directory)/\(ESP32FlashPackageManifest.fileName)"
        try await storage.write(path, data: manifestData)
        let expectedMD5 = Insecure.MD5.hash(data: manifestData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard await storage.md5(path) == expectedMD5 else {
            throw ESP32FlashPackageError.manifestReadbackFailed
        }

        try await verifyContents(
            storage: storage,
            directory: directory,
            expectedNames: binaryNames.union([ESP32FlashPackageManifest.fileName]))
    }

    private static func verifyContents(
        storage: any DeviceFileStore,
        directory: String,
        expectedNames: Set<String>
    ) async throws {
        let contents = try await storage.list(directory)
        guard contents.allSatisfy({ !$0.isDirectory }),
              Set(contents.map(\.name)) == expectedNames else {
            throw ESP32FlashPackageError.unexpectedStagingContents
        }
    }
}
