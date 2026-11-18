import Foundation

struct SubGhzProfile: Equatable {
    static let canonicalPresets = ["AM270","AM650","FM238","FM476","FM12K"]
    static let maximumBytes = 64*1024
    static let standardFrequencies: Set<UInt32> = [300000000,302757000,303000000,303875000,303900000,304250000,307000000,307500000,307800000,309000000,310000000,312000000,312100000,312200000,313000000,313850000,314000000,314350000,314980000,315000000,318000000,320000000,320150000,330000000,345000000,348000000,350000000,387000000,390000000,418000000,430000000,430500000,431500000,433075000,433220000,433420000,433657070,433889000,433920000,434075000,434176948,434190000,434390000,434420000,434620000,434775000,438900000,440175000,462750000,464000000,467750000,779000000,868000000,868350000,868400000,868460000,868800000,868950000,906400000,915000000,925000000,928000000]
    var includeStandard: Bool
    var frequencies: [UInt32]
    var hopperFrequencies: [UInt32]
    var defaultFrequency: UInt32
    var hoppingPresets: [String]
    private let originalLines: [String]
    private static let managed: Set<String> = ["Add_standard_frequencies","Frequency","Hopper_frequency","Default_frequency","Hopping_Preset"]

    static func frequencyValid(_ value: UInt32) -> Bool {
        (281000000...361000000).contains(value) || (378000000...481000000).contains(value) || (749000000...962000000).contains(value)
    }
    static func hz(fromMHz text: String) throws -> UInt32 {
        let parts = text.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count <= 2, !parts[0].isEmpty, parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 6),
              let whole = UInt64(parts[0]), whole <= 1000 else { throw FieldWorkflowError.invalid("frequency, use MHz with at most six decimals") }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let value = whole*1_000_000+(UInt64(fraction+String(repeating:"0",count:6-fraction.count)) ?? 0)
        guard value <= UInt32.max, frequencyValid(UInt32(value)) else { throw FieldWorkflowError.invalid("frequency outside supported radio ranges") }
        return UInt32(value)
    }
    static func mhz(_ value: UInt32) -> String { String(format:"%u.%06u",value/1_000_000,value%1_000_000) }
    private static func pair(_ line: String) -> (String,String)? {
        let trimmed = line.trimmingCharacters(in:.whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of:":") else { return nil }
        return (String(trimmed[..<colon]).trimmingCharacters(in:.whitespaces),String(trimmed[trimmed.index(after:colon)...]).trimmingCharacters(in:.whitespaces))
    }
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes, let text = String(data:data,encoding:.utf8), !text.contains("\0"),
              text.unicodeScalars.allSatisfy({ $0.value == 10 || $0.value == 13 || $0.value == 9 || ($0.value >= 32 && $0.value != 127) }) else {
            throw FieldWorkflowError.invalid("profile encoding or size")
        }
        let lines = text.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
        let pairs = lines.compactMap(pair)
        func singleton(_ key: String, default fallback: String? = nil) throws -> String {
            let values = pairs.filter { $0.0 == key }.map(\.1)
            guard values.count <= 1, let result = values.first ?? fallback else { throw FieldWorkflowError.invalid("duplicate or missing \(key)") }
            return result
        }
        guard try singleton("Filetype") == "Flipper SubGhz Setting File", try singleton("Version") == "1" else { throw FieldWorkflowError.invalid("unsupported settings format") }
        let flag = try singleton("Add_standard_frequencies",default:"true")
        guard ["true","false"].contains(flag) else { throw FieldWorkflowError.invalid("standard frequency flag") }
        func numbers(_ key: String) throws -> [UInt32] {
            let values = try pairs.filter { $0.0 == key }.map { item -> UInt32 in
                guard item.1.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt32(item.1), frequencyValid(value) else { throw FieldWorkflowError.invalid("\(key) value") }
                return value
            }
            guard values.count <= 128, Set(values).count == values.count else { throw FieldWorkflowError.invalid("\(key) count or duplicates") }
            return values
        }
        let defaultText = try singleton("Default_frequency",default:"433920000")
        guard let defaultValue = UInt32(defaultText), frequencyValid(defaultValue) else { throw FieldWorkflowError.invalid("default frequency") }
        let presets = pairs.filter { $0.0 == "Hopping_Preset" }.map(\.1)
        guard presets.count <= 64 else { throw FieldWorkflowError.invalid("hopping preset count") }
        return try Self(includeStandard:flag == "true",frequencies:numbers("Frequency"),hopperFrequencies:numbers("Hopper_frequency"),defaultFrequency:defaultValue,hoppingPresets:presets,originalLines:lines)
    }
    func encoded() throws -> Data {
        guard frequencies.count <= 128, hopperFrequencies.count <= 128,
              frequencies.allSatisfy(Self.frequencyValid), hopperFrequencies.allSatisfy(Self.frequencyValid),
              Set(frequencies).count == frequencies.count, Set(hopperFrequencies).count == hopperFrequencies.count,
              Self.frequencyValid(defaultFrequency),
              (includeStandard || (!frequencies.isEmpty && !hopperFrequencies.isEmpty)),
              frequencies.contains(defaultFrequency) || (includeStandard && Self.standardFrequencies.contains(defaultFrequency)),
              Set(hoppingPresets).count == hoppingPresets.count, hoppingPresets.allSatisfy(Self.canonicalPresets.contains) else {
            throw FieldWorkflowError.invalid("frequency lists/default or hopping presets; only ordinary canonical presets may be selected")
        }
        var lines = originalLines.filter { Self.pair($0).map { !Self.managed.contains($0.0) } ?? true }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("Add_standard_frequencies: \(includeStandard ? "true" : "false")")
        lines += frequencies.map { "Frequency: \($0)" }
        lines += hopperFrequencies.map { "Hopper_frequency: \($0)" }
        lines.append("Default_frequency: \(defaultFrequency)")
        lines += hoppingPresets.map { "Hopping_Preset: \($0)" }
        let data = Data((lines.joined(separator:"\n")+"\n").utf8)
        guard data.count <= Self.maximumBytes else { throw FieldWorkflowError.invalid("profile too large") }
        return data
    }
}
