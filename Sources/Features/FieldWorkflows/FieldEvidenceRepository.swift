import Foundation

@MainActor protocol FieldEvidenceReading {
    func list(_ path: String) async throws -> [FlipperFile]
    func read(_ path: String, maximumBytes: Int) async throws -> Data
    func checksum(_ path: String) async throws -> String?
}

enum FieldEvidenceDocument: Equatable {
    case round(FieldRoundDocument)
    case inventory(CaptureInventory)
    case comparison(FieldComparisonDocument)
}
struct FieldEvidenceSnapshot: Equatable {
    let file: FlipperFile
    let document: FieldEvidenceDocument
    let data: Data
    let sha256: String
}
@MainActor struct FieldEvidenceRepository {
    static let root = "/ext/apps_data/device_library"
    enum Kind { case round, inventory, comparison }
    let reader: any FieldEvidenceReading

    static func kind(_ file: FlipperFile) -> Kind? {
        guard !file.isDirectory, file.name.utf8.count <= 96 else { return nil }
        if file.path == root+"/inventories/"+file.name,
           file.name.range(of:"^[0-9]{1,10}-[0-9]{2}\\.tinv$",options:.regularExpression) != nil,
           file.size >= 56, file.size <= CaptureInventory.maximumBytes { return .inventory }
        guard file.path == root+"/reports/"+file.name else { return nil }
        if file.name.range(of:"^round-[0-9]{1,10}-[a-f0-9]{16}\\.txt$",options:.regularExpression) != nil,
           file.size > 0, file.size <= 16*1024 { return .round }
        if file.name.range(of:"^[0-9]{1,10}-[0-9]{2}\\.txt$",options:.regularExpression) != nil,
           file.size <= 512*1024 { return .comparison }
        return nil
    }
    func index() async throws -> [FlipperFile] {
        var found: [String:FlipperFile] = [:]
        for directory in [Self.root+"/reports",Self.root+"/inventories"] {
            try Task.checkCancellation()
            let files = try await reader.list(directory)
            guard files.count <= 4096 else { throw FieldWorkflowError.invalid("evidence directory is too large") }
            for file in files where Self.kind(file) != nil { found[file.path] = file }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }.prefix(256).map { $0 }
    }
    func load(_ file: FlipperFile) async throws -> FieldEvidenceSnapshot {
        guard let kind = Self.kind(file) else { throw FieldWorkflowError.invalid("evidence path or size") }
        let limit: Int
        switch kind { case .round: limit = 16*1024;case .inventory: limit = CaptureInventory.maximumBytes;case .comparison: limit = 512*1024 }
        try Task.checkCancellation()
        guard let before = try await reader.checksum(file.path) else { throw FieldWorkflowError.invalid("device checksum unavailable") }
        let data = try await reader.read(file.path,maximumBytes:limit)
        try Task.checkCancellation()
        guard data.count == Int(file.size), data.count <= limit, FieldWire.md5(data) == before,
              try await reader.checksum(file.path) == before else { throw FieldWorkflowError.conflict }
        let document: FieldEvidenceDocument
        switch kind {
        case .round:
            let round = try FieldRoundDocument.parse(data)
            guard UInt32(file.name.split(separator:"-")[1]) == round.started else { throw FieldWorkflowError.invalid("round filename identity") }
            document = .round(round)
        case .inventory: document = .inventory(try CaptureInventory.parse(data))
        case .comparison: document = .comparison(try FieldComparisonDocument.parse(data))
        }
        return FieldEvidenceSnapshot(file:file,document:document,data:data,sha256:FieldWire.sha256(data))
    }
}
