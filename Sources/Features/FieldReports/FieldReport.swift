import Foundation

enum FieldReportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let reason): return "Report rejected: \(reason)." }
    }
}

enum FieldReportKind: String, CaseIterable, Identifiable {
    case sensors, power, uhf, varta
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sensors: return "Sensor Watch"
        case .power: return "Power Journal"
        case .uhf: return "UHF Inventory"
        case .varta: return "Varta Inspector"
        }
    }
    var icon: String {
        switch self {
        case .sensors: return "thermometer.medium"
        case .power: return "battery.75percent"
        case .uhf: return "tag"
        case .varta: return "wave.3.right"
        }
    }
    static let root = "/ext/apps_data/device_library"
    var directory: String { Self.root + (self == .power ? "/power" : "/reports") }
    var header: [String] {
        switch self {
        case .sensors: return "object,protocol,id,channel,frequency_hz,timestamp,temp_tenths,humidity,battery_low,frames".components(separatedBy: ",")
        case .power: return "timestamp,soc,voltage_mv,current_ma,temp_tenths,heap_free,usb,charging,gauge_health".components(separatedBy: ",")
        case .uhf: return "epc,pc,antenna,hits,first,last,signal_raw,frequency_raw".components(separatedBy: ",")
        case .varta: return "source,id,clock,known_prefix,config_present,config_match,marker_present,marker_match".components(separatedBy: ",")
        }
    }
    var maximumRows: Int {
        switch self { case .sensors: return 256; case .power: return 128; case .uhf: return 32; case .varta: return 1 }
    }
    func accepts(name: String) -> Bool {
        guard name.hasSuffix(".csv") else { return false }
        let parts = name.dropLast(4).split(separator: "_", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == rawValue &&
            parts[1].allSatisfy(\.isASCIIDigit) && UInt32(parts[1]) != nil &&
            parts[2].allSatisfy(\.isASCIIDigit) && UInt8(parts[2]).map { $0 < 32 } == true
    }
}

private extension Character {
    var isASCIIDigit: Bool { unicodeScalars.count == 1 && (48...57).contains(unicodeScalars.first!.value) }
}

struct FieldReportRow: Identifiable, Equatable {
    let id: Int
    let values: [String: String]
    subscript(_ column: String) -> String { values[column] ?? "" }
    var object: String? {
        let text = self["object"]
        return text.hasPrefix("object:") ? String(text.dropFirst(7)) : nil
    }
    var sensor: String {
        [object ?? "", self["protocol"], self["id"], self["channel"], self["frequency_hz"]].joined(separator: " · ")
    }
}

struct FieldReportPoint: Identifiable {
    let id: Int
    let value: Double
    let group: String
}

struct FieldReportDocument {
    static let maximumBytes = 64 * 1024
    let kind: FieldReportKind
    let rows: [FieldReportRow]
    var objects: [String] { Array(Set(rows.compactMap(\.object))).sorted() }

    func series(column: String) -> [FieldReportPoint] {
        rows.compactMap { row in
            guard let value = Double(row[column]), value.isFinite else { return nil }
            let scale = column == "temp_tenths" ? 10.0 : column == "voltage_mv" ? 1000.0 : 1.0
            return FieldReportPoint(id: row.id, value: value / scale,
                                    group: kind == .sensors ? row.sensor : kind.title)
        }
    }

    /// The four producers emit unquoted, printable ASCII fields. This is their
    /// versioned schema, not a permissive spreadsheet/CSV importer.
    static func parse(_ data: Data, kind: FieldReportKind) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ (32...126).contains($0.value) || $0 == "\n" || $0 == "\r" }) else {
            throw FieldReportError.invalid("size or text encoding")
        }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard lines.count >= 2, lines.count <= kind.maximumRows + 1,
              lines.removeFirst() == kind.header.joined(separator: ",") else {
            throw FieldReportError.invalid("unknown header or row count")
        }
        let rows = try lines.enumerated().map { index, line -> FieldReportRow in
            let fields = line.components(separatedBy: ",")
            guard fields.count == kind.header.count, fields.allSatisfy({ $0.count <= 128 }),
                  !line.contains("\r") else { throw FieldReportError.invalid("row \(index + 1) shape") }
            let row = FieldReportRow(id: index, values: Dictionary(uniqueKeysWithValues: zip(kind.header, fields)))
            guard valid(row, kind: kind) else { throw FieldReportError.invalid("row \(index + 1) values") }
            return row
        }
        return Self(kind: kind, rows: rows)
    }

    private static func valid(_ row: FieldReportRow, kind: FieldReportKind) -> Bool {
        func number(_ key: String, _ limits: ClosedRange<Int64>, optional: Bool = false) -> Bool {
            let value = row[key]
            if optional && value.isEmpty { return true }
            guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespaces),
                  let parsed = Int64(value) else { return false }
            return limits.contains(parsed)
        }
        func hex(_ value: String) -> Bool { !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
        let uint32: ClosedRange<Int64> = 0...Int64(UInt32.max)
        switch kind {
        case .power:
            return number("timestamp", uint32) && number("soc", 0...100) && number("voltage_mv", 1...6000) &&
                number("current_ma", -10000...10000) && number("temp_tenths", -1000...1500) &&
                number("heap_free", 0...1_048_576) && number("usb", 0...1) && number("charging", 0...1) && number("gauge_health", 0...100)
        case .sensors:
            guard let object = row.object, !object.isEmpty, object.count <= 63, object != ".", object != "..",
                  object.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }),
                  !row["protocol"].isEmpty, row["protocol"].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [32,45,46,47,95].contains($0) }) else { return false }
            return number("id", uint32) && number("channel", 0...255) && number("frequency_hz", 100_000_000...1_000_000_000) &&
                number("timestamp", uint32) && number("temp_tenths", -800...800, optional: true) &&
                number("humidity", 0...100, optional: true) && number("battery_low", 0...1, optional: true) && number("frames", 1...Int64(UInt32.max))
        case .uhf:
            guard hex(row["epc"]), row["epc"].count <= 96, let pc = UInt16(row["pc"]),
                  Int((pc >> 11) & 31) * 4 == row["epc"].count else { return false }
            return number("antenna", 0...255) && number("hits", 1...Int64(UInt32.max)) &&
                number("first", uint32) && number("last", uint32) && number("signal_raw", uint32) && number("frequency_raw", uint32)
        case .varta:
            return ["live", "dump", "rfid"].contains(row["source"]) && row["id"].count == 10 && hex(row["id"]) &&
                ["0", "16", "32", "64"].contains(row["clock"]) &&
                ["known_prefix", "config_present", "config_match", "marker_present", "marker_match"].allSatisfy { number($0, 0...1) } &&
                (row["config_present"] == "1" || row["config_match"] == "0") && (row["marker_present"] == "1" || row["marker_match"] == "0")
        }
    }
}
