import Foundation

struct SubGhzProfile: Equatable {
  static let canonicalPresets = ["AM270", "AM650", "FM238", "FM476", "FM12K"]
  static let maximumBytes = 64 * 1024
  static let standardFrequencies: Set<UInt32> = [
    300_000_000, 302_757_000, 303_000_000, 303_875_000, 303_900_000, 304_250_000, 307_000_000,
    307_500_000, 307_800_000, 309_000_000, 310_000_000, 312_000_000, 312_100_000, 312_200_000,
    313_000_000, 313_850_000, 314_000_000, 314_350_000, 314_980_000, 315_000_000, 318_000_000,
    320_000_000, 320_150_000, 330_000_000, 345_000_000, 348_000_000, 350_000_000, 387_000_000,
    390_000_000, 418_000_000, 430_000_000, 430_500_000, 431_000_000, 431_500_000, 433_075_000,
    433_220_000, 433_420_000, 433_657_070, 433_889_000, 433_920_000, 434_075_000, 434_176_948,
    434_190_000, 434_390_000, 434_420_000, 434_620_000, 434_775_000, 438_900_000, 440_175_000,
    462_750_000, 464_000_000, 467_750_000, 779_000_000, 868_000_000, 868_350_000, 868_400_000,
    868_460_000, 868_800_000, 868_950_000, 906_400_000, 915_000_000, 925_000_000, 928_000_000,
  ]
  var includeStandard: Bool
  var frequencies: [UInt32]
  var hopperFrequencies: [UInt32]
  var defaultFrequency: UInt32
  var hoppingPresets: [String]
  private let originalLines: [String]
  private static let managed: Set<String> = [
    "Add_standard_frequencies", "Frequency", "Hopper_frequency", "Default_frequency",
    "Hopping_Preset",
  ]

  static func frequencyValid(_ value: UInt32) -> Bool {
    (281_000_000...361_000_000).contains(value) || (378_000_000...481_000_000).contains(value)
      || (749_000_000...962_000_000).contains(value)
  }
  static func hz(fromMHz text: String) throws -> UInt32 {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2, !parts[0].isEmpty,
      parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
      parts.count == 1 || (!parts[1].isEmpty && parts[1].count <= 6),
      let whole = UInt64(parts[0]), whole <= 1000
    else { throw FieldWorkflowError.invalid("frequency, use MHz with at most six decimals") }
    let fraction = parts.count == 2 ? String(parts[1]) : ""
    let value =
      whole * 1_000_000
      + (UInt64(fraction + String(repeating: "0", count: 6 - fraction.count)) ?? 0)
    guard value <= UInt32.max, frequencyValid(UInt32(value)) else {
      throw FieldWorkflowError.invalid("frequency outside supported radio ranges")
    }
    return UInt32(value)
  }
  static func mhz(_ value: UInt32) -> String {
    String(format: "%u.%06u", value / 1_000_000, value % 1_000_000)
  }
  private static func pair(_ line: String) -> (String, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else {
      return nil
    }
    return (
      String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces),
      String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    )
  }
  static func parse(_ data: Data) throws -> Self {
    guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
      !text.contains("\0"),
      text.unicodeScalars.allSatisfy({
        $0.value == 10 || $0.value == 13 || $0.value == 9 || ($0.value >= 32 && $0.value != 127)
      })
    else {
      throw FieldWorkflowError.invalid("profile encoding or size")
    }
    let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    let pairs = lines.compactMap(pair)
    func singleton(_ key: String, default fallback: String? = nil) throws -> String {
      let values = pairs.filter { $0.0 == key }.map(\.1)
      guard values.count <= 1, let result = values.first ?? fallback else {
        throw FieldWorkflowError.invalid("duplicate or missing \(key)")
      }
      return result
    }
    guard try singleton("Filetype") == "Flipper SubGhz Setting File",
      try singleton("Version") == "1"
    else { throw FieldWorkflowError.invalid("unsupported settings format") }
    let flag = try singleton("Add_standard_frequencies", default: "true")
    guard ["true", "false"].contains(flag) else {
      throw FieldWorkflowError.invalid("standard frequency flag")
    }
    func numbers(_ key: String) throws -> [UInt32] {
      let values = try pairs.filter { $0.0 == key }.map { item -> UInt32 in
        guard item.1.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt32(item.1),
          frequencyValid(value)
        else { throw FieldWorkflowError.invalid("\(key) value") }
        return value
      }
      guard values.count <= 128, Set(values).count == values.count else {
        throw FieldWorkflowError.invalid("\(key) count or duplicates")
      }
      return values
    }
    let defaultText = try singleton("Default_frequency", default: "433920000")
    guard let defaultValue = UInt32(defaultText), frequencyValid(defaultValue) else {
      throw FieldWorkflowError.invalid("default frequency")
    }
    let presets = pairs.filter { $0.0 == "Hopping_Preset" }.map(\.1)
    guard presets.count <= 64 else { throw FieldWorkflowError.invalid("hopping preset count") }
    return try Self(
      includeStandard: flag == "true", frequencies: numbers("Frequency"),
      hopperFrequencies: numbers("Hopper_frequency"), defaultFrequency: defaultValue,
      hoppingPresets: presets, originalLines: lines)
  }
  func encoded() throws -> Data {
    guard frequencies.count <= 128, hopperFrequencies.count <= 128,
      frequencies.allSatisfy(Self.frequencyValid),
      hopperFrequencies.allSatisfy(Self.frequencyValid),
      Set(frequencies).count == frequencies.count,
      Set(hopperFrequencies).count == hopperFrequencies.count,
      Self.frequencyValid(defaultFrequency),
      includeStandard || (!frequencies.isEmpty && !hopperFrequencies.isEmpty),
      frequencies.contains(defaultFrequency)
        || (includeStandard && Self.standardFrequencies.contains(defaultFrequency)),
      Set(hoppingPresets).count == hoppingPresets.count,
      hoppingPresets.allSatisfy(Self.canonicalPresets.contains)
    else {
      throw FieldWorkflowError.invalid(
        "frequency lists/default or hopping presets; only ordinary canonical presets may be selected"
      )
    }
    var lines = originalLines.filter { Self.pair($0).map { !Self.managed.contains($0.0) } ?? true }
    while lines.last?.isEmpty == true { lines.removeLast() }
    lines.append("Add_standard_frequencies: \(includeStandard ? "true" : "false")")
    lines += frequencies.map { "Frequency: \($0)" }
    lines += hopperFrequencies.map { "Hopper_frequency: \($0)" }
    lines.append("Default_frequency: \(defaultFrequency)")
    lines += hoppingPresets.map { "Hopping_Preset: \($0)" }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    guard data.count <= Self.maximumBytes else {
      throw FieldWorkflowError.invalid("profile too large")
    }
    return data
  }
}
