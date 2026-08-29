import Foundation
import CryptoKit
import ZIPFoundation
import os

private let ulog = Logger(subsystem: "com.tumoflip.unleashedcompanion", category: "updates")

enum PluginInstallRouting {
    static let targetPaths: [String: String] = [
        "air_mouse": "/ext/apps/Module One/AirMouse BMI160/air_mouse.fap",
        "airmon": "/ext/apps/Module One/ESP32 Wi-Fi/airmon.fap",
        "esp32_wifi_marauder": "/ext/apps/Module One/ESP32 Wi-Fi/esp32_wifi_marauder.fap",
        "esp_flasher": "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
        "evil_portal": "/ext/apps/Module One/ESP32 Wi-Fi/evil_portal.fap",
        "flipper_share": "/ext/apps/Module One/Sub-GHz/flipper_share.fap",
        "flipper_xremote": "/ext/apps/Module One/IR Blaster/tumoflip_xremote.fap",
        "freq_analyzer_ext": "/ext/apps/Module One/Sub-GHz/freq_analyzer_ext.fap",
        "ghost_esp": "/ext/apps/Module One/ESP32 Wi-Fi/ghost_esp.fap",
        "gps_nmea": "/ext/apps/Module One/GPS/gps_nmea.fap",
        "gps_track": "/ext/apps/Module One/GPS/gps_track.fap",
        "ibutton_converter": "/ext/apps/Module One/iButton/ibutton_converter.fap",
        "ir_intervalometer": "/ext/apps/Module One/IR Blaster/ir_intervalometer.fap",
        "ir_remote": "/ext/apps/Module One/IR Blaster/ir_remote.fap",
        "ir_scope": "/ext/apps/Module One/IR Blaster/ir_scope.fap",
        "nrf24_batch": "/ext/apps/Module One/NRF24/nrf24_batch.fap",
        "nrf24_mouse_jacker": "/ext/apps/Module One/NRF24/nrf24_mouse_jacker.fap",
        "nrf24_mouse_jacker_ms": "/ext/apps/Module One/NRF24/nrf24_mouse_jacker_ms.fap",
        "nrf24_scanner": "/ext/apps/Module One/NRF24/nrf24_scanner.fap",
        "nrf24_sniffer": "/ext/apps/Module One/NRF24/nrf24_sniffer.fap",
        "nrf24_sniffer_ms": "/ext/apps/Module One/NRF24/nrf24_sniffer_ms.fap",
        "nrf24channelscanner": "/ext/apps/Module One/NRF24/nrf24channelscanner.fap",
        "nrf24tool": "/ext/apps/Module One/NRF24/nrf24tool.fap",
        "proto_pirate": "/ext/apps_data/arf_subghz_full/modules/proto_pirate.fap",
        "protoview": "/ext/apps/Module One/Sub-GHz/protoview.fap",
        "radio_scanner": "/ext/apps/Module One/Sub-GHz/radio_scanner.fap",
        "spectrum_analyzer": "/ext/apps/Module One/Sub-GHz/spectrum_analyzer.fap",
        "sub_analyzer": "/ext/apps/Module One/Sub-GHz/sub_analyzer.fap",
        "subghz_bruteforcer": "/ext/apps_data/arf_subghz_full/modules/subghz_bruteforcer.fap",
        "subghz_playlist": "/ext/apps/Module One/Sub-GHz/subghz_playlist.fap",
        "subghz_playlist_creator": "/ext/apps/Module One/Sub-GHz/subghz_playlist_creator.fap",
        "subghz_raw_edit": "/ext/apps/ARF Tools/subghz_raw_edit.fap",
        "subghz_signal_gen": "/ext/apps/Module One/Sub-GHz/subghz_signal_gen.fap",
        // Canonical Tumoflip/FW Packages route. Older builds used Module One;
        // that path is retained only as a guarded cleanup candidate below.
        "subghz_wardriving": "/ext/apps/Sub-GHz/subghz_wardriving.fap",
        "timed_remote": "/ext/apps/Module One/IR Blaster/timed_remote.fap",
        // Community Pack moved its source FAP to Tools/Crypto, but Tumoflip's
        // audited TOTP build remains at this route with its CLI-plugin family.
        "totp": "/ext/apps/Tools/totp.fap",
        "tpms": "/ext/apps/Module One/Sub-GHz/tpms.fap",
        "ublox": "/ext/apps/Module One/GPS/ublox.fap",
        "unitemp": "/ext/apps/Module One/Sensors BME280/unitemp.fap",
        "vario": "/ext/apps/Module One/Sensors BME280/vario.fap",
        "weather_station": "/ext/apps/Module One/Sub-GHz/weather_station.fap",
        "wifi_map": "/ext/apps/Module One/ESP32 Wi-Fi/wifi_map.fap",
        "wifi_scanner": "/ext/apps/Module One/ESP32 Wi-Fi/wifi_scanner.fap",
        "wmbuster": "/ext/apps/Module One/Sub-GHz/wmbuster.fap",
    ]

    static func targetPath(for remotePath: String) -> String {
        targetPaths[appID(for: remotePath)] ?? remotePath
    }

    /// Stable identity of a catalog binary. Community Pack categories and install
    /// routes are allowed to move, but the FAP basename is the app identity used by
    /// the Flipper launcher and by the package audit.
    static func appID(for path: String) -> String {
        (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            .lowercased()
    }

    static func legacyPaths(for remotePath: String) -> [String] {
        let appName = appID(for: remotePath)
        var paths: [String] = []
        let target = targetPath(for: remotePath)
        if target != remotePath { paths.append(remotePath) }
        if appName == "subghz_wardriving" {
            paths.append("/ext/apps/Module One/Sub-GHz/subghz_wardriving.fap")
        }
        return Array(Set(paths)).sorted()
    }

    /// Device paths that can represent one catalog binary, ordered from the local
    /// Tumoflip route to the current Community Pack path and then explicit historical
    /// aliases. Hash equality decides which one is authoritative; path spelling alone
    /// must never create a false missing/diff result.
    static func candidatePaths(for remotePath: String) -> [String] {
        let target = targetPath(for: remotePath)
        var result = [target]
        result.append(contentsOf: legacyPaths(for: remotePath))
        var seen = Set<String>()
        return result.filter {
            seen.insert(PluginRouteReconciliation.pathIdentity($0)).inserted
        }
    }

    static func remotePath(for archivePath: String) -> String? {
        for marker in ["artifacts-base/", "artifacts-extra/"] {
            if let range = archivePath.range(of: marker) {
                return "/ext/apps/" + archivePath[range.upperBound...]
            }
        }
        if let range = archivePath.range(of: "apps_data/") {
            return "/ext/apps_data/" + archivePath[range.upperBound...]
        }
        return nil
    }
}

enum PluginProtectionPolicy {
    /// Data-only plugin families whose binary names do not match the owning app.
    /// Protect the family as one unit so a catalog update cannot mix an upstream
    /// FAL set with Tumoflip's corresponding FAP or protocol pack.
    private static let dataFamilyOwners: [(prefix: String, owner: String)] = [
        ("/ext/apps_data/arf_subghz_full/", "arf_subghz_full"),
        ("/ext/apps_data/rolljam_standalone/", "rolljam"),
        ("/ext/apps_data/subghz/plugins/", "subghz_protocols"),
        ("/ext/apps_data/totp/", "totp"),
    ]

    static func protectionKeys(name: String, remotePath: String) -> Set<String> {
        // Flipper storage is FAT-backed. A catalog/archive spelling such as
        // `PLUGINS` must retain the same protection-family owner as `plugins`,
        // otherwise the generic apps_data fallback can silently classify a
        // protected protocol FAL as the unrelated `subghz` family.
        let path = PluginRouteReconciliation.pathIdentity(remotePath)
        var keys = [name.lowercased()]
        if let family = dataFamilyOwners.first(where: { path.hasPrefix($0.prefix) }) {
            keys.append(family.owner)
        } else if path.hasPrefix("/ext/apps_data/") {
            let suffix = path.dropFirst("/ext/apps_data/".count)
            if let root = suffix.split(separator: "/").first {
                keys.append(String(root).lowercased())
            }
        }
        return Set(keys)
    }

    static func normalizedName(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if name.hasSuffix(".fap") {
            name.removeLast(4)
        }
        guard !name.isEmpty,
              name.count <= 255,
              !name.contains("/"),
              !name.contains("\\"),
              name.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return name
    }

    static func isProtected(
        name: String,
        remotePath: String,
        excluded: Set<String>,
        unprotectedBuiltIns: Set<String>
    ) -> Bool {
        protectionKeys(name: name, remotePath: remotePath).contains {
            excluded.contains($0) && !unprotectedBuiltIns.contains($0)
        }
    }
}

struct PluginUpdate: Identifiable {
    let id = UUID()
    let remotePath: String   // /ext/apps/<Category>/<app>.fap
    let name: String
    let category: String
    let pack: String         // "base" | "extra"
    let newMD5: String
    let oldMD5: String?      // device/cache md5 (nil = not installed)
    let size: Int
    var selected = true
    var isNew: Bool { oldMD5 == nil }
    var targetPath: String { PluginInstallRouting.targetPath(for: remotePath) }
    var isRouted: Bool { targetPath != remotePath }
    var targetCategory: String {
        let parent = (targetPath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

enum PluginCatalogMetadata: Equatable {
    case parsed(FapMetadata)
    case invalid
}

enum PluginSelectionPolicy {
    static func classify(
        _ catalog: [String: PluginCatalogMetadata],
        deviceApiMajor: Int?,
        deviceTarget: Int?
    ) -> [String: FapCompatibilityState] {
        catalog.mapValues { metadata in
            switch metadata {
            case .parsed(let value):
                return FapCompatibility.classify(
                    value,
                    deviceApiMajor: deviceApiMajor,
                    deviceTarget: deviceTarget)
            case .invalid:
                return FapCompatibility.classify(
                    nil,
                    deviceApiMajor: deviceApiMajor,
                    deviceTarget: deviceTarget)
            }
        }
    }

    static func isInstallable(
        _ update: PluginUpdate,
        classifications: [String: FapCompatibilityState]
    ) -> Bool {
        classifications[update.remotePath]?.isInstallable == true
    }

    static func deselectBlocked(
        _ updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices
        where !isInstallable(updates[index], classifications: classifications) {
            updates[index].selected = false
        }
    }

    static func selectedInstallable(
        _ updates: [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) -> [PluginUpdate] {
        updates.filter {
            $0.selected && isInstallable($0, classifications: classifications)
        }
    }

    static func setSelected(
        _ selected: Bool,
        id: PluginUpdate.ID,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        guard let index = updates.firstIndex(where: { $0.id == id }) else { return }
        updates[index].selected = selected && isInstallable(
            updates[index], classifications: classifications)
    }

    static func setSelected(
        _ selected: Bool,
        where matches: (PluginUpdate) -> Bool,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices where matches(updates[index]) {
            updates[index].selected = selected && isInstallable(
                updates[index], classifications: classifications)
        }
    }

    static func selectOnly(
        where matches: (PluginUpdate) -> Bool,
        updates: inout [PluginUpdate],
        classifications: [String: FapCompatibilityState]
    ) {
        for index in updates.indices {
            updates[index].selected = matches(updates[index]) && isInstallable(
                updates[index], classifications: classifications)
        }
    }
}

enum UpdaterPhase: Equatable {
    case idle, fetching, downloading, needsBaseline
    case scanning(Int, Int), installing(Int, Int), cleaning(Int, Int), verifying(Int, Int)
    case done(String), failed(String)
}

/// Outcome of a signature check — either the per-file verification done during an
/// install, or an on-demand "Verify on device" re-hash of the whole pack.
struct VerifyResult: Equatable {
    enum Kind { case postInstall, onDevice }
    let kind: Kind
    let tag: String
    let verified: Int
    let failed: [String]   // "name: reason" for files that didn't match on device
    var ok: Bool { failed.isEmpty }
}

/// Outcome of an explicit legacy-route cleanup. A path is removed only after both its
/// canonical replacement and its own historical pack identity are verified.
struct CleanupResult: Equatable {
    let removed: [String]   // obsolete paths deleted after exact pack-history verification
    let kept: [String]      // paths kept because safe removal could not be proven/completed
    var isEmpty: Bool { removed.isEmpty && kept.isEmpty }
}

/// Persistent Community Pack baseline plus content-addressed routes retired by a
/// newer catalog. Version 2 caches contained only `tag` and `map`; the custom decoder
/// keeps those installations compatible while making route history explicit.
struct PluginCatalogCache: Codable, Equatable {
    var tag: String
    var map: [String: String]
    /// Content identities keyed by stable app ID + pack. Unlike `map`, these keys
    /// survive a Community Pack category/path move and are used only to migrate an
    /// existing baseline; route cleanup continues to use the path map and history.
    var appHashes: [String: String]
    private(set) var retiredRoutes: [String: [String]]

    init(
        tag: String,
        map: [String: String],
        appHashes: [String: String] = [:],
        retiredRoutes: [String: [String]] = [:]
    ) {
        self.tag = tag
        self.map = map
        self.appHashes = appHashes
        self.retiredRoutes = retiredRoutes.mapValues(Self.normalizedMD5s)
    }

    private enum CodingKeys: String, CodingKey {
        case tag, map, appHashes = "app_hashes"
        case retiredRoutes = "retired_routes"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tag = try values.decode(String.self, forKey: .tag)
        map = try values.decode([String: String].self, forKey: .map)
        appHashes = try values.decodeIfPresent(
            [String: String].self,
            forKey: .appHashes
        ) ?? [:]
        retiredRoutes = try values.decodeIfPresent(
            [String: [String]].self,
            forKey: .retiredRoutes
        )?.mapValues(Self.normalizedMD5s) ?? [:]
    }

    /// Returns the last known content identity for an app, first using the new
    /// identity index and then falling back to v2 path entries. The fallback is
    /// accepted only when one unambiguous hash exists for that app ID; two different
    /// binaries with the same basename fail closed and remain visible for review.
    func md5(for update: PluginUpdate) -> String? {
        let identityKey = PluginRouteReconciliation.cacheIdentityKey(for: update)
        if let value = appHashes[identityKey] { return value }
        if let value = map[update.remotePath] { return value }
        let routeIdentity = PluginRouteReconciliation.pathIdentity(update.remotePath)
        if let value = map.first(where: {
            PluginRouteReconciliation.pathIdentity($0.key) == routeIdentity
        })?.value {
            return value
        }

        let appID = PluginInstallRouting.appID(for: update.remotePath)
        let artifactExtension = (update.remotePath as NSString).pathExtension.lowercased()
        let belongsToArtifact: (String) -> Bool = { path in
            !path.hasPrefix("appid:") &&
            PluginInstallRouting.appID(for: path) == appID &&
            (path as NSString).pathExtension.lowercased() == artifactExtension
        }
        let matches = map.compactMap { path, value -> String? in
            guard belongsToArtifact(path) else { return nil }
            return value
        }
        let unique = Set(matches)
        if unique.count == 1 { return unique.first }

        // `reconcileRoutes` retires a moved path before the fast diff runs. Keep
        // that history useful for the first post-move check; otherwise the old
        // v2 cache would be interpreted as a brand-new app on every path move.
        let retired = retiredRoutes.compactMap { path, values -> [String]? in
            belongsToArtifact(path) ? values : nil
        }.flatMap { $0 }
        let retiredUnique = Set(retired)
        if retiredUnique.contains(update.newMD5) { return update.newMD5 }
        if retiredUnique.count == 1 { return retiredUnique.first }
        return retiredUnique.sorted().last
    }

    mutating func record(_ update: PluginUpdate) {
        map[update.remotePath] = update.newMD5
        appHashes[PluginRouteReconciliation.cacheIdentityKey(for: update)] = update.newMD5
    }

    /// Historical paths retained when an immutable catalog moved an artifact. They
    /// are read-only aliases for verification; deletion still requires the separate
    /// content-addressed cleanup gate.
    func retiredAliases(for update: PluginUpdate) -> [String] {
        let appID = PluginInstallRouting.appID(for: update.remotePath)
        let artifactExtension = (update.remotePath as NSString).pathExtension.lowercased()
        return retiredRoutes.keys.filter { path in
            PluginInstallRouting.appID(for: path) == appID &&
            (path as NSString).pathExtension.lowercased() == artifactExtension
        }.sorted()
    }

    /// Moves paths removed by the current immutable catalog out of the active
    /// baseline without losing the exact hashes that are safe to recognize later.
    /// A route that becomes active again is never considered a cleanup candidate.
    mutating func reconcileRoutes(current: [String: String]) {
        for path in current.keys {
            retiredRoutes.removeValue(forKey: path)
        }
        let retired = map.filter { current[$0.key] == nil }
        for (path, md5) in retired {
            var known = retiredRoutes[path] ?? []
            known.append(md5)
            retiredRoutes[path] = Self.normalizedMD5s(known)
            map.removeValue(forKey: path)
        }
    }

    mutating func forgetRetiredRoute(_ path: String) {
        retiredRoutes.removeValue(forKey: path)
    }

    private static func normalizedMD5s(_ values: [String]) -> [String] {
        Array(Set(
            values.map { $0.lowercased() }
                .filter(PluginRouteReconciliation.isMD5)
        )).sorted()
    }
}

struct PluginRouteCleanupCandidate: Codable, Equatable {
    let catalogPath: String
    let canonicalPath: String
    let legacyPath: String
    let canonicalMD5: String
    let acceptedLegacyMD5s: [String]
}

/// Cleanup recovery is intentionally independent from the Community Pack baseline.
/// Resetting/reseeding that baseline must not orphan a `.ucobsolete` marker left by a
/// device or app crash. The journal contains only validated exact paths and hashes.
struct PluginRouteCleanupJournalStore {
    private let defaults: UserDefaults
    private let key: String
    private var activeKey: String { key + ".active-staging" }

    init(
        defaults: UserDefaults = .standard,
        key: String = "pluginRouteCleanupJournal.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [PluginRouteCleanupCandidate] {
        let decoded: [PluginRouteCleanupCandidate]
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(
                [PluginRouteCleanupCandidate].self,
                from: data
           ) {
            decoded = stored
        } else {
            decoded = []
        }
        return PluginRouteReconciliation.normalizedCandidates(
            decoded + [activeStagingCandidate()].compactMap { $0 }
        )
    }

    func recoveryPathIdentities() -> Set<String> {
        guard let candidate = activeStagingCandidate() else { return [] }
        return [PluginRouteReconciliation.pathIdentity(candidate.legacyPath)]
    }

    @discardableResult
    func markStaging(_ candidate: PluginRouteCleanupCandidate) -> Bool {
        guard let validated = PluginRouteReconciliation.normalizedCandidates([candidate]).first,
              let data = try? JSONEncoder().encode(validated) else { return false }
        defaults.set(data, forKey: activeKey)
        guard defaults.synchronize(), activeStagingCandidate() == validated else {
            return false
        }
        return true
    }

    @discardableResult
    func markPending(_ candidate: PluginRouteCleanupCandidate) -> Bool {
        guard let active = activeStagingCandidate(),
              PluginRouteReconciliation.pathIdentity(active.legacyPath)
                == PluginRouteReconciliation.pathIdentity(candidate.legacyPath) else { return true }
        defaults.removeObject(forKey: activeKey)
        return defaults.synchronize() && activeStagingCandidate() == nil
    }

    @discardableResult
    func record(_ candidates: [PluginRouteCleanupCandidate]) -> Bool {
        save(load() + candidates)
    }

    @discardableResult
    func remove(legacyPaths: [String]) -> Bool {
        let identities = Set(legacyPaths.map(PluginRouteReconciliation.pathIdentity))
        let saved = save(load().filter {
            !identities.contains(PluginRouteReconciliation.pathIdentity($0.legacyPath))
        })
        if let active = activeStagingCandidate(),
           identities.contains(PluginRouteReconciliation.pathIdentity(active.legacyPath)) {
            defaults.removeObject(forKey: activeKey)
            return saved && defaults.synchronize() && activeStagingCandidate() == nil
        }
        return saved
    }

    private func activeStagingCandidate() -> PluginRouteCleanupCandidate? {
        guard let data = defaults.data(forKey: activeKey),
              let decoded = try? JSONDecoder().decode(
                PluginRouteCleanupCandidate.self,
                from: data
              ) else { return nil }
        return PluginRouteReconciliation.normalizedCandidates([decoded]).first
    }

    private func save(_ candidates: [PluginRouteCleanupCandidate]) -> Bool {
        let normalized = PluginRouteReconciliation.normalizedCandidates(candidates)
        guard !normalized.isEmpty else {
            defaults.removeObject(forKey: key)
            return defaults.synchronize() && defaults.data(forKey: key) == nil
        }
        guard let data = try? JSONEncoder().encode(normalized) else { return false }
        defaults.set(data, forKey: key)
        guard defaults.synchronize(),
              let persisted = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(
                [PluginRouteCleanupCandidate].self,
                from: persisted
              ) else { return false }
        return PluginRouteReconciliation.normalizedCandidates(decoded) == normalized
    }
}

enum PluginRouteCleanupDecision: Equatable {
    case remove
    case missing
    case keep
}

struct PluginRouteCleanupExecution: Equatable {
    var removed: [String] = []
    var missing: [String] = []
    var rolledBack: [String] = []
    var kept: [String] = []
    var failures: [String] = []

    mutating func normalize() {
        removed = Array(Set(removed)).sorted()
        missing = Array(Set(missing)).sorted()
        rolledBack = Array(Set(rolledBack)).sorted()
        kept = Array(
            Set(kept).subtracting(removed).subtracting(missing).subtracting(rolledBack)
        ).sorted()
        failures = Array(Set(failures)).sorted()
    }
}

private struct PluginRouteCleanupFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Executes only exact-path cleanup candidates. The legacy file is first moved to a
/// durable sibling marker, then its hash and the canonical replacement are re-read
/// immediately before deletion. A crash leaves a recoverable marker for the next run;
/// a transport failure stops the sweep and leaves every unvisited route untouched.
enum PluginRouteCleanupExecutor {
    /// `shouldPreserve` is evaluated at each device-mutation boundary, rather than
    /// only while candidates are assembled. `beginIrreversibleMutation` keeps a
    /// successful policy request from interleaving with the small copy/remove or
    /// delete operation that follows. Long hash reads and recoverable staging stay
    /// outside that fence so the UI remains responsive.
    @MainActor
    static func execute(
        _ candidates: [PluginRouteCleanupCandidate],
        storage: any DeviceFileStore,
        stagedRecoveryPaths: Set<String> = [],
        rollbackOnlyPaths: Set<String> = [],
        shouldPreserve: ((PluginRouteCleanupCandidate) -> Bool)? = nil,
        beginIrreversibleMutation: (() -> Bool)? = nil,
        endIrreversibleMutation: (() -> Void)? = nil,
        didObserveNoStage: ((PluginRouteCleanupCandidate) -> Void)? = nil,
        willStage: ((PluginRouteCleanupCandidate) throws -> Void)? = nil,
        progress: ((Int, Int, String) -> Void)? = nil
    ) async -> PluginRouteCleanupExecution {
        let ordered = candidates.sorted {
            let lhsIdentity = PluginRouteReconciliation.pathIdentity($0.legacyPath)
            let rhsIdentity = PluginRouteReconciliation.pathIdentity($1.legacyPath)
            let lhsIsRecovery = stagedRecoveryPaths.contains(lhsIdentity)
            let rhsIsRecovery = stagedRecoveryPaths.contains(rhsIdentity)
            if lhsIsRecovery != rhsIsRecovery { return lhsIsRecovery }
            return lhsIdentity < rhsIdentity
        }
        var result = PluginRouteCleanupExecution()

        for (index, candidate) in ordered.enumerated() {
            progress?(index, ordered.count, candidate.legacyPath)
            defer { progress?(index + 1, ordered.count, candidate.legacyPath) }
            do {
                let stagedPath = cleanupStagePath(for: candidate)
                var canonicalMD5 = try await storage.checkedMD5(candidate.canonicalPath)
                var legacyMD5 = try await storage.checkedMD5(candidate.legacyPath)
                var stagedMD5 = try await storage.checkedMD5(stagedPath)
                let legacyIdentity = PluginRouteReconciliation.pathIdentity(
                    candidate.legacyPath
                )

                if stagedMD5 != nil,
                   !stagedRecoveryPaths.contains(legacyIdentity) {
                    result.kept.append(candidate.legacyPath)
                    result.failures.append(
                        "\(candidate.legacyPath): unowned recovery marker was preserved"
                    )
                    continue
                }

                // Protection may be enabled after a crash (or become built-in in a
                // newer app). An owned active marker still has to be reconciled, but
                // this path is rollback-only: never delete the protected legacy FAP.
                if rollbackOnlyPaths.contains(legacyIdentity)
                    || shouldPreserve?(candidate) == true {
                    if let stagedMD5 {
                        if legacyMD5 == nil {
                            guard isAcceptedLegacyMD5(stagedMD5, for: candidate) else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker is incomplete"
                                )
                            }
                            try await restore(
                                candidate: candidate,
                                stagedPath: stagedPath,
                                expectedMD5: stagedMD5,
                                storage: storage
                            )
                        } else {
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker remained"
                                )
                            }
                        }
                    }
                    didObserveNoStage?(candidate)
                    result.rolledBack.append(candidate.legacyPath)
                    continue
                }

                // Flipper's BLE rename is implemented as copy + remove. If the link
                // dies between those operations, both the source and marker survive.
                // A persisted cleanup journal proves the marker belongs to this exact
                // transaction. Heal a partial copy by discarding only the marker while
                // the exact source is intact; if both copies are complete, keep the
                // marker as rollback material and finish the interrupted transaction.
                if let currentLegacyMD5 = legacyMD5,
                   let currentStagedMD5 = stagedMD5 {
                    guard isAcceptedLegacyMD5(currentLegacyMD5, for: candidate) else {
                        throw PluginRouteCleanupFailure(
                            message: "legacy changed while recovery marker exists"
                        )
                    }

                    if !isAcceptedLegacyMD5(currentStagedMD5, for: candidate) {
                        try await storage.delete(stagedPath, recursive: false)
                        guard try await storage.checkedMD5(stagedPath) == nil else {
                            throw PluginRouteCleanupFailure(
                                message: "partial recovery marker remained"
                            )
                        }
                        stagedMD5 = nil
                        canonicalMD5 = try await storage.checkedMD5(
                            candidate.canonicalPath
                        )
                        legacyMD5 = try await storage.checkedMD5(candidate.legacyPath)
                    } else {
                        let verifiedCanonicalMD5 = try await storage.checkedMD5(
                            candidate.canonicalPath
                        )
                        let verifiedLegacyMD5 = try await storage.checkedMD5(
                            candidate.legacyPath
                        )
                        let verifiedStagedMD5 = try await storage.checkedMD5(stagedPath)
                        guard let verifiedLegacyMD5,
                              let verifiedStagedMD5,
                              isAcceptedLegacyMD5(verifiedLegacyMD5, for: candidate),
                              isAcceptedLegacyMD5(verifiedStagedMD5, for: candidate) else {
                            throw PluginRouteCleanupFailure(
                                message: "recovery copies changed during verification"
                            )
                        }

                        guard verifiedCanonicalMD5?.lowercased()
                                == candidate.canonicalMD5.lowercased() else {
                            // Roll back the interrupted copy while the exact source is
                            // still present. No installed FAP is removed in this path.
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw CocoaError(.fileWriteUnknown)
                            }
                            result.kept.append(candidate.legacyPath)
                            continue
                        }

                        if shouldPreserve?(candidate) == true {
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker remained"
                                )
                            }
                            didObserveNoStage?(candidate)
                            result.rolledBack.append(candidate.legacyPath)
                            continue
                        }

                        let removedLegacy = try await performIrreversibleMutation(
                            candidate: candidate,
                            shouldPreserve: shouldPreserve,
                            begin: beginIrreversibleMutation,
                            end: endIrreversibleMutation
                        ) {
                            try await storage.delete(candidate.legacyPath, recursive: false)
                        }
                        guard removedLegacy else {
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker remained"
                                )
                            }
                            didObserveNoStage?(candidate)
                            result.rolledBack.append(candidate.legacyPath)
                            continue
                        }
                        guard try await storage.checkedMD5(candidate.legacyPath) == nil else {
                            throw PluginRouteCleanupFailure(
                                message: "source remained after recovery delete"
                            )
                        }
                        canonicalMD5 = verifiedCanonicalMD5
                        legacyMD5 = nil
                        stagedMD5 = verifiedStagedMD5
                    }
                }

                if stagedMD5 == nil {
                    didObserveNoStage?(candidate)
                }

                // Recover an interrupted cleanup before considering a new move. The
                // marker is app-owned, but its bytes still need the same old-pack proof.
                if let stagedMD5 {
                    guard legacyMD5 == nil else { throw CocoaError(.fileWriteUnknown) }
                    guard PluginRouteReconciliation.decision(
                        for: candidate,
                        canonicalDeviceMD5: canonicalMD5,
                        legacyDeviceMD5: stagedMD5
                    ) == .remove else {
                        if isAcceptedLegacyMD5(stagedMD5, for: candidate) {
                            try await restore(
                                candidate: candidate,
                                stagedPath: stagedPath,
                                expectedMD5: stagedMD5,
                                storage: storage
                            )
                        } else {
                            throw PluginRouteCleanupFailure(
                                message: "recovery marker bytes are not an accepted old build"
                            )
                        }
                        result.kept.append(candidate.legacyPath)
                        continue
                    }

                    // The marker may have survived a previous app/device crash. Do
                    // not trust even the reads at the top of this iteration: repeat
                    // the two content proofs adjacently at the actual delete boundary.
                    let currentCanonicalMD5 = try await storage.checkedMD5(
                        candidate.canonicalPath
                    )
                    let currentStagedMD5 = try await storage.checkedMD5(stagedPath)
                    guard PluginRouteReconciliation.decision(
                        for: candidate,
                        canonicalDeviceMD5: currentCanonicalMD5,
                        legacyDeviceMD5: currentStagedMD5
                    ) == .remove else {
                        if let currentStagedMD5,
                           isAcceptedLegacyMD5(currentStagedMD5, for: candidate) {
                            try await restore(
                                candidate: candidate,
                                stagedPath: stagedPath,
                                expectedMD5: currentStagedMD5,
                                storage: storage
                            )
                        } else {
                            throw PluginRouteCleanupFailure(
                                message: "recovery marker changed during verification"
                            )
                        }
                        result.kept.append(candidate.legacyPath)
                        continue
                    }

                    if shouldPreserve?(candidate) == true {
                        try await restore(
                            candidate: candidate,
                            stagedPath: stagedPath,
                            expectedMD5: currentStagedMD5,
                            storage: storage
                        )
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }

                    let removedStage = try await performIrreversibleMutation(
                        candidate: candidate,
                        shouldPreserve: shouldPreserve,
                        begin: beginIrreversibleMutation,
                        end: endIrreversibleMutation
                    ) {
                        try await storage.delete(stagedPath, recursive: false)
                    }
                    guard removedStage else {
                        try await restore(
                            candidate: candidate,
                            stagedPath: stagedPath,
                            expectedMD5: currentStagedMD5,
                            storage: storage
                        )
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }
                    guard try await storage.checkedMD5(stagedPath) == nil else {
                        throw PluginRouteCleanupFailure(
                            message: "recovery marker remained after delete"
                        )
                    }
                    result.removed.append(candidate.legacyPath)
                    continue
                }

                guard legacyMD5 != nil else {
                    result.missing.append(candidate.legacyPath)
                    continue
                }
                switch PluginRouteReconciliation.decision(
                    for: candidate,
                    canonicalDeviceMD5: canonicalMD5,
                    legacyDeviceMD5: legacyMD5
                ) {
                case .missing:
                    result.missing.append(candidate.legacyPath)
                case .keep:
                    result.kept.append(candidate.legacyPath)
                case .remove:
                    if shouldPreserve?(candidate) == true {
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }

                    // The stage path was observed absent above. Persist ownership
                    // synchronously before copy+remove can create even partial bytes.
                    try willStage?(candidate)
                    let staged = try await performIrreversibleMutation(
                        candidate: candidate,
                        shouldPreserve: shouldPreserve,
                        begin: beginIrreversibleMutation,
                        end: endIrreversibleMutation
                    ) {
                        try await storage.move(candidate.legacyPath, to: stagedPath)
                    }
                    guard staged else {
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }

                    // Re-read both identities after the move. If anything changed,
                    // restore the exact legacy bytes instead of deleting the marker.
                    let currentCanonicalMD5 = try await storage.checkedMD5(
                        candidate.canonicalPath
                    )
                    let currentLegacyMD5 = try await storage.checkedMD5(
                        candidate.legacyPath
                    )
                    let currentStagedMD5 = try await storage.checkedMD5(stagedPath)
                    if let currentLegacyMD5, let currentStagedMD5 {
                        guard isAcceptedLegacyMD5(currentLegacyMD5, for: candidate),
                              isAcceptedLegacyMD5(currentStagedMD5, for: candidate),
                              currentCanonicalMD5?.lowercased()
                                == candidate.canonicalMD5.lowercased() else {
                            throw PluginRouteCleanupFailure(
                                message: "copy-and-remove did not finish safely"
                            )
                        }

                        if shouldPreserve?(candidate) == true {
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker remained"
                                )
                            }
                            didObserveNoStage?(candidate)
                            result.rolledBack.append(candidate.legacyPath)
                            continue
                        }

                        let removedLegacy = try await performIrreversibleMutation(
                            candidate: candidate,
                            shouldPreserve: shouldPreserve,
                            begin: beginIrreversibleMutation,
                            end: endIrreversibleMutation
                        ) {
                            try await storage.delete(candidate.legacyPath, recursive: false)
                        }
                        guard removedLegacy else {
                            try await storage.delete(stagedPath, recursive: false)
                            guard try await storage.checkedMD5(stagedPath) == nil else {
                                throw PluginRouteCleanupFailure(
                                    message: "protected recovery marker remained"
                                )
                            }
                            didObserveNoStage?(candidate)
                            result.rolledBack.append(candidate.legacyPath)
                            continue
                        }
                        guard try await storage.checkedMD5(candidate.legacyPath) == nil else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    guard PluginRouteReconciliation.decision(
                        for: candidate,
                        canonicalDeviceMD5: currentCanonicalMD5,
                        legacyDeviceMD5: currentStagedMD5
                    ) == .remove else {
                        try await restore(
                            candidate: candidate,
                            stagedPath: stagedPath,
                            expectedMD5: legacyMD5,
                            storage: storage
                        )
                        result.kept.append(candidate.legacyPath)
                        result.failures.append(
                            "\(candidate.legacyPath): device bytes changed during cleanup"
                        )
                        continue
                    }

                    if shouldPreserve?(candidate) == true {
                        try await restore(
                            candidate: candidate,
                            stagedPath: stagedPath,
                            expectedMD5: legacyMD5,
                            storage: storage
                        )
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }

                    let removedStage = try await performIrreversibleMutation(
                        candidate: candidate,
                        shouldPreserve: shouldPreserve,
                        begin: beginIrreversibleMutation,
                        end: endIrreversibleMutation
                    ) {
                        try await storage.delete(stagedPath, recursive: false)
                    }
                    guard removedStage else {
                        try await restore(
                            candidate: candidate,
                            stagedPath: stagedPath,
                            expectedMD5: legacyMD5,
                            storage: storage
                        )
                        didObserveNoStage?(candidate)
                        result.rolledBack.append(candidate.legacyPath)
                        continue
                    }
                    guard try await storage.checkedMD5(stagedPath) == nil else {
                        throw PluginRouteCleanupFailure(
                            message: "recovery marker remained after delete"
                        )
                    }
                    result.removed.append(candidate.legacyPath)
                }
            } catch {
                result.kept.append(contentsOf: ordered[index...].map(\.legacyPath))
                result.failures.append(
                    "\(candidate.legacyPath): \(error.localizedDescription)"
                )
                break
            }
        }
        result.normalize()
        return result
    }

    static func cleanupStagePath(for candidate: PluginRouteCleanupCandidate) -> String {
        candidate.legacyPath + ".ucobsolete"
    }

    @MainActor
    private static func performIrreversibleMutation(
        candidate: PluginRouteCleanupCandidate,
        shouldPreserve: ((PluginRouteCleanupCandidate) -> Bool)?,
        begin: (() -> Bool)?,
        end: (() -> Void)?,
        operation: () async throws -> Void
    ) async throws -> Bool {
        guard shouldPreserve?(candidate) != true else { return false }
        guard begin?() ?? true else {
            throw PluginRouteCleanupFailure(
                message: "another Community mutation owns the protection fence"
            )
        }
        defer { end?() }
        guard shouldPreserve?(candidate) != true else { return false }
        try await operation()
        return true
    }

    private static func isAcceptedLegacyMD5(
        _ md5: String,
        for candidate: PluginRouteCleanupCandidate
    ) -> Bool {
        candidate.acceptedLegacyMD5s.contains(md5.lowercased())
    }

    private static func restore(
        candidate: PluginRouteCleanupCandidate,
        stagedPath: String,
        expectedMD5: String?,
        storage: any DeviceFileStore
    ) async throws {
        guard try await storage.checkedMD5(candidate.legacyPath) == nil else {
            return
        }
        try await storage.move(stagedPath, to: candidate.legacyPath)
        guard try await storage.checkedMD5(candidate.legacyPath) == expectedMD5,
              try await storage.checkedMD5(stagedPath) == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Derives obsolete FAP routes from immutable Community Pack history. No folder or
/// release-specific deletion list is trusted: a move needs a unique same-name app in
/// the current catalog, a retired old route, and exact content identities on device.
enum PluginRouteReconciliation {
    /// Stable cache key for a catalog binary. The pack and extension components
    /// prevent same-basename FAP/FAL artifacts from sharing a baseline.
    static func cacheIdentityKey(for update: PluginUpdate) -> String {
        let ext = (update.remotePath as NSString).pathExtension.lowercased()
        return "appid:\(pathIdentity(update.pack)):\(PluginInstallRouting.appID(for: update.remotePath)).\(ext)"
    }

    static func candidates(
        current: [PluginUpdate],
        retiredRoutes: [String: [String]],
        excluded: Set<String>,
        unprotectedBuiltIns: Set<String>,
        includeInstallRoutes: Bool = true
    ) -> [String: [PluginRouteCleanupCandidate]] {
        let eligible = current.filter {
            isSafeFAPPath($0.remotePath)
                && isSafeFAPPath($0.targetPath)
                && !PluginProtectionPolicy.isProtected(
                    name: $0.name,
                    remotePath: $0.targetPath,
                    excluded: excluded,
                    unprotectedBuiltIns: unprotectedBuiltIns)
        }
        let currentCatalogPaths = Set(current.map { pathIdentity($0.remotePath) })
        let canonicalPaths = Set(current.map { pathIdentity($0.targetPath) })
        let byStem = Dictionary(grouping: eligible, by: { stem($0.remotePath) })
        var proposals: [PluginRouteCleanupCandidate] = []

        for (legacyPath, historicalMD5s) in retiredRoutes {
            let appStem = stem(legacyPath)
            let legacyIdentity = pathIdentity(legacyPath)
            guard isSafeFAPPath(legacyPath),
                  !currentCatalogPaths.contains(legacyIdentity),
                  !canonicalPaths.contains(legacyIdentity),
                  !PluginProtectionPolicy.isProtected(
                    name: appStem,
                    remotePath: legacyPath,
                    excluded: excluded,
                    unprotectedBuiltIns: unprotectedBuiltIns),
                  let matches = byStem[appStem], matches.count == 1,
                  let update = matches.first else { continue }
            appendCandidate(
                catalogPath: update.remotePath,
                canonicalPath: update.targetPath,
                legacyPath: legacyPath,
                canonicalMD5: update.newMD5,
                acceptedLegacyMD5s: historicalMD5s,
                to: &proposals
            )
        }

        // Preserve the small set of intentional Tumoflip install routes. These
        // predate cache history, so only a byte-identical old copy is accepted.
        if includeInstallRoutes {
            for update in eligible {
                for legacyPath in PluginInstallRouting.legacyPaths(for: update.remotePath)
                where legacyPath != update.targetPath {
                    appendCandidate(
                        catalogPath: update.remotePath,
                        canonicalPath: update.targetPath,
                        legacyPath: legacyPath,
                        canonicalMD5: update.newMD5,
                        acceptedLegacyMD5s: (retiredRoutes[legacyPath] ?? []) + [update.newMD5],
                        to: &proposals
                    )
                }
            }
        }

        // If two catalog entries claim one old path, fail closed instead of choosing.
        let unambiguous = Dictionary(
            grouping: proposals,
            by: { pathIdentity($0.legacyPath) }
        ).values.compactMap {
            group -> PluginRouteCleanupCandidate? in
            let identities = Set(group.map {
                "\($0.catalogPath)\u{0}\($0.canonicalPath)\u{0}\($0.canonicalMD5)"
            })
            guard identities.count == 1, let first = group.first else { return nil }
            let accepted = Array(Set(group.flatMap(\.acceptedLegacyMD5s))).sorted()
            return PluginRouteCleanupCandidate(
                catalogPath: first.catalogPath,
                canonicalPath: first.canonicalPath,
                legacyPath: first.legacyPath,
                canonicalMD5: first.canonicalMD5,
                acceptedLegacyMD5s: accepted
            )
        }
        return Dictionary(grouping: unambiguous, by: \.catalogPath).mapValues {
            $0.sorted { $0.legacyPath < $1.legacyPath }
        }
    }

    /// Validates persisted candidates again on every load and collapses duplicate
    /// journal/cache entries. Conflicting claims for one FAT path are discarded.
    static func normalizedCandidates(
        _ candidates: [PluginRouteCleanupCandidate]
    ) -> [PluginRouteCleanupCandidate] {
        let validated = candidates.compactMap { candidate -> PluginRouteCleanupCandidate? in
            guard isSafeFAPPath(candidate.catalogPath) else { return nil }
            var result: [PluginRouteCleanupCandidate] = []
            appendCandidate(
                catalogPath: candidate.catalogPath,
                canonicalPath: candidate.canonicalPath,
                legacyPath: candidate.legacyPath,
                canonicalMD5: candidate.canonicalMD5,
                acceptedLegacyMD5s: candidate.acceptedLegacyMD5s,
                to: &result
            )
            return result.first
        }
        return Dictionary(grouping: validated, by: { pathIdentity($0.legacyPath) })
            .values.compactMap { group -> PluginRouteCleanupCandidate? in
                let identities = Set(group.map {
                    pathIdentity($0.catalogPath) + "\u{0}"
                        + pathIdentity($0.canonicalPath) + "\u{0}"
                        + $0.canonicalMD5.lowercased()
                })
                guard identities.count == 1, let first = group.first else { return nil }
                return PluginRouteCleanupCandidate(
                    catalogPath: first.catalogPath,
                    canonicalPath: first.canonicalPath,
                    legacyPath: first.legacyPath,
                    canonicalMD5: first.canonicalMD5.lowercased(),
                    acceptedLegacyMD5s: Array(Set(
                        group.flatMap(\.acceptedLegacyMD5s).map { $0.lowercased() }
                    )).filter(isMD5).sorted()
                )
            }
            .sorted { pathIdentity($0.legacyPath) < pathIdentity($1.legacyPath) }
    }

    static func decision(
        for candidate: PluginRouteCleanupCandidate,
        canonicalDeviceMD5: String?,
        legacyDeviceMD5: String?
    ) -> PluginRouteCleanupDecision {
        guard canonicalDeviceMD5?.lowercased() == candidate.canonicalMD5.lowercased() else {
            return .keep
        }
        guard let legacyDeviceMD5 else { return .missing }
        return candidate.acceptedLegacyMD5s.contains(legacyDeviceMD5.lowercased())
            ? .remove : .keep
    }

    static func isMD5(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func appendCandidate(
        catalogPath: String,
        canonicalPath: String,
        legacyPath: String,
        canonicalMD5: String,
        acceptedLegacyMD5s: [String],
        to proposals: inout [PluginRouteCleanupCandidate]
    ) {
        let canonical = canonicalMD5.lowercased()
        let accepted = Array(Set(
            acceptedLegacyMD5s.map { $0.lowercased() }
                .filter(isMD5)
        )).sorted()
        guard isSafeFAPPath(canonicalPath),
              isSafeFAPPath(legacyPath),
              pathIdentity(canonicalPath) != pathIdentity(legacyPath),
              isMD5(canonical),
              !accepted.isEmpty else { return }
        proposals.append(PluginRouteCleanupCandidate(
            catalogPath: catalogPath,
            canonicalPath: canonicalPath,
            legacyPath: legacyPath,
            canonicalMD5: canonical,
            acceptedLegacyMD5s: accepted
        ))
    }

    private static func stem(_ path: String) -> String {
        (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    /// Flipper SD storage is FAT-backed, so path identity is case-insensitive even
    /// when the spelling returned by a manifest or cache differs. Never compare raw
    /// strings when deciding whether one path may be deleted in favor of another.
    static func pathIdentity(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isSafeFAPPath(_ path: String) -> Bool {
        let identity = pathIdentity(path)
        let roots = ["/ext/apps/", "/ext/apps_data/"]
        guard let root = roots.first(where: { identity.hasPrefix($0) }),
              identity.hasSuffix(".fap") else {
            return false
        }
        let suffix = identity.dropFirst(root.count)
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

struct InstallRecord: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let tag: String
    let name: String
    let pack: String
    let wasNew: Bool
}

/// The Community installer and standalone cleanup mutate overlapping SD paths. UI
/// disabling is not synchronization, so both entry points acquire this main-actor gate
/// synchronously before their first suspension point.
@MainActor
final class PluginTransactionGate {
    private(set) var isActive = false

    func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func end() {
        isActive = false
    }
}

/// Linearizes protection changes with only the short irreversible part of a Community
/// mutation. Long downloads, hashes, and recoverable staging remain interruptible;
/// requests made inside the live delete/swap window are not acknowledged and can be
/// retried immediately afterwards.
@MainActor
final class PluginProtectionMutationGate {
    private(set) var isActive = false

    func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func end() {
        isActive = false
    }
}

/// One dated build in the all-the-plugins release history — xMasterX sometimes ships
/// a same-day follow-up (tag suffixed "p2", "p3", …) when the first cut needed a fix,
/// so "latest" isn't always the only build worth offering; `hasPacks` excludes any
/// release whose base/extra zip assets are missing (a botched or in-progress upload).
struct PluginReleaseInfo: Identifiable, Equatable {
    let tag: String
    let publishedAt: Date
    let hasPacks: Bool
    var id: String { tag }
}

/// Protected apps are intentionally not overwritten by all-the-plugins, but we
/// still surface their upstream/device state so important fixes are not hidden.
struct ProtectedPluginReview: Identifiable, Equatable {
    let remotePath: String
    let targetPath: String
    let name: String
    let category: String
    let pack: String
    let newMD5: String
    let deviceMD5: String?
    /// Whether the device probe completed successfully. A successful probe with
    /// `deviceMD5 == nil` means the protected upstream path is absent, not that
    /// the device is still unknown.
    let deviceKnown: Bool
    let size: Int

    var id: String { remotePath }
    var isRouted: Bool { targetPath != remotePath }
    var targetCategory: String {
        let parent = (targetPath as NSString).deletingLastPathComponent
        return (parent as NSString).lastPathComponent
    }
}

/// Live progress for the file currently being written, so the UI can show a
/// real moving bar instead of an indeterminate spinner.
struct InstallDetail: Equatable {
    var name: String
    var sent: Int
    var total: Int
    var attempt: Int   // 1-based; >1 means we're retrying after a link blip
    var channel: TransferChannel = .ble
}

/// Pulls the latest all-the-plugins build straight from xMasterX's public GitHub
/// releases, fingerprints every .fap and installs ONLY the ones that changed
/// since the last sync — base + extra packs.
@MainActor
final class PluginUpdater: ObservableObject {
    @Published var phase: UpdaterPhase = .idle
    @Published var tag = ""
    @Published private(set) var updates: [PluginUpdate] = []
    /// Set after a device scan: how many apps DIFFER from the pack (these may be
    /// your own modifications, so they default to unselected pending review).
    @Published var changedFromScan = 0
    /// App name-stems (lowercased, no .fap) the updater must NEVER touch — your
    /// locally-modified builds. They're skipped entirely: not shown, not written.
    @Published private(set) var excluded: Set<String> = []
    /// Built-in protections the user has explicitly lifted. A name here is no longer
    /// protected even though it's in `builtInExcluded`, so all-the-plugins may overwrite it.
    @Published private(set) var unprotectedBuiltIns: Set<String> = []
    /// Protected apps present in the upstream pack, compared against the device.
    @Published var protectedReviews: [ProtectedPluginReview] = []
    /// Automation-owned decision for the exact release tag + base/extra archive bytes.
    /// A missing decision is surfaced once as a global audit failure; individual rows
    /// remain UNVERIFIED until an authoritative comparison is available.
    @Published private(set) var protectedAuditResolution: ProtectedPluginAuditResolution?
    private let protectedAuditService: ProtectedPluginAuditService
    private let cleanupJournalStore: PluginRouteCleanupJournalStore
    private let persistenceDefaults: UserDefaults
    private let protectionMutationGate: PluginProtectionMutationGate
    /// Exact archive identity retained for the loaded catalog. The audit can be
    /// published after the Community Pack was downloaded, so every later device
    /// verification must be able to re-resolve this same immutable identity without
    /// downloading or guessing the pack again.
    private var protectedAuditProvenance: ProtectedPluginPackProvenance?
    /// Latest-started-wins token. Prevents a slow stale response from overwriting a
    /// newer resolution, both across catalog switches and for the same exact pack.
    private var protectedAuditGeneration: UInt64 = 0
    private var protectedAuditResolutionTask: Task<ProtectedPluginAuditResolution, Never>?
    /// Protected items that genuinely need a look: device state unknown yet, or the
    /// upstream bytes/route are not covered by the exact automation-owned audit ledger.
    /// Shared by the Updates "More" subtitle and the Protected Apps screen.
    var pendingProtectedReview: [ProtectedPluginReview] {
        protectedReviews.filter {
            protectedReviewStatus($0) == .needsReview
        }
    }
    /// These rows have not received a completed device probe yet. They need a
    /// device check, not a human provenance decision, so the UI must never
    /// present them as a DIFF.
    var protectedDeviceCheckReviews: [ProtectedPluginReview] {
        pendingProtectedReview.filter { !$0.deviceKnown }
    }
    /// These rows were actually compared with the device and still need a review.
    var protectedDeviceDiffReviews: [ProtectedPluginReview] {
        pendingProtectedReview.filter(\.deviceKnown)
    }
    /// Rows whose bytes cannot be classified because the centralized ledger itself
    /// is unavailable or invalid. These are deliberately not DIFFs: no authoritative
    /// comparison was possible.
    var unverifiedProtectedReviews: [ProtectedPluginReview] {
        guard protectedAuditFailure != nil else { return [] }
        return protectedReviews.filter { protectedReviewStatus($0) == .unverified }
    }
    var protectedAuditFailure: ProtectedPluginAuditResolution? {
        guard let resolution = protectedAuditResolution,
              !resolution.allowsCurrentVerdicts else { return nil }
        return resolution
    }
    /// Expected Tumoflip differences covered by the exact current pack audit. They stay
    /// visible for provenance, but no longer create a false Needs review / DIFF alert.
    var auditedProtectedReviews: [ProtectedPluginReview] {
        protectedReviews.filter { protectedReviewStatus($0).isAudited }
    }
    @Published var history: [InstallRecord] = PluginUpdater.loadHistory()
    /// Per-file write progress for the install currently in flight (nil when idle).
    @Published var installDetail: InstallDetail?
    /// Result of the last install verification or on-device verify (nil until one runs).
    @Published var verifyResult: VerifyResult?
    /// Result of the last explicit legacy-route cleanup transaction.
    @Published var lastCleanup: CleanupResult?
    /// Immutable-history route moves that can be checked in a standalone cleanup.
    /// No device path is touched until the user starts the separate transaction.
    @Published private(set) var pendingRouteCleanup: [PluginRouteCleanupCandidate] = []
    /// nil = always use GitHub's "latest" release; set = pin to this exact tag (e.g. to
    /// pick up a same-day "p2" follow-up that "latest" hasn't reflected yet, or to roll
    /// back to a known-good build). Persisted so the pin survives relaunches.
    @Published var manualReleaseTag: String? = PluginUpdater.loadManualReleaseTag()
    @Published var availableReleases: [PluginReleaseInfo] = []
    @Published var loadingReleases = false

    init(
        protectedAuditService: ProtectedPluginAuditService = .live(),
        cleanupJournalStore: PluginRouteCleanupJournalStore = .init(),
        persistenceDefaults: UserDefaults = .standard,
        protectionMutationGate: PluginProtectionMutationGate? = nil
    ) {
        self.protectedAuditService = protectedAuditService
        self.cleanupJournalStore = cleanupJournalStore
        self.persistenceDefaults = persistenceDefaults
        self.protectionMutationGate = protectionMutationGate
            ?? PluginProtectionMutationGate()
        excluded = Self.loadExcluded(defaults: persistenceDefaults)
        unprotectedBuiltIns = Self.loadUnprotected(defaults: persistenceDefaults)
        pendingRouteCleanup = eligibleJournalCleanupCandidates()
    }

    func protectedReviewStatus(_ review: ProtectedPluginReview) -> ProtectedPluginReviewAuditStatus {
        ProtectedPluginReviewPolicy.status(
            review,
            compatibility: classification(review.remotePath),
            audit: protectedAuditResolution?.audit,
            allowsCurrentVerdicts: protectedAuditResolution?.allowsCurrentVerdicts ?? false)
    }

    var shouldLoadCatalog: Bool {
        if case .idle = phase { return updates.isEmpty && tag.isEmpty }
        return false
    }

    /// Whether an on-device "Verify on device" pass can run — needs the pack manifest
    /// loaded by a prior check (so we know expected md5s and have data to reinstall).
    var canVerifyOnDevice: Bool { !allManifest.isEmpty }

    private let repo = "xMasterX/all-the-plugins"
    private static let excludedKey = "pluginExcluded"
    static let builtInExcluded: Set<String> = [
        "ai_dashboard",
        "app_bridge_terminal",
        "arf_car_emulate",
        "arf_counter_bf",
        "arf_frequency_analyzer",
        "arf_keeloq",
        "arf_psa_decrypt",
        "arf_status",
        "arf_subghz",
        "arf_subghz_full",
        "ble_gatt_lab",
        "claude_buddy",
        "claude_remote_ble",
        "esp_flasher",
        "esp32_wifi_marauder",
        "field_logger",
        "flipper_companion",
        "flipper_relay",
        "flipper_xremote",
        "freq_analyzer_ext",
        "garage_door_remote",
        "keeloq_keystore_decryptor",
        "module_one_cockpit",
        "module_one_sensor_logger",
        "nfc_ccid_bridge",
        "protocol_compiler",
        "proto_pirate",
        "quac",
        "rolljam",
        "rolljam_standalone",
        "runtime_trace_viewer",
        "signal_workbench",
        "subghz_bruteforcer",
        "subghz_protocols",
        "subghz_raw_edit",
        "subghz_wardriving",
        "totp",
        "tumo_acceptance_suite",
        "tumo_ir_lab",
        "tumo_macro_deck",
        "tumocard_os",
        "tumofabric_node",
        "tumoflip_xremote",
        "tumoflip_packages",
        "tumokey",
        "tumokey_phase_a",
        "tumomodule_runtime",
        "tumonet_bench",
        "tumonet_gateway",
        "tumoscope",
        "tumoscript",
        "tumovgm_bridge",
        "tumovm_peripherals",
        "tumovm_poc",
        "usb_sd_mode",
        "wifi_map",
        "wifi_mapper",
    ]
    private static let retiredBuiltInExcluded: Set<String> = ["ble_killer"]

    var builtInProtectedNames: [String] {
        Self.builtInExcluded.sorted()
    }

    var customProtectedNames: [String] {
        excluded.subtracting(Self.builtInExcluded).sorted()
    }

    /// Effective protection: excluded AND not lifted via `unprotectedBuiltIns`.
    func isProtected(_ name: String) -> Bool {
        let n = name.lowercased()
        return excluded.contains(n) && !unprotectedBuiltIns.contains(n)
    }

    func isProtected(_ update: PluginUpdate) -> Bool {
        PluginProtectionPolicy.isProtected(
            name: update.name,
            remotePath: update.remotePath,
            excluded: excluded,
            unprotectedBuiltIns: unprotectedBuiltIns)
    }

    func isBuiltInUnprotected(_ name: String) -> Bool {
        unprotectedBuiltIns.contains(name.lowercased())
    }

    // Per-fap md5 of the pack state we last reconciled with the device.
    private let cacheKey = "pluginPackCache.v2"

    // Working files for the current check (kept for install pass).
    private var packURLs: [(pack: String, url: URL)] = []
    private var allManifest: [String: PluginUpdate] = [:]   // remotePath -> entry (no data)
    private var protectedManifest: [PluginUpdate] = []
    private let transactionGate = PluginTransactionGate()

#if DEBUG
    // Test-only seams for exercising the real check/install transaction without a
    // physical Flipper or a live GitHub release. They stay nil in every normal app
    // run, so production keeps using the active transfer channel and RPC identity.
    private var testingStorage: (any DeviceFileStore)?
    private var testingChannel: TransferChannel?
    private var testingDeviceIdentity: (api: Int?, target: Int?)?
    private var testingRelease: (tag: String, assets: [String: URL])?
    private var testingDownloads: [URL: URL] = [:]
#endif

    var selectedCount: Int { installableSelectedCount }
    var pendingCleanupCount: Int { pendingRouteCleanup.count }

    // MARK: - FAP/FAL compatibility (issue #19)

    /// Parsed `.fapmeta` for every catalog binary — computed ONCE during Check in the
    /// same archive pass that already MD5s each file. Covers base + extra and BOTH
    /// installable AND protected apps. Re-classification against a (re)connected device
    /// reuses this without re-downloading or re-parsing the archives.
    @Published private(set) var catalogMeta: [String: PluginCatalogMetadata] = [:]

    /// Fresh connected-firmware identity from the last classification (nil = unknown).
    @Published private(set) var deviceApiMajor: Int?
    @Published private(set) var deviceTarget: Int?

    /// Per-catalog-binary compatibility state (remotePath → state), recomputed from
    /// `catalogMeta` + the fresh device identity. The single source the UI, the selection
    /// policy, and the install gate all read.
    @Published private(set) var classifications: [String: FapCompatibilityState] = [:]
    @Published private(set) var validating = false

    func classification(_ remotePath: String) -> FapCompatibilityState {
        classifications[remotePath] ?? .unvalidated(FapCompatibility.unknownDeviceReason)
    }
    func isInstallable(_ u: PluginUpdate) -> Bool { classification(u.remotePath).isInstallable }
    func reason(_ u: PluginUpdate) -> String? { classification(u.remotePath).reason }

    /// `updates` split by installability, for the UI partition (installable categories vs
    /// the collapsed "Incompatible" section).
    var installableUpdates: [PluginUpdate] { updates.filter { isInstallable($0) } }
    var blockedUpdates: [PluginUpdate] { updates.filter { !isInstallable($0) } }

    /// Only installable AND selected — drives the install button count / plan. `selected`
    /// is kept ⊆ installable by the selection policy, but this stays defensive.
    var installableSelectedCount: Int {
        PluginSelectionPolicy.selectedInstallable(
            updates, classifications: classifications).count
    }

    // MARK: Selection policy — the UI never sets `.selected` directly; it routes through
    // these, which refuse to select unvalidated/incompatible entries.

    func setSelected(_ on: Bool, id: PluginUpdate.ID) {
        PluginSelectionPolicy.setSelected(
            on, id: id, updates: &updates, classifications: classifications)
    }
    func setSelected(_ on: Bool, where match: (PluginUpdate) -> Bool) {
        PluginSelectionPolicy.setSelected(
            on, where: match, updates: &updates, classifications: classifications)
    }
    func selectOnly(where match: (PluginUpdate) -> Bool) {
        PluginSelectionPolicy.selectOnly(
            where: match, updates: &updates, classifications: classifications)
    }

    /// Fresh device firmware API major + hardware target (both nil when unreachable). A
    /// stale cached identity is NEVER used as the install-time identity — this always
    /// reads device_info over a BLE-ready link.
    private func deviceApiTarget() async throws -> (api: Int?, target: Int?) {
#if DEBUG
        if let testingDeviceIdentity { return testingDeviceIdentity }
#endif
        guard FlipperBLE.shared.state == .ready else {
            throw FlipperRPCError.notReady
        }
        guard FlipperBLE.shared.serialOwner == .rpc else {
            throw FlipperRPCError.serialOwnedByClaudeBuddy
        }
        let info = try await FlipperSystem().deviceInfo()
        let dict = Dictionary(info, uniquingKeysWith: { a, _ in a })
        return (dict["firmware_api_major"].flatMap(Int.init), dict["hardware_target"].flatMap(Int.init))
    }

    private func fapCandidates(_ entries: [PluginUpdate]) -> [PackageCompatibilityGate.Candidate] {
        entries.map { update in
            PackageCompatibilityGate.Candidate(
                id: update.remotePath,
                target: update.targetPath,
                data: { self.extractData(remotePath: update.remotePath) })
        }
    }

    /// Re-read fresh device identity and re-classify the WHOLE catalog from the cached
    /// parsed metadata (no re-download / re-parse), then drop any now-blocked selection.
    /// Runs after every path that (re)builds `updates` — Check (Auto & pinned), first-run
    /// Scan, Verify on device — and on reconnect.
    func validateCompatibility() async {
        guard !catalogMeta.isEmpty else { classifications = [:]; return }
        // Don't re-classify while an install is in flight. A long install drops &
        // re-establishes BLE per app; each `ble.state` blip can re-fire centralized
        // revalidation, and during the reconnect an unavailable identity used to
        // flip every app to .unvalidated →
        // the category list collapses to just "incompatible" and back, thrashing the
        // card heights mid-animation (visible z-fight) and contending with the
        // transfer over RPC (issue #21). install() runs its own inline gate, so
        // skipping here loses nothing; the post-install .ready settle revalidates.
        switch phase {
        case .installing, .cleaning: return
        default: break
        }
        validating = true
        defer { validating = false }
        let api: Int?
        let target: Int?
        do {
            (api, target) = try await deviceApiTarget()
        } catch {
            // Keep the last known classification during a transient reconnect.
            // Install performs the same read again and remains fail-closed.
            return
        }
        deviceApiMajor = api
        deviceTarget = target
        classifications = PluginSelectionPolicy.classify(catalogMeta, deviceApiMajor: api, deviceTarget: target)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: classifications)
    }

    // MARK: - Check

    func check() async {
        do {
            phase = .fetching
            let (nextTag, assets) = try await latestRelease()

            phase = .downloading
            var manifest: [String: PluginUpdate] = [:]
            var protected: [PluginUpdate] = []
            var metadata: [String: PluginCatalogMetadata] = [:]
            var downloadedPacks: [(pack: String, url: URL)] = []
            var archiveSHA256: [String: String] = [:]
            for (pack, name) in [("base", "all-the-apps-base.zip"), ("extra", "all-the-apps-extra.zip")] {
                guard let asset = assets[name] else { continue }
                let url = try await download(asset, to: "atp-\(pack).zip")
                downloadedPacks.append((pack, url))
                archiveSHA256[pack] = try sha256(url)
                let extracted = try extractManifest(zipURL: url, pack: pack)
                metadata.merge(extracted.metadata) { _, new in new }
                for f in extracted.updates {
                    if isProtected(f) {
                        protected.append(f)
                        continue
                    }
                    manifest[f.remotePath] = f
                }
            }
            // Commit the new catalog only after every source archive was downloaded and
            // decoded. A transient GitHub/CDN failure must not erase the last good UI.
            tag = nextTag
            packURLs = downloadedPacks
            allManifest = manifest
            protectedManifest = sortUpdates(protected)
            catalogMeta = metadata
            updates = []
            changedFromScan = 0
            protectedReviews = []
            verifyResult = nil
            classifications = [:]
            setProtectedAuditProvenance(ProtectedPluginPackProvenance(
                sourceTag: nextTag,
                archiveSHA256: archiveSHA256))
            await refreshProtectedAudit()

            var cache = loadCache()
            if var reconciled = cache {
                reconciled.reconcileRoutes(
                    current: manifest.mapValues(\.newMD5)
                )
                saveCache(reconciled)
                cache = reconciled
            }
            if var cache {
                // Fast path: diff the new pack against what we last reconciled.
                var result: [PluginUpdate] = []
                for (path, f) in manifest {
                    let knownMD5 = cache.md5(for: f)
                    if knownMD5 != f.newMD5 {
                        var update = PluginUpdate(
                            remotePath: path,
                            name: f.name,
                            category: f.category,
                            pack: f.pack,
                            newMD5: f.newMD5,
                            oldMD5: knownMD5,
                            size: f.size)
                        // New all-the-plugins entries should be reviewed manually; otherwise
                        // a broad pack update can quietly fill the SD with duplicates.
                        update.selected = knownMD5 != nil
                        result.append(update)
                    } else if cache.map[path] != f.newMD5 ||
                                cache.appHashes[PluginRouteReconciliation.cacheIdentityKey(for: f)] != f.newMD5 {
                        // The bytes are already accepted, but the catalog moved the
                        // app or this cache predates the identity index. Persist the
                        // current path/key so the next release does not rediscover a
                        // false DIFF.
                        cache.record(f)
                    }
                }
                saveCache(cache)
                pendingRouteCleanup = cleanupCandidates(cache: cache)
                updates = sortUpdates(result)
                phase = updates.isEmpty ? .done("Everything up to date · \(nextTag)") : .idle
            } else {
                // No baseline yet — let the user choose how to seed it.
                pendingRouteCleanup = cleanupCandidates(cache: nil)
                phase = .needsBaseline
            }
            await validateCompatibility()
        } catch {
            if UpdateTaskCancellation.isCancellation(error) {
                if tag.isEmpty { phase = .idle }
                return
            }
            ulog.error("check failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func sortUpdates(_ r: [PluginUpdate]) -> [PluginUpdate] {
        r.sorted { ($0.pack, $0.category, $0.name) < ($1.pack, $1.category, $1.name) }
    }

    private func sortProtected(_ r: [ProtectedPluginReview]) -> [ProtectedPluginReview] {
        r.sorted { ($0.pack, $0.category, $0.name) < ($1.pack, $1.category, $1.name) }
    }

    private func standaloneCleanupCandidates(
        _ cache: PluginCatalogCache
    ) -> [PluginRouteCleanupCandidate] {
        PluginRouteReconciliation.candidates(
            current: Array(allManifest.values),
            retiredRoutes: cache.retiredRoutes,
            excluded: excluded,
            unprotectedBuiltIns: unprotectedBuiltIns,
            includeInstallRoutes: false
        ).values.flatMap { $0 }.sorted {
            PluginRouteReconciliation.pathIdentity($0.legacyPath)
                < PluginRouteReconciliation.pathIdentity($1.legacyPath)
        }
    }

    private func isCleanupAllowed(_ candidate: PluginRouteCleanupCandidate) -> Bool {
        let name = (((candidate.catalogPath as NSString).lastPathComponent as NSString)
            .deletingPathExtension)
        return !PluginProtectionPolicy.isProtected(
            name: name,
            remotePath: candidate.canonicalPath,
            excluded: excluded,
            unprotectedBuiltIns: unprotectedBuiltIns
        )
    }

    private func shouldPreserveDuringCleanup(
        _ candidate: PluginRouteCleanupCandidate
    ) -> Bool {
        return !isCleanupAllowed(candidate)
    }

    private func isProtectedAtInstallTarget(_ update: PluginUpdate) -> Bool {
        PluginProtectionPolicy.isProtected(
            name: update.name,
            remotePath: update.targetPath,
            excluded: excluded,
            unprotectedBuiltIns: unprotectedBuiltIns
        )
    }

    private func eligibleJournalCleanupCandidates() -> [PluginRouteCleanupCandidate] {
        let activePaths = cleanupJournalStore.recoveryPathIdentities()
        return cleanupJournalStore.load().filter {
            isCleanupAllowed($0)
                || activePaths.contains(
                    PluginRouteReconciliation.pathIdentity($0.legacyPath)
                )
        }
    }

    private func cleanupCandidates(
        cache: PluginCatalogCache?
    ) -> [PluginRouteCleanupCandidate] {
        let journal = eligibleJournalCleanupCandidates()
        let journalPaths = Set(journal.map {
            PluginRouteReconciliation.pathIdentity($0.legacyPath)
        })
        let historical = cache.map(standaloneCleanupCandidates) ?? []
        let newHistorical = historical.filter {
            !journalPaths.contains(PluginRouteReconciliation.pathIdentity($0.legacyPath))
        }
        return PluginRouteReconciliation.normalizedCandidates(journal + newHistorical)
    }

    /// Reads every known route for one app. The deliberate Tumoflip target remains
    /// authoritative when it exists; an alias is accepted only when that target is
    /// missing and its bytes match. Community Pack is free to move a FAP between
    /// categories, so checking only `targetPath` turns a valid alias installation
    /// into a false MISSING/DIFF without hiding a genuinely modified target.
    private func deviceObservation(
        for update: PluginUpdate,
        storage: any DeviceFileStore,
        cache: PluginCatalogCache? = nil
    ) async throws -> (path: String, md5: String?) {
        var firstFound: (path: String, md5: String)?
        var matchingAlias: (path: String, md5: String)?
        let targetIdentity = PluginRouteReconciliation.pathIdentity(update.targetPath)
        var candidates = PluginInstallRouting.candidatePaths(for: update.remotePath)
        candidates.append(contentsOf: cache?.retiredAliases(for: update) ?? [])
        var seen = Set<String>()
        for path in candidates where seen.insert(
            PluginRouteReconciliation.pathIdentity(path)
        ).inserted {
            guard let md5 = try await storage.checkedMD5(path) else { continue }
            if firstFound == nil { firstFound = (path, md5) }
            if PluginRouteReconciliation.pathIdentity(path) == targetIdentity {
                return (path, md5)
            }
            if md5.lowercased() == update.newMD5.lowercased(), matchingAlias == nil {
                matchingAlias = (path, md5)
            }
        }
        return matchingAlias ?? firstFound ?? (update.targetPath, nil)
    }

    private func refreshPendingRouteCleanup() {
        pendingRouteCleanup = cleanupCandidates(cache: loadCache())
    }

    private func setProtectedAuditProvenance(_ provenance: ProtectedPluginPackProvenance?) {
        protectedAuditResolutionTask?.cancel()
        protectedAuditResolutionTask = nil
        protectedAuditGeneration &+= 1
        protectedAuditProvenance = provenance
        protectedAuditResolution = nil
    }

    private func refreshProtectedAuditResolution(forceRemote: Bool = false) async {
        protectedAuditResolutionTask?.cancel()
        protectedAuditGeneration &+= 1
        let generation = protectedAuditGeneration
        guard let provenance = protectedAuditProvenance else {
            // Never retain an acceptance from a previously loaded pack when the
            // current archive identity is incomplete.
            protectedAuditResolution = .rejected(
                "Community Pack archive provenance is incomplete; protected apps remain unverified.")
            return
        }
        // resolve() remains fail-closed. A reachable exact authoritative audit is the
        // only path that clears a prior revocation tombstone; offline/cache fallback
        // cannot resurrect a revision that the ledger rejected.
        let service = protectedAuditService
        let task = Task {
            await service.resolve(for: provenance, forceRemote: forceRemote)
        }
        protectedAuditResolutionTask = task
        let resolution = await task.value
        guard generation == protectedAuditGeneration,
              provenance == protectedAuditProvenance else { return }
        protectedAuditResolutionTask = nil
        protectedAuditResolution = resolution
    }

    /// Refreshes both halves of the protected-app decision using one coherent pass:
    /// a cache-bypassing primary ledger read followed by current on-device MD5s.
    /// This is the normal catalog-refresh path, not an opt-in repair action.
    func refreshProtectedAudit() async {
        await refreshProtectedAuditResolution(forceRemote: true)
        await refreshProtectedReviews()
    }

    private func refreshProtectedReviews() async {
        guard !protectedManifest.isEmpty else {
            protectedReviews = []
            return
        }

        let items = protectedManifest
        let channel = activeChannel
        guard await fileChannelReady(channel, timeout: 2) else {
            protectedReviews = sortProtected(items.map {
                ProtectedPluginReview(
                    remotePath: $0.remotePath,
                    targetPath: $0.targetPath,
                    name: $0.name,
                    category: $0.category,
                    pack: $0.pack,
                    newMD5: $0.newMD5,
                    deviceMD5: nil,
                    deviceKnown: false,
                    size: $0.size)
            })
            return
        }

        let storage = activeStorage
        let cache = loadCache()
        var result: [ProtectedPluginReview] = []
        for f in items {
            let observation: (path: String, md5: String?)
            do {
                observation = try await deviceObservation(
                    for: f, storage: storage, cache: cache)
            } catch {
                protectedReviews = sortProtected(items.map {
                    ProtectedPluginReview(
                        remotePath: $0.remotePath,
                        targetPath: $0.targetPath,
                        name: $0.name,
                        category: $0.category,
                        pack: $0.pack,
                        newMD5: $0.newMD5,
                        deviceMD5: nil,
                        deviceKnown: false,
                        size: $0.size)
                })
                return
            }
            result.append(ProtectedPluginReview(
                remotePath: f.remotePath,
                targetPath: f.targetPath,
                name: f.name,
                category: f.category,
                pack: f.pack,
                newMD5: f.newMD5,
                deviceMD5: observation.md5,
                // `deviceObservation` returns nil when every candidate path is
                // absent. The successful RPC probe is still authoritative: for
                // an intentionally replaced upstream app this is the evidence
                // required to render REPLACED rather than CHECK.
                deviceKnown: true,
                size: f.size))
        }
        protectedReviews = sortProtected(result)
    }

    /// First-run option A: scan the Flipper so we flag exactly what's missing/old.
    func scanBaseline() async {
        let channel = activeChannel
        let storage = activeStorage
        let cache = loadCache()
        guard await fileChannelReady(channel) else {
            phase = .failed("Connect to the Flipper first, or select the SD card over USB.")
            return
        }
        let items = Array(allManifest.values)
        var result: [PluginUpdate] = []
        for (i, f) in items.enumerated() {
            if channel == .ble, ble().state != .ready {
                phase = .failed("Disconnected during scan")
                return
            }
            phase = .scanning(i + 1, items.count)
            let observation: (path: String, md5: String?)
            do {
                observation = try await deviceObservation(
                    for: f, storage: storage, cache: cache)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            if observation.md5?.lowercased() != f.newMD5.lowercased() {
                var u = PluginUpdate(remotePath: f.remotePath, name: f.name, category: f.category,
                                     pack: f.pack, newMD5: f.newMD5, oldMD5: observation.md5, size: f.size)
                // Differs-from-pack apps may be YOUR mods, and new pack entries can be
                // low-value duplicates. Leave both for explicit review.
                u.selected = false
                result.append(u)
            }
        }
        changedFromScan = result.filter { !$0.isNew }.count
        updates = sortUpdates(result)
        phase = updates.isEmpty ? .done("Everything up to date · \(tag)") : .idle
        await validateCompatibility()
    }

    /// First-run option B: assume the Flipper already has this build (e.g. just
    /// flashed via SD). Seeds the baseline instantly with no scan.
    func seedBaseline() {
        let map = allManifest.mapValues(\.newMD5)
        var cache = loadCache() ?? PluginCatalogCache(tag: tag, map: [:])
        cache.reconcileRoutes(current: map)
        cache.tag = tag
        cache.map = map
        cache.appHashes = allManifest.values.reduce(into: [:]) { hashes, update in
            hashes[PluginRouteReconciliation.cacheIdentityKey(for: update)] = update.newMD5
        }
        saveCache(cache)
        pendingRouteCleanup = cleanupCandidates(cache: cache)
        updates = []
        phase = .done("Baseline set · \(tag)")
    }

    private func ble() -> FlipperBLE { .shared }
    private var activeStorage: any DeviceFileStore {
#if DEBUG
        if let testingStorage { return testingStorage }
#endif
        return TransferChannelStore.shared.activeStore
    }
    var activeChannel: TransferChannel {
#if DEBUG
        if let testingChannel { return testingChannel }
#endif
        return TransferChannelStore.shared.activeChannel
    }

    private func fileChannelReady(_ channel: TransferChannel, timeout: Double? = nil) async -> Bool {
        switch channel {
        case .usb:
            return true
        case .ble:
            if let timeout {
                return await ble().waitUntilReady(timeout: timeout)
            }
            return await ble().waitUntilReady()
        }
    }

    // MARK: - Install

    /// Set by the Stop button. Checked at each file boundary in install(); the file
    /// currently being written always finishes and is md5-verified, so the app you
    /// pressed Stop on stays whole. Files not yet started keep their current version.
    @Published private(set) var stopRequested = false
    func requestStop() { stopRequested = true }

    func install() async {
        let requested = updates.filter(\.selected)
        guard !requested.isEmpty else { return }

        // `updates` is mutable UI state: protection can remove a row while this
        // async transaction is suspended, and unprotecting it does not fabricate a
        // new pending row without an ordinary Check. The only non-installed paths
        // allowed to retain/receive the current catalog MD5 are therefore paths whose
        // cache already matched the exact current catalog at transaction start.
        // Everything else needs either a verified live install below or another Check.
        var cache = loadCache() ?? PluginCatalogCache(tag: tag, map: [:])
        cache.reconcileRoutes(current: allManifest.mapValues(\.newMD5))
        let cacheVerifiedCurrentAtStart = Set(allManifest.compactMap { entry -> String? in
            let (path, update) = entry
            return cache.md5(for: update) == update.newMD5 ? path : nil
        })

        guard transactionGate.begin() else { return }
        defer { transactionGate.end() }
        stopRequested = false
        // Mark busy immediately so the Install button disables before any
        // await point — `phase` stayed `.idle` (not busy) through the
        // fileChannelReady/prepare waits below, letting a double-tap start a
        // second, fully overlapping install() run.
        phase = .installing(0, requested.count)
        let channel = activeChannel
        let storage = activeStorage
        guard await fileChannelReady(channel) else {
            phase = .failed("Flipper isn't ready — wait for the green “Connected & ready” status, select USB SD, then retry.")
            return
        }
        guard ble().serialOwner != .claudeBuddy else {
            phase = .failed(
                FlipperRPCError.serialOwnedByClaudeBuddy.localizedDescription
            )
            return
        }

        // Issue #19: reject any selected FAP/FAL whose embedded `.fapmeta` is
        // incompatible with the connected firmware. Read fresh device_info and gate
        // BEFORE the first storage write below, so nothing is written for a rejected
        // binary. Non-FAP data files keep their existing MD5/routing checks.
        let devApi: Int?
        let devTarget: Int?
        do {
            (devApi, devTarget) = try await deviceApiTarget()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        deviceApiMajor = devApi
        deviceTarget = devTarget
        classifications = PluginSelectionPolicy.classify(
            catalogMeta, deviceApiMajor: devApi, deviceTarget: devTarget)
        let rejected = PackageCompatibilityGate.blocked(
            fapCandidates(requested), deviceApiMajor: devApi, deviceTarget: devTarget)
        PluginSelectionPolicy.deselectBlocked(&updates, classifications: classifications)
        if !rejected.isEmpty {
            phase = .failed(PackageCompatibilityGate.summary(rejected))
            return
        }

        let selected = PluginSelectionPolicy.selectedInstallable(
            updates, classifications: classifications)
        guard !selected.isEmpty else {
            phase = .failed("No compatible apps selected.")
            return
        }

        var installed = Set<String>()      // verified on device
        var protectedSkipped = Set<String>()
        var failures: [String] = []
        verifyResult = nil
        lastCleanup = nil

        let live = InstallActivityController()
        let transferReporter = TransferActivityReporter(channel: channel)
        live.start(total: selected.count)
        // Give FAB2 a moment to finish negotiating after the link reaches
        // .ready before arming the on-device indicator — closes the small
        // ready -> FAB2-negotiated gap that could otherwise drop transfer_begin
        // silently (companion issue #18). Never blocks the install either way.
        _ = await transferReporter.prepare()
        transferReporter.begin("all-the-plugins")
        defer {
            transferReporter.end()
        }

        let maxAttempts = 3
        for (i, u) in selected.enumerated() {
            // Stop before starting a new file: apps not yet started keep their version.
            if stopRequested { break }
            if isProtectedAtInstallTarget(u) {
                protectedSkipped.insert(u.remotePath)
                continue
            }
            live.update(current: i, total: selected.count, detail: u.name)
            guard let data = extractData(remotePath: u.remotePath) else {
                failures.append("\(u.name): not found in pack"); continue
            }
            let dir = (u.targetPath as NSString).deletingLastPathComponent
            // Write the new FAP to a sibling temp first, and only swap it into place after
            // it is fully written AND md5-verified. So a Stop (or a link death) mid-write
            // just discards the temp and leaves the installed app on its previous, working
            // version — the app you stopped on is never a truncated/broken FAP.
            let tempPath = u.targetPath + ".ucnew"

            var ok = false
            var stoppedMidFile = false
            var lastReason = "unknown error"
            for attempt in 1...maxAttempts {
                phase = .installing(i + 1, selected.count)
                transferReporter.progress(u.name, force: attempt == 1)
                installDetail = InstallDetail(
                    name: u.name,
                    sent: 0,
                    total: data.count,
                    attempt: attempt,
                    channel: channel
                )

                // Re-establish the link before each try — a long install can drop
                // BLE briefly and auto-reconnect; wait for it instead of failing.
                guard await fileChannelReady(channel, timeout: attempt == 1 ? 6 : 12) else {
                    lastReason = "Flipper disconnected"
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                try? await storage.makeDirectory(dir)
                do {
                    try? await storage.delete(tempPath)      // clear any stale temp from a prior run
                    try await storage.write(tempPath, data: data) { sent in
                        Task { @MainActor in
                            if let d = self.installDetail, d.name == u.name, sent > d.sent {
                                self.installDetail?.sent = sent
                                transferReporter.progress(u.name)
                            }
                        }
                    }
                    installDetail?.sent = data.count
                    // Stop check BEFORE the live app is touched: drop the temp and keep the
                    // previous, working version in place — nothing half-written is applied.
                    if stopRequested { try? await storage.delete(tempPath); stoppedMidFile = true; break }
                    // Verify the staged temp, then swap it into place. storage.move is a
                    // device-side rename (no BLE transfer), so the commit is quick and the
                    // long, interruptible part (the BLE write) already went to the temp.
                    let staged = await verifyWrite(
                        path: tempPath, expectedMD5: u.newMD5, expectedSize: data.count, storage: storage)
                    guard staged.ok else { lastReason = staged.reason; try? await storage.delete(tempPath); continue }
                    guard try await commitStagedInstall(
                        u,
                        tempPath: tempPath,
                        storage: storage
                    ) else {
                        protectedSkipped.insert(u.remotePath)
                        try? await storage.delete(tempPath)
                        break
                    }
                    let landed = await verifyWrite(
                        path: u.targetPath, expectedMD5: u.newMD5, expectedSize: data.count, storage: storage)
                    if landed.ok { ok = true; break }
                    lastReason = landed.reason
                } catch {
                    lastReason = error.localizedDescription
                    ulog.error("install \(u.name, privacy: .public) attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                    try? await storage.delete(tempPath)      // never leave a partial temp behind
                    try? await Task.sleep(nanoseconds: 800_000_000)   // let reconnect engage
                }
            }

            if ok {
                installed.insert(u.remotePath)
                cache.record(u)
                history.insert(InstallRecord(date: Date(), tag: tag, name: u.name,
                                             pack: u.pack, wasNew: u.isNew), at: 0)
            } else if !stoppedMidFile && !protectedSkipped.contains(u.remotePath) {
                failures.append("\(u.name): \(lastReason)")
            }
            live.update(current: i + 1, total: selected.count, detail: u.name)
            // Stopped mid-file: the temp was discarded and the live app kept its previous
            // working version — it's neither installed nor failed. End the run here.
            if stopRequested { break }
        }
        installDetail = nil
        if history.count > 1000 { history.removeLast(history.count - 1000) }
        saveHistory()

        // Reconcile cache only for paths that already matched this exact catalog at
        // transaction start, plus files that this transaction md5-verified after a
        // successful live replacement. Failed, skipped, protected, and previously
        // hidden rows keep their old hash so an ordinary subsequent Check surfaces
        // them. Do not derive this from mutable `updates` or current protection:
        // either can change while this transaction is suspended.
        for (path, f) in allManifest where installed.contains(path)
            || cacheVerifiedCurrentAtStart.contains(path) {
            cache.record(f)
        }
        cache.tag = tag
        saveCache(cache)
        pendingRouteCleanup = cleanupCandidates(cache: cache)

        // Keep failed/skipped in the list; drop only the verified ones.
        updates.removeAll {
            installed.contains($0.remotePath) || isProtectedAtInstallTarget($0)
        }

        // Post-install signature summary: each install above is md5-verified on the
        // device, so this records exactly what landed intact vs what didn't.
        verifyResult = VerifyResult(kind: .postInstall, tag: tag,
                                    verified: installed.count, failed: failures)

        if stopRequested {
            // Files that were stopped (mid-temp-write or not yet started) kept their
            // previous working version — neither installed nor failed. Any genuine
            // failure (e.g. a verify mismatch) is still surfaced separately.
            let kept = max(0, selected.count - installed.count - failures.count)
            var msg = "Stopped — installed \(installed.count) of \(selected.count)."
            if kept > 0 { msg += " \(kept) kept their current version." }
            if failures.isEmpty {
                phase = .done(msg)
            } else {
                msg += " \(failures.count) failed and may need reinstalling: "
                    + failures.prefix(3).joined(separator: "; ") + (failures.count > 3 ? " …" : "")
                phase = .failed(msg)
            }
            await live.stop(
                completed: installed.count,
                total: selected.count,
                detail: failures.isEmpty ? "Install stopped" : "Stopped with failures"
            )
        } else if failures.isEmpty {
            var message = "Installed \(installed.count) app\(installed.count == 1 ? "" : "s") · \(tag)"
            if !protectedSkipped.isEmpty {
                message += " · kept \(protectedSkipped.count) newly protected"
            }
            phase = .done(message)
            await live.succeed(
                // A protected app can be intentionally skipped after the
                // transaction begins. The operation itself is still complete;
                // report terminal progress rather than leaving the Live Activity
                // on a misleading partial bar. The UI message keeps the exact
                // installed/skipped counts above.
                completed: selected.count,
                total: selected.count,
                detail: protectedSkipped.isEmpty
                    ? "Plugins installed"
                    : "Installed \(installed.count); kept \(protectedSkipped.count) protected"
            )
        } else {
            let head = installed.isEmpty ? "Install failed" : "Installed \(installed.count), \(failures.count) failed"
            phase = .failed("\(head): " + failures.prefix(4).joined(separator: "; ")
                            + (failures.count > 4 ? " …" : ""))
            if installed.isEmpty {
                await live.fail(
                    completed: 0,
                    total: selected.count,
                    detail: "Install failed"
                )
            } else {
                await live.completeWithIssues(
                    completed: installed.count,
                    total: selected.count,
                    detail: "\(failures.count) failed"
                )
            }
        }
    }

    /// Separate, user-triggered reconciliation for routes retired by an immutable
    /// Community Pack catalog. It never downloads or reinstalls an app. Each path is
    /// independently content-verified and moved through a durable recovery marker.
    func cleanUpPendingRoutes() async {
        guard !pendingRouteCleanup.isEmpty else {
            phase = .done("No obsolete Community Pack routes remain.")
            return
        }
        guard transactionGate.begin() else { return }
        defer { transactionGate.end() }

        phase = .cleaning(0, pendingRouteCleanup.count)
        verifyResult = nil
        lastCleanup = nil
        let channel = activeChannel
        let storage = activeStorage
        guard await fileChannelReady(channel) else {
            phase = .failed(
                "Flipper isn't ready — connect it or select its SD card, then retry cleanup."
            )
            return
        }
        guard channel != .ble || ble().serialOwner != .claudeBuddy else {
            phase = .failed(FlipperRPCError.serialOwnedByClaudeBuddy.localizedDescription)
            return
        }

        var cache = loadCache()
        cache?.reconcileRoutes(current: allManifest.mapValues(\.newMD5))
        let candidates = cleanupCandidates(cache: cache)
        pendingRouteCleanup = candidates
        guard !candidates.isEmpty else {
            if let cache { saveCache(cache) }
            phase = .done("No obsolete Community Pack routes remain.")
            return
        }

        // Persist exact recovery context before the first device mutation. This
        // journal intentionally survives Reset baseline and app/device restarts.
        guard cleanupJournalStore.record(candidates) else {
            phase = .failed("Cleanup recovery journal could not be persisted; nothing was removed.")
            return
        }
        let stagedRecoveryPaths = cleanupJournalStore.recoveryPathIdentities()
        phase = .cleaning(0, candidates.count)
        let cleanup = await PluginRouteCleanupExecutor.execute(
            candidates,
            storage: storage,
            stagedRecoveryPaths: stagedRecoveryPaths,
            shouldPreserve: { [weak self] candidate in
                self?.shouldPreserveDuringCleanup(candidate) ?? true
            },
            beginIrreversibleMutation: { [weak self] in
                self?.protectionMutationGate.begin() ?? false
            },
            endIrreversibleMutation: { [weak self] in
                self?.protectionMutationGate.end()
            },
            didObserveNoStage: { [cleanupJournalStore] candidate in
                cleanupJournalStore.markPending(candidate)
            },
            willStage: { [cleanupJournalStore] candidate in
                guard cleanupJournalStore.markStaging(candidate) else {
                    throw PluginRouteCleanupFailure(
                        message: "active cleanup marker could not be persisted"
                    )
                }
            },
            progress: { [weak self] done, total, _ in
                self?.phase = .cleaning(done, total)
            }
        )
        for path in cleanup.removed + cleanup.missing {
            cache?.forgetRetiredRoute(path)
        }
        if let cache { saveCache(cache) }
        let journalUpdated = cleanupJournalStore.remove(
            legacyPaths: cleanup.removed + cleanup.missing + cleanup.rolledBack
        )
        pendingRouteCleanup = cleanupCandidates(cache: cache)
        lastCleanup = (cleanup.removed.isEmpty && cleanup.kept.isEmpty)
            ? nil
            : CleanupResult(removed: cleanup.removed, kept: cleanup.kept)

        if !journalUpdated {
            phase = .failed(
                "Device files are safe, but cleanup recovery state could not be updated. Retry cleanup."
            )
        } else if let failure = cleanup.failures.first {
            phase = .failed(
                "Cleanup stopped safely; unverified files were kept. \(failure)"
            )
        } else if !cleanup.removed.isEmpty {
            phase = .done(
                "Removed \(cleanup.removed.count) obsolete Community Pack route"
                + (cleanup.removed.count == 1 ? "." : "s.")
            )
        } else if !cleanup.rolledBack.isEmpty {
            phase = .done("Restored protected Community app route safely.")
        } else if !cleanup.kept.isEmpty {
            phase = .done("Nothing removed — custom or unverified files were kept.")
        } else {
            phase = .done("No obsolete Community Pack routes remain.")
        }
    }

    /// On-demand signature check — the all-the-plugins analogue of FW packages'
    /// "Verify on device". Re-hashes every .fap in the current pack on the Flipper and
    /// compares to the expected md5; files that are missing or whose md5 differs are
    /// surfaced as selectable updates so the existing Install button can (re)install them.
    /// Heavy over BLE (one md5 round-trip per file); fast over USB SD.
    func verifyInstalled() async {
        guard !allManifest.isEmpty else {
            phase = .failed("Run “Check for updates” first so the pack manifest is loaded.")
            return
        }
        let channel = activeChannel
        guard await fileChannelReady(channel) else {
            phase = .failed("Connect to the Flipper first, or select the SD card over USB.")
            return
        }
        let storage = activeStorage
        let cache = loadCache()
        verifyResult = nil
        let items = allManifest.values.sorted { $0.remotePath < $1.remotePath }
        var bad: [PluginUpdate] = []
        var failures: [String] = []
        var verified = 0
        for (i, f) in items.enumerated() {
            if Task.isCancelled { phase = .idle; return }
            phase = .verifying(i + 1, items.count)
            guard await fileChannelReady(channel) else { phase = .failed("Disconnected during verify"); return }
            let observation: (path: String, md5: String?)
            do {
                observation = try await deviceObservation(
                    for: f, storage: storage, cache: cache)
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
            if observation.md5?.lowercased() == f.newMD5.lowercased() {
                verified += 1
            } else {
                var update = PluginUpdate(
                    remotePath: f.remotePath,
                    name: f.name,
                    category: f.category,
                    pack: f.pack,
                    newMD5: f.newMD5,
                    oldMD5: observation.md5,
                    size: f.size)
                update.selected = observation.md5 != nil
                bad.append(update)
                failures.append("\(f.name): \(observation.md5 == nil ? "missing" : "md5 mismatch")")
            }
        }
        verifyResult = VerifyResult(kind: .onDevice, tag: tag, verified: verified, failed: failures)
        // Explicit Verify must bypass GitHub/raw CDN caching: automation may have
        // published the exact audit after this pack was checked a few minutes ago.
        await refreshProtectedAuditResolution(forceRemote: true)
        await refreshProtectedReviews()
        if bad.isEmpty {
            phase = .done("Verified \(verified) app\(verified == 1 ? "" : "s") on device · all match \(tag)")
        } else {
            updates = sortUpdates(bad)   // surface missing/mismatched for one-tap reinstall
            phase = .idle
        }
        await validateCompatibility()
    }

    /// Verify a freshly-written file. Retries the md5 once after a short pause
    /// (slow SD flush), then — if still wrong — reports device vs source size so
    /// a truncated write (dropped chunk) is distinguishable from byte corruption.
    private func verifyWrite(
        path: String,
        expectedMD5: String,
        expectedSize: Int,
        storage: any DeviceFileStore
    ) async -> (ok: Bool, reason: String) {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            if let dev = await storage.md5(path), dev == expectedMD5 { return (true, "") }
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let devSize = (try? await storage.list(dir))?.first { $0.name == name }?.size
        let sizeStr = devSize.map { "\($0)" } ?? "missing"
        return (false, "md5 mismatch (device \(sizeStr)B vs source \(expectedSize)B)")
    }

    /// Commit a fully verified `.ucnew` only while the protection policy is fenced.
    /// A user may protect an app during the long temp-file upload, but once this
    /// method begins that request is rejected rather than falsely acknowledged while
    /// the live target is being replaced. Returning `false` leaves the live FAP
    /// untouched and lets the caller discard the temp safely.
    private func commitStagedInstall(
        _ update: PluginUpdate,
        tempPath: String,
        storage: any DeviceFileStore
    ) async throws -> Bool {
        guard protectionMutationGate.begin() else { return false }
        defer { protectionMutationGate.end() }
        guard !isProtectedAtInstallTarget(update) else {
            return false
        }
        if await storage.exists(update.targetPath) {
            try await storage.delete(update.targetPath)
        }
        try await storage.move(tempPath, to: update.targetPath)
        return true
    }

    // MARK: - GitHub

    /// Picks the release to use: the manual pin if one is set, otherwise GitHub's own
    /// "latest" (most recently published non-draft, non-prerelease release).
    private func latestRelease() async throws -> (String, [String: URL]) {
#if DEBUG
        if let testingRelease { return testingRelease }
#endif
        let path = manualReleaseTag.map { "releases/tags/\($0)" } ?? "releases/latest"
        let url = URL(string: "https://api.github.com/repos/\(repo)/\(path)")!
        let result = try await GitHubAPIClient.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else {
            throw GitHubAPIError.invalidJSON
        }
        var map: [String: URL] = [:]
        for a in assets {
            if let name = a["name"] as? String, let u = a["browser_download_url"] as? String,
               let url = URL(string: u) { map[name] = url }
        }
        return (tag, map)
    }

    /// Fetches recent releases for the manual picker — newest first, capped at 20 (far
    /// more than anyone needs to page back through, and one request instead of paginating).
    func loadAvailableReleases() async {
        loadingReleases = true
        defer { loadingReleases = false }
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!
        guard let result = try? await GitHubAPIClient.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] else {
            return
        }
        let formatter = ISO8601DateFormatter()
        availableReleases = arr.compactMap { r -> PluginReleaseInfo? in
            guard let tag = r["tag_name"] as? String,
                  let publishedRaw = r["published_at"] as? String,
                  let published = formatter.date(from: publishedRaw),
                  r["draft"] as? Bool != true, r["prerelease"] as? Bool != true else { return nil }
            let assetNames = Set((r["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
            let hasPacks = assetNames.contains("all-the-apps-base.zip") && assetNames.contains("all-the-apps-extra.zip")
            return PluginReleaseInfo(tag: tag, publishedAt: published, hasPacks: hasPacks)
        }
    }

    /// Pins the pack source to an exact release (nil = back to Auto/latest) and
    /// re-checks immediately so the switch is reflected right away.
    func setManualReleaseTag(_ tag: String?) {
        manualReleaseTag = tag
        Self.saveManualReleaseTag(tag)
        Task { await check() }
    }

    private static let manualReleaseTagKey = "pluginManualReleaseTag"
    private static func loadManualReleaseTag() -> String? {
        UserDefaults.standard.string(forKey: manualReleaseTagKey)
    }
    private static func saveManualReleaseTag(_ tag: String?) {
        if let tag { UserDefaults.standard.set(tag, forKey: manualReleaseTagKey) }
        else { UserDefaults.standard.removeObject(forKey: manualReleaseTagKey) }
    }

    private func download(_ url: URL, to name: String) async throws -> URL {
#if DEBUG
        if let local = testingDownloads[url] { return local }
#endif
        let (tmp, _) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Zip

    private struct ExtractedPack {
        var updates: [PluginUpdate] = []
        var metadata: [String: PluginCatalogMetadata] = [:]
    }

    private func extractManifest(zipURL: URL, pack: String) throws -> ExtractedPack {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw NSError(domain: "updater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Bad \(pack) zip"])
        }
        var out = ExtractedPack()
        for entry in archive where FapCompatibility.isBinary(entry.path) {
            guard let rp = PluginInstallRouting.remotePath(for: entry.path) else { continue }
            var data = Data()
            _ = try? archive.extract(entry) { data.append($0) }
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let comps = rp.split(separator: "/")
            let name = (String(comps.last ?? "") as NSString).deletingPathExtension
            let category = comps.count >= 2 ? String(comps[comps.count - 2]) : ""
            out.updates.append(PluginUpdate(
                remotePath: rp,
                name: name,
                category: category,
                pack: pack,
                newMD5: md5,
                oldMD5: nil,
                size: data.count))
            out.metadata[rp] = FapMetadata.parse(data).map(PluginCatalogMetadata.parsed) ?? .invalid
        }
        return out
    }

    private func extractData(remotePath: String) -> Data? {
        for (_, url) in packURLs {
            guard let archive = Archive(url: url, accessMode: .read) else { continue }
            for entry in archive where FapCompatibility.isBinary(entry.path) {
                if PluginInstallRouting.remotePath(for: entry.path) == remotePath {
                    var data = Data()
                    _ = try? archive.extract(entry) { data.append($0) }
                    if !data.isEmpty { return data }
                }
            }
        }
        return nil
    }

    // MARK: - Cache

    private func loadCache() -> PluginCatalogCache? {
        guard let d = persistenceDefaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(PluginCatalogCache.self, from: d)
    }
    private func saveCache(_ c: PluginCatalogCache) {
        if let d = try? JSONEncoder().encode(c) {
            persistenceDefaults.set(d, forKey: cacheKey)
        }
    }
    func resetBaseline() {
        persistenceDefaults.removeObject(forKey: cacheKey)
        pendingRouteCleanup = cleanupCandidates(cache: nil)
    }

    // MARK: - Exclusions (protect locally-modified apps)

    private static func loadExcluded(defaults: UserDefaults) -> Set<String> {
        if let arr = defaults.array(forKey: excludedKey) as? [String] {
            let original = Set(arr.map { $0.lowercased() })
            let saved = original.subtracting(retiredBuiltInExcluded)
            let merged = saved.union(builtInExcluded)
            if merged != original {
                defaults.set(Array(merged).sorted(), forKey: excludedKey)
            }
            return merged
        }
        return builtInExcluded
    }

    @discardableResult
    private func saveExcluded() -> Bool {
        persistenceDefaults.set(Array(excluded).sorted(), forKey: Self.excludedKey)
        return persistenceDefaults.synchronize()
            && Self.loadExcluded(defaults: persistenceDefaults) == excluded
    }

    private static let unprotectedKey = "pluginUnprotectedBuiltIns"
    private static func loadUnprotected(defaults: UserDefaults) -> Set<String> {
        guard let arr = defaults.array(forKey: unprotectedKey) as? [String] else { return [] }
        return Set(arr.map { $0.lowercased() }).intersection(builtInExcluded)   // only honor real built-ins
    }

    @discardableResult
    private func saveUnprotected() -> Bool {
        persistenceDefaults.set(
            Array(unprotectedBuiltIns).sorted(),
            forKey: Self.unprotectedKey
        )
        return persistenceDefaults.synchronize()
            && Self.loadUnprotected(defaults: persistenceDefaults) == unprotectedBuiltIns
    }

    @discardableResult
    private func changeProtection(_ protect: Bool, name: String) -> Bool {
        // Do not acknowledge a policy change while a live target is in its tiny
        // delete/rename window. The caller can retry immediately; accepting and
        // queueing it here would make "Protected" appear true after the FAP was
        // already removed or swapped. Outside that fence, each operation changes
        // exactly one synchronously verified UserDefaults key.
        guard !protectionMutationGate.isActive else { return false }
        guard let normalized = PluginProtectionPolicy.normalizedName(name) else {
            return false
        }

        let oldExcluded = excluded
        let oldUnprotected = unprotectedBuiltIns
        let saved: Bool
        if Self.builtInExcluded.contains(normalized) {
            if protect {
                unprotectedBuiltIns.remove(normalized)
            } else {
                unprotectedBuiltIns.insert(normalized)
            }
            saved = saveUnprotected()
        } else {
            if protect {
                excluded.insert(normalized)
            } else {
                excluded.remove(normalized)
            }
            saved = saveExcluded()
        }
        guard saved else {
            excluded = oldExcluded
            unprotectedBuiltIns = oldUnprotected
            return false
        }

        if protect { updates.removeAll { isProtectedAtInstallTarget($0) } }
        refreshPendingRouteCleanup()
        return true
    }

    @discardableResult
    func addExclusion(_ name: String) -> Bool {
        changeProtection(true, name: name)
    }

    @discardableResult
    func removeExclusion(_ name: String) -> Bool {
        changeProtection(false, name: name)
    }

    // MARK: - History

    private static let historyKey = "pluginHistory"
    private static func loadHistory() -> [InstallRecord] {
        guard let d = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([InstallRecord].self, from: d)) ?? []
    }
    private func saveHistory() {
        if let d = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(d, forKey: Self.historyKey)
        }
    }
    func clearHistory() { history = []; saveHistory() }
}

#if DEBUG
extension PluginUpdater {
    /// Configures a deterministic local Community Pack source and device transport
    /// for transaction regressions. Production catalog discovery remains remote-only.
    func configureCatalogSourceForTesting(
        tag: String,
        assets: [String: URL],
        downloads: [URL: URL],
        storage: any DeviceFileStore,
        deviceAPI: Int? = 88,
        deviceTarget: Int? = 7
    ) {
        testingRelease = (tag, assets)
        testingDownloads = downloads
        testingStorage = storage
        testingChannel = storage.channel
        testingDeviceIdentity = (deviceAPI, deviceTarget)
    }

    func seedCacheForTesting(_ cache: PluginCatalogCache) {
        saveCache(cache)
    }

    func cacheForTesting() -> PluginCatalogCache? {
        loadCache()
    }

    /// Test-only access to the final replacement boundary. Production callers can
    /// reach it only through `install()` after staging and MD5 verification.
    func commitStagedInstallForTesting(
        _ update: PluginUpdate,
        tempPath: String,
        storage: any DeviceFileStore
    ) async throws -> Bool {
        try await commitStagedInstall(update, tempPath: tempPath, storage: storage)
    }

    /// Focused test hook for the late-ledger lifecycle. Production provenance is set
    /// only from the SHA-256 values computed while downloading both pack archives.
    func configureProtectedAuditProvenanceForTesting(
        _ provenance: ProtectedPluginPackProvenance
    ) {
        setProtectedAuditProvenance(provenance)
    }

    func refreshProtectedAuditResolutionForTesting(forceRemote: Bool = false) async {
        await refreshProtectedAuditResolution(forceRemote: forceRemote)
    }

    func refreshProtectedAuditForTesting() async {
        await refreshProtectedAudit()
    }

    static func protectedAuditQAFixture() -> PluginUpdater {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("protected-audit-ui-\(UUID().uuidString)")
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.invalid/audit.json")!,
            cache: ProtectedPluginAuditCache(directory: temp),
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            bundledData: { nil })
        let updater = PluginUpdater(protectedAuditService: service)
        let audit = ProtectedPluginAudit(
            sourceTag: "qa-pack",
            sourceCommit: String(repeating: "a", count: 40),
            auditIssue: "https://github.com/squazaryu/tumoflip/issues/302",
            archives: [
                ProtectedPluginAuditArchive(
                    pack: "base", fileName: "all-the-apps-base.zip",
                    sha256: String(repeating: "1", count: 64)),
                ProtectedPluginAuditArchive(
                    pack: "extra", fileName: "all-the-apps-extra.zip",
                    sha256: String(repeating: "2", count: 64)),
            ],
            entries: [
                ProtectedPluginAuditEntry(
                    remotePath: "/ext/apps/GPIO/esp_flasher.fap",
                    targetPath: "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
                    sourceMD5: String(repeating: "1", count: 32),
                    targetMD5s: [String(repeating: "a", count: 32)],
                    targetProvenance: [ProtectedPluginTargetProvenance(
                        targetMD5: String(repeating: "a", count: 32),
                        channel: .dev,
                        releaseTag: "fw-packages-dev-003",
                        manifestSHA256: String(repeating: "c", count: 64))],
                    disposition: .auditedDifference,
                    note: nil),
                ProtectedPluginAuditEntry(
                    remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                    targetPath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                    sourceMD5: String(repeating: "2", count: 32),
                    targetMD5s: [],
                    targetProvenance: [],
                    disposition: .intentionallyReplaced,
                    note: nil),
            ])
        updater.tag = "qa-pack"
        updater.protectedAuditResolution = .accepted(
            audit,
            origin: .remote,
            allowsCurrentVerdicts: true)
        updater.protectedReviews = [
            ProtectedPluginReview(
                remotePath: "/ext/apps/GPIO/esp_flasher.fap",
                targetPath: "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
                name: "esp_flasher", category: "GPIO", pack: "extra",
                newMD5: String(repeating: "1", count: 32),
                deviceMD5: String(repeating: "a", count: 32),
                deviceKnown: true, size: 6_000_000),
            ProtectedPluginReview(
                remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                targetPath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                name: "claude_remote_ble", category: "Bluetooth", pack: "extra",
                newMD5: String(repeating: "2", count: 32),
                deviceMD5: nil, deviceKnown: true, size: 48_000),
            ProtectedPluginReview(
                remotePath: "/ext/apps/Sub-GHz/subghz_raw_edit.fap",
                targetPath: "/ext/apps/ARF Tools/subghz_raw_edit.fap",
                name: "subghz_raw_edit", category: "Sub-GHz", pack: "extra",
                newMD5: String(repeating: "3", count: 32),
                deviceMD5: String(repeating: "b", count: 32),
                deviceKnown: true, size: 32_000),
            ProtectedPluginReview(
                remotePath: "/ext/apps/Tools/missing_protected_app.fap",
                targetPath: "/ext/apps/Tools/missing_protected_app.fap",
                name: "missing_protected_app", category: "Tools", pack: "base",
                newMD5: String(repeating: "4", count: 32),
                deviceMD5: nil,
                deviceKnown: true, size: 24_000),
        ]
        let metadata = FapMetadata(apiMajor: 88, apiMinor: 2, hardwareTarget: 7)
        updater.classifications = Dictionary(
            uniqueKeysWithValues: updater.protectedReviews.map {
                ($0.remotePath, .compatible(metadata))
            })
        return updater
    }

    static func protectedAuditUnavailableQAFixture() -> PluginUpdater {
        let updater = protectedAuditQAFixture()
        updater.protectedAuditResolution = .rejected(
            "The authoritative protected-app audit endpoint could not be reached.",
            kind: .unavailable)
        return updater
    }

    static func protectedAuditInvalidQAFixture() -> PluginUpdater {
        let updater = protectedAuditQAFixture()
        updater.protectedAuditResolution = .rejected(
            "The authoritative protected-app audit document is malformed.",
            kind: .invalid)
        return updater
    }

    static func protectedAuditNotCurrentQAFixture() -> PluginUpdater {
        let updater = protectedAuditQAFixture()
        if let audit = updater.protectedAuditResolution?.audit {
            updater.protectedAuditResolution = .accepted(
                audit,
                origin: .cache,
                allowsCurrentVerdicts: false,
                warning: "A fresh primary audit could not be loaded. Cached audit data is shown only as historical evidence; no device change decision was made.")
        }
        return updater
    }

    static func communityRouteCleanupQAFixture() -> PluginUpdater {
        let updater = PluginUpdater()
        updater.tag = "16aug2026"
        updater.phase = .done("Installed 2 apps · cleaned 1 duplicate · 16aug2026")
        updater.verifyResult = VerifyResult(
            kind: .postInstall,
            tag: "16aug2026",
            verified: 2,
            failed: []
        )
        updater.lastCleanup = CleanupResult(
            removed: ["/ext/apps/Games/4inrow.fap"],
            kept: ["/ext/apps/GPIO/custom_sensor.fap"]
        )
        updater.pendingRouteCleanup = [PluginRouteCleanupCandidate(
            catalogPath: "/ext/apps/Games/Board/chess.fap",
            canonicalPath: "/ext/apps/Games/Board/chess.fap",
            legacyPath: "/ext/apps/Games/chess.fap",
            canonicalMD5: "22222222222222222222222222222222",
            acceptedLegacyMD5s: ["11111111111111111111111111111111"]
        )]
        return updater
    }

    static func communityAppsLayoutQAFixture() -> PluginUpdater {
        let updater = PluginUpdater()
        let metadata = FapMetadata(apiMajor: 88, apiMinor: 4, hardwareTarget: 7)
        let updates = [
            PluginUpdate(
                remotePath: "/ext/apps/GPIO/battery_reader.fap",
                name: "battery_reader",
                category: "GPIO",
                pack: "base",
                newMD5: String(repeating: "1", count: 32),
                oldMD5: nil,
                size: 18_432,
                selected: true
            ),
            PluginUpdate(
                remotePath: "/ext/apps/Tools/morse_decoder.fap",
                name: "morse_decoder",
                category: "Tools",
                pack: "extra",
                newMD5: String(repeating: "2", count: 32),
                oldMD5: String(repeating: "3", count: 32),
                size: 32_768,
                selected: true
            ),
            PluginUpdate(
                remotePath: "/ext/apps/Games/updated_game.fap",
                name: "updated_game",
                category: "Games",
                pack: "extra",
                newMD5: String(repeating: "4", count: 32),
                oldMD5: String(repeating: "5", count: 32),
                size: 65_536,
                selected: false
            ),
        ]
        updater.tag = "28aug2026"
        updater.phase = .done("3 Community app changes found.")
        updater.updates = updates
        updater.allManifest = Dictionary(uniqueKeysWithValues: updates.map { ($0.remotePath, $0) })
        updater.classifications = Dictionary(
            uniqueKeysWithValues: updates.map { ($0.remotePath, .compatible(metadata)) }
        )
        updater.verifyResult = VerifyResult(
            kind: .onDevice,
            tag: "28aug2026",
            verified: 54,
            failed: []
        )
        return updater
    }
}
#endif
