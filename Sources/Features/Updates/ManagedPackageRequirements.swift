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
        let isTumoflipF7API88 = originFork?.caseInsensitiveCompare("tumoflip") == .orderedSame
            && hardwareTarget == 7 && numeric && Int(parts[0]) == 88
        let minor = numeric ? Int(parts[1]) : nil
        var result: [String: String] = [:]
        for target in targets {
            let path = target.lowercased()
            guard path.hasPrefix("/ext/apps/") else { continue }
            let requirement: (name: String, minimumMinor: Int)
            switch (path as NSString).lastPathComponent {
            case "hid_ble.fap":
                requirement = ("Bluetooth Remote", 11)
            case "device_library.fap":
                requirement = ("Device Library", 5)
            default:
                continue
            }
            if !isTumoflipF7API88 || (minor ?? -1) < requirement.minimumMinor {
                result[target] = "\(requirement.name) needs Tumoflip F7 API 88.\(requirement.minimumMinor) or later in API 88. Update firmware first."
            }
        }
        return result
    }
}
