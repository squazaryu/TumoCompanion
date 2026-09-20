import Foundation

/// Narrow source-owned requirements in addition to generic FAP major/target checks.
/// Equal API numbers in another fork do not prove that Tumoflip-only exports exist.
enum ManagedPackageRequirements {
    static func blocked(
        targets: [String],
        originFork: String?,
        firmwareAPI: String?,
        hardwareTarget: Int?
    ) -> [String: String] {
        let parts = firmwareAPI?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        let numeric = parts.count == 2 && parts.allSatisfy {
            !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
        let supported = originFork?.caseInsensitiveCompare("tumoflip") == .orderedSame
            && hardwareTarget == 7 && numeric && Int(parts[0]) == 88
            && (Int(parts[1]) ?? -1) >= 11
        guard !supported else { return [:] }
        var result: [String: String] = [:]
        for target in targets {
            let path = target.lowercased()
            if path.hasPrefix("/ext/apps/"), (path as NSString).lastPathComponent == "hid_ble.fap" {
                result[target] = "Bluetooth Remote needs Tumoflip F7 API 88.11 or later in API 88. Update firmware first."
            }
        }
        return result
    }
}
