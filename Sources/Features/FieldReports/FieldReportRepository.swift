import Foundation
import CryptoKit

/// Intentionally no write, move or delete methods on this feature's capability.
protocol FieldReportReading {
    func list(_ path: String) async throws -> [FlipperFile]
    func read(_ path: String, maximumBytes: Int) async throws -> Data
    func checksum(_ path: String) async throws -> String?
}

struct FieldReportSnapshot {
    let file: FlipperFile
    let document: FieldReportDocument
    let data: Data
    let sha256: String
}

struct FieldReportRepository {
    let reader: any FieldReportReading

    static func kind(for file: FlipperFile) -> FieldReportKind? {
        guard !file.isDirectory, file.size > 0, file.size <= FieldReportDocument.maximumBytes else { return nil }
        return FieldReportKind.allCases.first {
            $0.accepts(name: file.name) && file.path == "\($0.directory)/\(file.name)"
        }
    }

    func index() async throws -> [FlipperFile] {
        var found: [String: FlipperFile] = [:]
        for directory in [FieldReportKind.root + "/reports", FieldReportKind.root + "/power"] {
            try Task.checkCancellation()
            let files = try await reader.list(directory)
            guard files.count <= 4096 else { throw FieldReportError.invalid("directory is too large") }
            for file in files where Self.kind(for: file) != nil { found[file.path] = file }
        }
        try Task.checkCancellation()
        return Array(found.values.sorted {
            let left = UInt32($0.name.split(separator: "_")[1]) ?? 0
            let right = UInt32($1.name.split(separator: "_")[1]) ?? 0
            if left != right { return left > right }
            let leftRevision = UInt8($0.name.dropLast(4).split(separator: "_")[2]) ?? 0
            let rightRevision = UInt8($1.name.dropLast(4).split(separator: "_")[2]) ?? 0
            return leftRevision == rightRevision ? $0.name > $1.name : leftRevision > rightRevision
        }.prefix(256))
    }

    func load(_ file: FlipperFile) async throws -> FieldReportSnapshot {
        guard let kind = Self.kind(for: file) else { throw FieldReportError.invalid("path or size") }
        try Task.checkCancellation()
        guard let before = try await reader.checksum(file.path) else { throw FieldReportError.invalid("device checksum is unavailable") }
        try Task.checkCancellation()
        let data = try await reader.read(file.path, maximumBytes: FieldReportDocument.maximumBytes)
        try Task.checkCancellation()
        guard data.count == Int(file.size), data.count <= FieldReportDocument.maximumBytes,
              let after = try await reader.checksum(file.path), before == after,
              before == Insecure.MD5.hash(data: data).map({ String(format: "%02x", $0) }).joined() else {
            throw FieldReportError.invalid("file changed or transfer checksum differs")
        }
        try Task.checkCancellation()
        return FieldReportSnapshot(file: file, document: try FieldReportDocument.parse(data, kind: kind), data: data,
                                   sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
