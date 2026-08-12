import Foundation

enum TumoflipFirmwareChannel: String, CaseIterable, Identifiable, Equatable {
    case stable
    case dev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stable: return "Stable"
        case .dev: return "Dev"
        }
    }

    var packageLabel: String {
        switch self {
        case .stable: return "main/stable packages"
        case .dev: return "dev packages"
        }
    }

    static func infer(version: String) -> TumoflipFirmwareChannel? {
        if version.hasPrefix("t-dev-") { return .dev }
        let stablePatterns = [
            #"^t-flppr-fw-[0-9]{3}$"#,
            #"^t-flppr-fw-[0-9]{3}-[0-9]{3}$"#,
            #"^tmwhflpprarf[0-9]{3}-[0-9]{3}$"#,
        ]
        if stablePatterns.contains(where: {
            version.range(of: $0, options: .regularExpression) != nil
        }) {
            return .stable
        }
        return nil
    }
}

enum TumoflipReleaseCatalogPolicy {
    /// A published release can be retained for source and acceptance evidence while
    /// being removed from user-facing firmware/package pickers.
    static let hiddenMarker = "<!-- tumoflip-catalog: hidden -->"

    static func isVisible(body: String?) -> Bool {
        guard let body else { return true }
        return !body.localizedCaseInsensitiveContains(hiddenMarker)
    }
}

struct TumoflipDeviceIdentity: Equatable {
    let firmwareVersion: String?
    let originFork: String?
    let firmwareCommit: String?
    let firmwareCommitDirty: Bool?
    let firmwareAPI: String?
    let hardwareTarget: Int?

    init(
        firmwareVersion: String?,
        originFork: String?,
        firmwareCommit: String?,
        firmwareCommitDirty: Bool?,
        firmwareAPI: String?,
        hardwareTarget: Int?
    ) {
        self.firmwareVersion = firmwareVersion
        self.originFork = originFork
        self.firmwareCommit = firmwareCommit
        self.firmwareCommitDirty = firmwareCommitDirty
        self.firmwareAPI = firmwareAPI
        self.hardwareTarget = hardwareTarget
    }

    init(deviceInfo: [(String, String)]) {
        let dict = Dictionary(deviceInfo, uniquingKeysWith: { first, _ in first })
        let apiParts = [dict["firmware_api_major"], dict["firmware_api_minor"]].compactMap { $0 }
        self.init(
            firmwareVersion: dict["firmware_version"],
            originFork: dict["firmware_origin_fork"],
            firmwareCommit: dict["firmware_commit"],
            firmwareCommitDirty: Self.parseBool(dict["firmware_commit_dirty"]),
            firmwareAPI: apiParts.count == 2 ? apiParts.joined(separator: ".") : nil,
            hardwareTarget: dict["hardware_target"].flatMap(Int.init)
        )
    }

    var isTumoflip: Bool {
        originFork?.caseInsensitiveCompare("tumoflip") == .orderedSame
    }

    var inferredChannel: TumoflipFirmwareChannel? {
        guard isTumoflip, let firmwareVersion else { return nil }
        return TumoflipFirmwareChannel.infer(version: firmwareVersion)
    }

    /// API/target pair used to validate external FAP/FAL binaries. Keep the parsing in
    /// one place so package routing and compatibility checks cannot disagree about the
    /// same `device_info` response.
    var compatibilityIdentity: TumoflipCompatibilityIdentity? {
        guard let firmwareAPI,
              let apiMajorText = firmwareAPI.split(separator: ".", maxSplits: 1).first,
              let apiMajor = Int(apiMajorText),
              let hardwareTarget else {
            return nil
        }
        return TumoflipCompatibilityIdentity(
            apiMajor: apiMajor,
            hardwareTarget: hardwareTarget
        )
    }

    private static func parseBool(_ value: String?) -> Bool? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        switch raw {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }
}

struct TumoflipCompatibilityIdentity: Equatable {
    let apiMajor: Int
    let hardwareTarget: Int
}

struct TumoflipFirmwareRoute: Equatable {
    enum Warning: Equatable {
        case identityUnavailable
        case nonTumoflip(origin: String?)
        case unknownTumoflipVersion(String?)
        case manualOverride(selected: TumoflipFirmwareChannel, detected: TumoflipFirmwareChannel?)

        var message: String {
            switch self {
            case .identityUnavailable:
                return "Installed firmware identity is unavailable. Stable packages are selected until you explicitly choose another channel."
            case .nonTumoflip(let origin):
                return "Connected firmware is not reported as Tumoflip\(origin.map { " (\($0))" } ?? ""). Stable packages are selected; dev packages are never selected automatically."
            case .unknownTumoflipVersion(let version):
                return "Tumoflip version \(version ?? "unknown") does not match a known stable/dev pattern. Stable packages are selected until you explicitly choose another channel."
            case .manualOverride(let selected, let detected):
                if let detected {
                    return "Manual override is using \(selected.packageLabel) instead of detected \(detected.packageLabel). Confirm compatibility before installing."
                }
                return "Manual override is using \(selected.packageLabel) without a detected Tumoflip channel. Confirm compatibility before installing."
            }
        }
    }

    let channel: TumoflipFirmwareChannel
    let detectedChannel: TumoflipFirmwareChannel?
    let warning: Warning?
    let isManualOverride: Bool
}

enum TumoflipFirmwareRouter {
    static func route(
        identity: TumoflipDeviceIdentity?,
        manualOverride: TumoflipFirmwareChannel?
    ) -> TumoflipFirmwareRoute {
        let detected = identity?.inferredChannel
        if let manualOverride {
            // A persisted selection that matches the detected firmware channel is
            // not a compatibility override. Keep the selected channel, but do not
            // surface a warning that claims Dev is replacing Dev (or Stable is
            // replacing Stable).
            if manualOverride == detected {
                return TumoflipFirmwareRoute(
                    channel: manualOverride,
                    detectedChannel: detected,
                    warning: nil,
                    isManualOverride: false
                )
            }
            return TumoflipFirmwareRoute(
                channel: manualOverride,
                detectedChannel: detected,
                warning: .manualOverride(selected: manualOverride, detected: detected),
                isManualOverride: true
            )
        }

        guard let identity else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .identityUnavailable,
                isManualOverride: false
            )
        }
        guard identity.isTumoflip else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .nonTumoflip(origin: identity.originFork),
                isManualOverride: false
            )
        }
        guard let detected else {
            return TumoflipFirmwareRoute(
                channel: .stable,
                detectedChannel: nil,
                warning: .unknownTumoflipVersion(identity.firmwareVersion),
                isManualOverride: false
            )
        }
        return TumoflipFirmwareRoute(
            channel: detected,
            detectedChannel: detected,
            warning: nil,
            isManualOverride: false
        )
    }
}

enum TumoflipPackageReleaseMatcher {
    /// Prefer the independent FW Packages catalog over package assets bundled with
    /// a firmware release. GitHub's releases endpoint is ordered by `created_at`,
    /// not `published_at`: a firmware draft created later can otherwise shadow a
    /// subsequently published package revision forever.
    static func shouldReplaceSelection(
        current: TumoflipManifest.PackageRelease?,
        with candidate: TumoflipManifest.PackageRelease?
    ) -> Bool {
        let currentRevision = current.flatMap { release in
            release.isIndependentCatalog ? release.catalogRevision : nil
        }
        let candidateRevision = candidate.flatMap { release in
            release.isIndependentCatalog ? release.catalogRevision : nil
        }

        switch (currentRevision, candidateRevision) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(current), .some(candidate)):
            return candidate > current
        case (nil, nil):
            // Keep the first legacy exact-firmware match to preserve the API order
            // used before independent package catalogs existed.
            return false
        }
    }

    static func matches(
        manifestVersion: String,
        packageRelease: TumoflipManifest.PackageRelease? = nil,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?
    ) -> Bool {
        // Independent catalog revisions follow the Community Apps lifecycle: the
        // package channel and firmware compatibility are checked, but the package is
        // not named after (or pinned to) one exact firmware release.
        if let packageRelease, packageRelease.isIndependentCatalog {
            guard packageRelease.catalogChannel == channel.rawValue else { return false }
            guard let installedVersion, !installedVersion.isEmpty else { return true }
            return TumoflipFirmwareChannel.infer(version: installedVersion) == channel
        }

        // Backward compatibility for package assets attached directly to old firmware
        // releases. Those manifests remain exact-version pinned.
        guard TumoflipFirmwareChannel.infer(version: manifestVersion) == channel else {
            return false
        }
        guard let installedVersion, !installedVersion.isEmpty else {
            return true
        }
        return manifestVersion == installedVersion
    }
}
