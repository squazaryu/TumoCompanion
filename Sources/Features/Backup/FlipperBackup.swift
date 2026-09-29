import Foundation
import CryptoKit
import Combine
import ZIPFoundation

@MainActor
protocol FlipperBackupStorage: AnyObject {
    func list(_ path: String) async throws -> [FlipperFile]
    func read(_ path: String) async throws -> Data
    func checkedMD5(_ path: String, timeout: TimeInterval) async throws -> String?
    func makeDirectory(_ path: String) async throws
    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)?
    ) async throws
}

extension FlipperStorage: FlipperBackupStorage {}

struct FlipperBackupReceipt {
    let url: URL
    let files: Int
    let bytes: Int64
}

private enum FlipperBackupError: LocalizedError {
    case invalidPath(String)
    case noFiles
    case archiveCreation
    case incompleteRead(String)
    case checksumMismatch(String)
    case invalidArchive(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path): return "Unsafe backup path: \(path)"
        case .noFiles: return "No files were found in the selected folders."
        case .archiveCreation: return "Couldn't create the backup archive."
        case .incompleteRead(let path): return "Incomplete read: \(path)"
        case .checksumMismatch(let path): return "Checksum mismatch: \(path)"
        case .invalidArchive(let reason): return "Invalid backup archive: \(reason)"
        }
    }
}

private struct FlipperBackupManifest: Codable {
    struct File: Codable {
        let path: String
        let size: Int
        let sha256: String
    }

    let schema: Int
    let files: [File]
}

/// Backs up selected Flipper SD folders to a timestamped .zip in the app's
/// Documents (over BLE), and restores a .zip back to the Flipper.
@MainActor
final class FlipperBackup: ObservableObject {
    @Published var running = false
    @Published var status: String?
    @Published var backups: [URL] = []

    private static let manifestName = ".tumoflip-backup.json"
    private static let maxFileBytes: UInt64 = 64 * 1024 * 1024
    private static let maxArchiveBytes: UInt64 = 512 * 1024 * 1024
    private let storage: any FlipperBackupStorage
    private let directory: URL

    convenience init() {
        self.init(storage: FlipperStorage(), directory: Self.dir)
    }

    init(storage: any FlipperBackupStorage, directory: URL) {
        self.storage = storage
        self.directory = directory
    }

    /// Top-level folders excluded from the default selection (large / re-installable).
    static let excludedDefaults: Set<String> = [
        "apps", "apps_assets", "apps_data", "apps_manifests", "update"
    ]

    static var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func refreshBackups() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        backups = urls.filter { $0.pathExtension == "zip" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    /// Top-level folders on the SD, for the selection UI.
    func topLevelFolders() async -> [String] {
        (try? await requiredTopLevelFolders()) ?? []
    }

    func requiredTopLevelFolders() async throws -> [String] {
        let entries = try await storage.list("/ext")
        return entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") }.map(\.name).sorted()
    }

    @discardableResult
    func backup(folders: [String], stamp: String) async throws -> FlipperBackupReceipt {
        running = true
        status = "Scanning…"
        defer { running = false }

        do {
            guard stamp.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else {
                throw FlipperBackupError.invalidPath(stamp)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            #endif
            var files: [FlipperFile] = []
            for folder in Set(folders).sorted() {
                guard !folder.isEmpty, !folder.contains("/"), folder != ".", folder != ".." else {
                    throw FlipperBackupError.invalidPath(folder)
                }
                try await collect("/ext/\(folder)", into: &files, depth: 0)
            }
            guard !files.isEmpty else { throw FlipperBackupError.noFiles }
            guard files.reduce(UInt64(0), { $0 + UInt64($1.size) }) <= Self.maxArchiveBytes else {
                throw FlipperBackupError.invalidArchive("selected files are too large")
            }

            let identifier = UUID().uuidString
            let staging = directory.appendingPathComponent(".flipper-\(identifier).incomplete")
            let final = directory.appendingPathComponent(
                "flipper-\(stamp)-\(identifier.prefix(8)).zip")
            let scratch = directory.appendingPathComponent(".flipper-\(identifier)-scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: scratch)
                try? FileManager.default.removeItem(at: staging)
            }

            let manifest = try await writeArchive(at: staging, scratch: scratch, files: files)
            try Task.checkCancellation()
            guard try Self.validateArchive(at: staging) != nil else {
                throw FlipperBackupError.invalidArchive("manifest missing")
            }
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: staging.path)
            #endif
            try FileManager.default.moveItem(at: staging, to: final)
            refreshBackups()
            status = "Backed up \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")."
            return FlipperBackupReceipt(
                url: final,
                files: manifest.files.count,
                bytes: manifest.files.reduce(0) { $0 + Int64($1.size) })
        } catch {
            status = "Backup incomplete: \(error.localizedDescription)"
            throw error
        }
    }

    func restore(_ zipURL: URL) async throws {
        running = true
        status = "Verifying backup…"
        defer { running = false }

        do {
            let manifest = try Self.validateArchive(at: zipURL)
            let archive: Archive
            do { archive = try Archive(url: zipURL, accessMode: .read) }
            catch { throw FlipperBackupError.invalidArchive("cannot open ZIP") }
            let entries = archive.filter { $0.type == .file && $0.path != Self.manifestName }
            for (index, entry) in entries.enumerated() {
                try Task.checkCancellation()
                status = "Restoring \(index + 1)/\(entries.count)…"
                let destination = try Self.safeDestination(for: entry.path)
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                if let expected = manifest?.files.first(where: { $0.path == entry.path }),
                   expected.size != data.count || expected.sha256 != Self.sha256(data) {
                    throw FlipperBackupError.checksumMismatch(entry.path)
                }
                try await makeDirs(for: destination)
                try await storage.write(destination, data: data, progress: nil)
                guard try await storage.checkedMD5(destination, timeout: 300) == Self.md5(data) else {
                    throw FlipperBackupError.checksumMismatch(destination)
                }
            }
            status = "Restored \(entries.count) file\(entries.count == 1 ? "" : "s")."
        } catch {
            status = "Restore incomplete: \(error.localizedDescription)"
            throw error
        }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshBackups()
    }

    // MARK: - Helpers

    static func safeDestination(for relativePath: String) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              parts.allSatisfy({ part in
                  !part.isEmpty && part != "." && part != ".." &&
                  part.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
              }) else {
            throw FlipperBackupError.invalidPath(relativePath)
        }
        return "/ext/\(relativePath)"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func collect(_ path: String, into files: inout [FlipperFile], depth: Int) async throws {
        guard depth < 32 else { throw FlipperBackupError.invalidPath(path) }
        let entries = try await storage.list(path)
        for e in entries {
            guard e.path == "\(path)/\(e.name)" else {
                throw FlipperBackupError.invalidPath(e.path)
            }
            _ = try Self.safeDestination(for: String(e.path.dropFirst("/ext/".count)))
            if e.isDirectory {
                try await collect(e.path, into: &files, depth: depth + 1)
            } else {
                guard files.count < 20_000 else { throw FlipperBackupError.invalidArchive("too many files") }
                guard UInt64(e.size) <= Self.maxFileBytes else {
                    throw FlipperBackupError.invalidArchive("file too large: \(e.path)")
                }
                files.append(e)
            }
        }
    }

    private func writeArchive(
        at url: URL,
        scratch: URL,
        files: [FlipperFile]
    ) async throws -> FlipperBackupManifest {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .create) }
        catch { throw FlipperBackupError.archiveCreation }
        let chunk = scratch.appendingPathComponent("file")
        var records: [FlipperBackupManifest.File] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            status = "Backing up \(index + 1)/\(files.count)…"
            let data = try await storage.read(file.path)
            guard data.count == Int(file.size) else {
                throw FlipperBackupError.incompleteRead(file.path)
            }
            guard try await storage.checkedMD5(file.path, timeout: 300) == Self.md5(data) else {
                throw FlipperBackupError.checksumMismatch(file.path)
            }
            let relative = String(file.path.dropFirst("/ext/".count))
            _ = try Self.safeDestination(for: relative)
            try data.write(to: chunk, options: .atomic)
            try archive.addEntry(with: relative, fileURL: chunk, compressionMethod: .deflate)
            records.append(.init(path: relative, size: data.count, sha256: Self.sha256(data)))
        }
        let manifest = FlipperBackupManifest(schema: 1, files: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: chunk, options: .atomic)
        try archive.addEntry(
            with: Self.manifestName, fileURL: chunk, compressionMethod: .deflate)
        return manifest
    }

    /// Validate the entire ZIP before restoring any file. Old archives without a
    /// manifest remain readable, but still require safe paths and valid ZIP CRCs.
    private static func validateArchive(at url: URL) throws -> FlipperBackupManifest? {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw FlipperBackupError.invalidArchive("cannot open ZIP") }
        var manifestData: Data?
        var actual: [String: FlipperBackupManifest.File] = [:]
        var totalBytes: UInt64 = 0
        for entry in archive where entry.type == .file {
            guard entry.uncompressedSize <= maxFileBytes,
                  totalBytes <= maxArchiveBytes - entry.uncompressedSize else {
                throw FlipperBackupError.invalidArchive("archive exceeds size limits")
            }
            totalBytes += entry.uncompressedSize
            if entry.path == manifestName {
                guard manifestData == nil else {
                    throw FlipperBackupError.invalidArchive("duplicate manifest")
                }
                var data = Data()
                _ = try archive.extract(entry) { data.append($0) }
                manifestData = data
                continue
            }
            _ = try safeDestination(for: entry.path)
            guard actual[entry.path] == nil else {
                throw FlipperBackupError.invalidArchive("duplicate file \(entry.path)")
            }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            actual[entry.path] = .init(
                path: entry.path, size: data.count, sha256: sha256(data))
        }
        guard !actual.isEmpty else { throw FlipperBackupError.noFiles }
        guard let manifestData else { return nil }
        let manifest = try JSONDecoder().decode(FlipperBackupManifest.self, from: manifestData)
        let declaredPaths = manifest.files.map(\.path)
        guard manifest.schema == 1,
              manifest.files.count == actual.count,
              Set(declaredPaths).count == declaredPaths.count,
              Set(declaredPaths) == Set(actual.keys),
              manifest.files.allSatisfy({ actual[$0.path]?.size == $0.size &&
                  actual[$0.path]?.sha256 == $0.sha256 }) else {
            throw FlipperBackupError.invalidArchive("manifest does not match files")
        }
        return manifest
    }

    /// Create every intermediate directory for a file path under /ext.
    private func makeDirs(for filePath: String) async throws {
        let comps = filePath.split(separator: "/").dropLast()   // drop filename
        var acc = ""
        for c in comps {
            acc += "/\(c)"
            try await storage.makeDirectory(acc)
        }
    }
}
