import Foundation
import CryptoKit

struct FieldRoundDocument: Equatable {
    enum Result: String, Codable, CaseIterable { case pending = "PENDING", pass = "PASS", problem = "PROBLEM", skipped = "SKIPPED" }
    struct Row: Identifiable, Equatable {
        let object: String
        let result: Result
        let timestamp: UInt32
        let note: String
        var id: String { object }
    }
    let started: UInt32
    let rows: [Row]
    var pending: Int { rows.filter { $0.result == .pending }.count }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16*1024, let text = String(data:data,encoding:.utf8), text.hasSuffix("\n") else {
            throw FieldWorkflowError.invalid("round text or size")
        }
        let lines = text.dropLast().components(separatedBy:"\n")
        let prefix = "Started UTC epoch: "
        guard lines.count >= 5, lines.count <= 20, lines[0] == "Field round",
              lines[1].hasPrefix(prefix),
              let started = UInt32(lines[1].dropFirst(prefix.count)), started > 0,
              lines[2] == "Explicit user results; opening a file is not a test.",
              lines[3] == "Object\tResult\tUTC epoch\tNote" else {
            throw FieldWorkflowError.invalid("round header or row count")
        }
        var rows: [Row] = []
        var names = Set<String>()
        for line in lines.dropFirst(4) {
            let columns = line.components(separatedBy:"\t")
            guard columns.count == 4, FieldWire.objectName(columns[0]), names.insert(columns[0]).inserted,
                  let result = Result(rawValue:columns[1]), let time = UInt32(columns[2]),
                  FieldWire.printable(columns[3]), columns[3].utf8.count < 64,
                  (result == .pending ? time == 0 && columns[3].isEmpty : time >= started) else {
                throw FieldWorkflowError.invalid("round row")
            }
            rows.append(Row(object:columns[0],result:result,timestamp:time,note:columns[3]))
        }
        return Self(started:started,rows:rows)
    }
}

struct CaptureDifference: Identifiable, Equatable {
    enum State: String, CaseIterable { case unchanged, changed, missing, unreadable, added }
    let path: String
    let state: State
    var id: String { path }
}

struct CaptureInventory: Equatable {
    struct Entry: Identifiable, Equatable {
        let path: String
        let size: UInt32
        let sha256: String
        var id: String { path }
    }
    static let maximumBytes = 16+512*292+40
    let entries: [Entry]
    let digest: String

    static func parse(_ input: Data) throws -> Self {
        let data = Data(input)
        guard data.count >= 56, data.count <= maximumBytes, (data.count-56)%292 == 0,
              try FieldWire.u32(data,0) == 0x31564954, try FieldWire.u32(data,4) == 1,
              try FieldWire.u32(data,8) == 292, try FieldWire.u32(data,12) == 0 else {
            throw FieldWorkflowError.invalid("inventory header, version or size")
        }
        let count = (data.count-56)/292
        let footer = 16+count*292
        let hash = Data(SHA256.hash(data:data.prefix(footer)))
        guard try FieldWire.u32(data,footer) == 0x444E4554,
              try FieldWire.u32(data,footer+4) == UInt32(count),
              hash == data.subdata(in:footer+8..<data.count) else {
            throw FieldWorkflowError.invalid("inventory footer or digest")
        }
        var entries: [Entry] = []
        var paths = Set<String>()
        for index in 0..<count {
            let offset = 16+index*292
            let path = try FieldWire.text(data,offset,256)
            let size = try FieldWire.u32(data,offset+256)
            guard FieldWire.capturePath(path), size <= 16*1024*1024,
                  paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw FieldWorkflowError.invalid("inventory path, duplicate or file size")
            }
            let digest = data.subdata(in:offset+260..<offset+292).map { String(format:"%02x",$0) }.joined()
            entries.append(Entry(path:path,size:size,sha256:digest))
        }
        return Self(entries:entries,digest:hash.map { String(format:"%02x",$0) }.joined())
    }
    /// Comparison of two saved snapshots, not a scan or proof of the current SD.
    func compare(to newer: Self) -> [CaptureDifference] {
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let current = Dictionary(uniqueKeysWithValues:newer.entries.map { (key($0.path),$0) })
        let old = Set(entries.map { key($0.path) })
        return entries.map { entry in
            let state: CaptureDifference.State
            if let observed = current[key(entry.path)] { state = observed.size == entry.size && observed.sha256 == entry.sha256 ? .unchanged : .changed }
            else { state = .missing }
            return CaptureDifference(path:entry.path,state:state)
        } + newer.entries.filter { !old.contains(key($0.path)) }.map { CaptureDifference(path:$0.path,state:.added) }
    }
}

struct FieldComparisonDocument: Equatable {
    let rows: [CaptureDifference]
    /// Native TXT reports contain only differences and have no completion footer.
    var provesCompleteScan: Bool { false }
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 512*1024, let text = String(data:data,encoding:.utf8),
              text.isEmpty || text.hasSuffix("\n") else { throw FieldWorkflowError.invalid("comparison text or size") }
        if text.isEmpty { return Self(rows:[]) }
        let lines = text.dropLast().components(separatedBy:"\n")
        guard lines.count <= 1024 else { throw FieldWorkflowError.invalid("comparison row count") }
        var paths = Set<String>()
        let rows = try lines.map { line -> CaptureDifference in
            let values = line.components(separatedBy:"\t")
            guard values.count == 2, let state = CaptureDifference.State(rawValue:values[0].lowercased()),
                  state != .unchanged, FieldWire.capturePath(values[1]),
                  paths.insert(values[1].lowercased()).inserted else { throw FieldWorkflowError.invalid("comparison row") }
            return CaptureDifference(path:values[1],state:state)
        }
        return Self(rows:rows)
    }
}
