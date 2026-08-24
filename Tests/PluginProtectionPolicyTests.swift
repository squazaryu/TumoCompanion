import CryptoKit
import XCTest
import ZIPFoundation
@testable import UnleashedCompanion

final class PluginProtectionPolicyTests: XCTestCase {
    private func routeUpdate(
        _ name: String,
        remotePath: String,
        md5: String
    ) -> PluginUpdate {
        PluginUpdate(
            remotePath: remotePath,
            name: name,
            category: (remotePath as NSString).deletingLastPathComponent,
            pack: "extra",
            newMD5: md5,
            oldMD5: nil,
            size: 1
        )
    }

    private func recoveryPaths(
        for candidate: PluginRouteCleanupCandidate
    ) -> Set<String> {
        [PluginRouteReconciliation.pathIdentity(candidate.legacyPath)]
    }

    private func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func le32(_ value: Int) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private func put(_ bytes: inout [UInt8], at offset: Int, _ value: [UInt8]) {
        for (index, byte) in value.enumerated() {
            bytes[offset + index] = byte
        }
    }

    /// Small, valid ELF32/FAP fixture. The real install gate parses this payload,
    /// rather than a test bypass, so the regression covers the production path.
    private func makeFAP(seed: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 52)
        put(&bytes, at: 0, [0x7F, 0x45, 0x4C, 0x46]) // ELF
        bytes[4] = 1 // ELFCLASS32
        bytes[5] = 1 // ELFDATA2LSB
        bytes[6] = 1 // EV_CURRENT
        put(&bytes, at: 16, le16(1))
        put(&bytes, at: 18, le16(0x28))
        put(&bytes, at: 20, le32(1))
        put(&bytes, at: 40, le16(52))
        put(&bytes, at: 46, le16(40))
        put(&bytes, at: 48, le16(3))
        put(&bytes, at: 50, le16(2))

        let metaOffset = bytes.count
        bytes += le32(FapMetadata.manifestMagic)
        bytes += le32(1)
        bytes += le16(4)
        bytes += le16(88)
        bytes += le16(7)

        let namesOffset = bytes.count
        let names = Array("\0.fapmeta\0.shstrtab\0".utf8)
        bytes += names
        let sectionOffset = (bytes.count + 3) & ~3
        put(&bytes, at: 32, le32(sectionOffset))
        bytes += repeatElement(0, count: sectionOffset - bytes.count)

        func sectionHeader(name: Int, type: Int, offset: Int, size: Int) -> [UInt8] {
            var header = [UInt8](repeating: 0, count: 40)
            put(&header, at: 0, le32(name))
            put(&header, at: 4, le32(type))
            put(&header, at: 16, le32(offset))
            put(&header, at: 20, le32(size))
            return header
        }

        bytes += sectionHeader(name: 0, type: 0, offset: 0, size: 0)
        bytes += sectionHeader(name: 1, type: 1, offset: metaOffset, size: 14)
        bytes += sectionHeader(name: 10, type: 3, offset: namesOffset, size: names.count)
        bytes += [seed]
        return Data(bytes)
    }

    private func makePluginArchive(entries: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginUpdaterTests-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    @MainActor
    private func makeCacheReconciliationFixture(
        storage: PluginInstallMemoryStore,
        defaults: UserDefaults
    ) async throws -> (
        updater: PluginUpdater,
        chessPath: String,
        checkersPath: String,
        oldChessMD5: String,
        oldCheckersMD5: String,
        newChessMD5: String,
        newCheckersMD5: String,
        archives: [URL],
        auditDirectory: URL
    ) {
        let chessPath = "/ext/apps/Games/Board/chess.fap"
        let checkersPath = "/ext/apps/Games/Board/checkers.fap"
        let chess = makeFAP(seed: 0xC1)
        let checkers = makeFAP(seed: 0xC2)
        let base = try makePluginArchive(entries: [
            "base_pack_build/artifacts-base/Games/Board/chess.fap": chess,
            "base_pack_build/artifacts-base/Games/Board/checkers.fap": checkers,
        ])
        let extra = try makePluginArchive(entries: [:])
        let baseAsset = URL(string: "https://example.invalid/base.zip")!
        let extraAsset = URL(string: "https://example.invalid/extra.zip")!
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginAuditTests-\(UUID().uuidString)", isDirectory: true)
        let auditService = ProtectedPluginAuditService(
            url: URL(string: "https://example.invalid/audit.json")!,
            cache: ProtectedPluginAuditCache(directory: auditDirectory),
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            bundledData: { nil }
        )
        let updater = PluginUpdater(
            protectedAuditService: auditService,
            persistenceDefaults: defaults
        )
        let oldChessMD5 = String(repeating: "1", count: 32)
        let oldCheckersMD5 = String(repeating: "2", count: 32)
        updater.seedCacheForTesting(PluginCatalogCache(
            tag: "previous",
            map: [
                chessPath: oldChessMD5,
                checkersPath: oldCheckersMD5,
            ]
        ))
        updater.configureCatalogSourceForTesting(
            tag: "fixture-pack",
            assets: [
                "all-the-apps-base.zip": baseAsset,
                "all-the-apps-extra.zip": extraAsset,
            ],
            downloads: [baseAsset: base, extraAsset: extra],
            storage: storage
        )
        await updater.check()

        return (
            updater,
            chessPath,
            checkersPath,
            oldChessMD5,
            oldCheckersMD5,
            md5(chess),
            md5(checkers),
            [base, extra],
            auditDirectory
        )
    }

    func testArchiveRoutingIncludesAppsAndAppsDataBinaries() {
        XCTAssertEqual(
            PluginInstallRouting.remotePath(
                for: "base_pack_build/artifacts-base/Tools/totp.fap"),
            "/ext/apps/Tools/totp.fap")
        XCTAssertEqual(
            PluginInstallRouting.remotePath(
                for: "base_pack_build/apps_data/totp/plugins/totp_cli_add_plugin.fal"),
            "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal")
        XCTAssertNil(PluginInstallRouting.remotePath(for: "base_pack_build/README.md"))
    }

    func testDependentTotpFalIsProtectedByOwningApp() {
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "totp_cli_add_plugin",
            remotePath: "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal",
            excluded: ["totp"],
            unprotectedBuiltIns: []))
    }

    func testSubGhzProtocolFamilyIsProtectedAsOneUnit() {
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "protocol_vag",
            remotePath: "/ext/apps_data/subghz/plugins/protocol_vag.fal",
            excluded: ["subghz_protocols"],
            unprotectedBuiltIns: []))
    }

    @MainActor
    func testMixedCaseSubGhzProtocolFALCannotBeAdmittedWhenOwnerIsProtected() {
        let suite = "PluginProtectionMixedCaseFALTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = PluginUpdater(persistenceDefaults: defaults)
        let fal = routeUpdate(
            "protocol_vag",
            remotePath: "/ext/apps_data/subghz/PLUGINS/protocol_vag.fal",
            md5: "11111111111111111111111111111111"
        )

        XCTAssertEqual(
            PluginProtectionPolicy.protectionKeys(
                name: fal.name,
                remotePath: fal.remotePath
            ),
            ["protocol_vag", "subghz_protocols"]
        )
        XCTAssertTrue(
            updater.isProtected(fal),
            "A FAT case alias must be filtered into the protected review, not admitted for install."
        )
    }

    func testUnprotectingOwnerLiftsDependentFalProtection() {
        XCTAssertFalse(PluginProtectionPolicy.isProtected(
            name: "totp_cli_add_plugin",
            remotePath: "/ext/apps_data/totp/plugins/totp_cli_add_plugin.fal",
            excluded: ["totp"],
            unprotectedBuiltIns: ["totp"]))
    }

    func testBuiltInListCoversTumoflipAppsAndRetiresBleKiller() {
        let expected: Set<String> = [
            "ai_dashboard", "app_bridge_terminal", "arf_frequency_analyzer",
            "arf_subghz_full", "ble_gatt_lab", "claude_buddy", "claude_remote_ble",
            "esp_flasher", "esp32_wifi_marauder",
            "field_logger", "flipper_companion", "flipper_relay", "freq_analyzer_ext",
            "module_one_cockpit", "module_one_sensor_logger", "nfc_ccid_bridge",
            "protocol_compiler", "proto_pirate",
            "quac", "rolljam", "runtime_trace_viewer", "signal_workbench",
            "subghz_bruteforcer", "subghz_protocols", "subghz_raw_edit",
            "subghz_wardriving", "totp",
            "tumo_acceptance_suite", "tumo_ir_lab", "tumo_macro_deck", "tumocard_os",
            "tumofabric_node", "tumoflip_packages", "tumoflip_xremote",
            "tumokey", "tumokey_phase_a", "tumomodule_runtime", "tumonet_bench",
            "tumonet_gateway",
            "tumoscope", "tumoscript", "tumovgm_bridge", "tumovm_peripherals",
            "tumovm_poc", "usb_sd_mode",
            "wifi_map", "wifi_mapper",
        ]

        XCTAssertTrue(expected.isSubset(of: PluginUpdater.builtInExcluded))
        XCTAssertFalse(PluginUpdater.builtInExcluded.contains("ble_killer"))
    }

    func testAllThePluginsCannotOverwriteWardrivingOrDuplicateClaudeBuddy() {
        let wardrivingRemote = "/ext/apps/Sub-GHz/subghz_wardriving.fap"
        XCTAssertEqual(
            PluginInstallRouting.targetPath(for: wardrivingRemote),
            wardrivingRemote,
            "Wardriving follows the canonical firmware/FW Packages route")
        XCTAssertEqual(
            PluginInstallRouting.legacyPaths(for: wardrivingRemote),
            ["/ext/apps/Module One/Sub-GHz/subghz_wardriving.fap"])
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "subghz_wardriving",
            remotePath: wardrivingRemote,
            excluded: PluginUpdater.builtInExcluded,
            unprotectedBuiltIns: []))
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "claude_remote_ble",
            remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
            excluded: PluginUpdater.builtInExcluded,
            unprotectedBuiltIns: []))
    }

    func testAllThePluginsCannotOverwriteTumoflipESPFlasher() {
        let routedPath = PluginInstallRouting.targetPath(
            for: "/ext/apps/GPIO/esp_flasher.fap")
        XCTAssertEqual(
            routedPath,
            "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap")
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "esp_flasher",
            remotePath: routedPath,
            excluded: PluginUpdater.builtInExcluded,
            unprotectedBuiltIns: []))
    }

    func testMovedCommunityTotpUsesAuditedTumoflipRoute() {
        let remotePath = "/ext/apps/Tools/Crypto/totp.fap"

        XCTAssertEqual(
            PluginInstallRouting.targetPath(for: remotePath),
            "/ext/apps/Tools/totp.fap")
        XCTAssertEqual(
            PluginInstallRouting.legacyPaths(for: remotePath),
            [remotePath],
            "The Community Pack category is never the protected Tumoflip target.")
        XCTAssertTrue(PluginProtectionPolicy.isProtected(
            name: "totp",
            remotePath: remotePath,
            excluded: PluginUpdater.builtInExcluded,
            unprotectedBuiltIns: []))
    }

    func testCandidatePathsPreferTumoflipRouteThenCommunityAlias() {
        let remotePath = "/ext/apps/GPIO/weather_station.fap"
        XCTAssertEqual(
            PluginInstallRouting.candidatePaths(for: remotePath),
            [
                "/ext/apps/Module One/Sub-GHz/weather_station.fap",
                remotePath,
            ]
        )
    }

    func testCacheMatchesMovedCatalogEntryByAppIDAndMigratesIdentityIndex() {
        let oldPath = "/ext/apps/Old Category/weather_station.fap"
        let newPath = "/ext/apps/New Category/weather_station.fap"
        let md5 = "67067213b636a3a5f3bba182390c0bde"
        let update = routeUpdate("weather_station", remotePath: newPath, md5: md5)
        var cache = PluginCatalogCache(tag: "previous", map: [oldPath: md5])
        cache.reconcileRoutes(current: [newPath: md5])

        XCTAssertEqual(
            cache.md5(for: update),
            md5,
            "A category move must not become a false new/changed app.")
        cache.record(update)
        XCTAssertEqual(cache.map[newPath], md5)
        XCTAssertEqual(
            cache.appHashes[PluginRouteReconciliation.cacheIdentityKey(for: update)],
            md5
        )
    }

    @MainActor
    func testBaselineScanAcceptsByteIdenticalCommunityAlias() async throws {
        let suite = "PluginAliasScanTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let data = makeFAP(seed: 0xC7)
        let remotePath = "/ext/apps/GPIO/weather_station.fap"
        let archive = try makePluginArchive(entries: [
            "base_pack_build/artifacts-base/GPIO/weather_station.fap": data,
        ])
        let extra = try makePluginArchive(entries: [:])
        let baseAsset = URL(string: "https://example.invalid/alias-base.zip")!
        let extraAsset = URL(string: "https://example.invalid/alias-extra.zip")!
        let md5 = self.md5(data)
        let storage = PluginRouteMemoryStore(hashes: [remotePath: md5])
        let updater = PluginUpdater(persistenceDefaults: defaults)
        updater.configureCatalogSourceForTesting(
            tag: "alias-pack",
            assets: [
                "all-the-apps-base.zip": baseAsset,
                "all-the-apps-extra.zip": extraAsset,
            ],
            downloads: [baseAsset: archive, extraAsset: extra],
            storage: storage
        )

        await updater.check()
        XCTAssertEqual(updater.phase, .needsBaseline)
        await updater.scanBaseline()

        XCTAssertTrue(
            updater.updates.isEmpty,
            "A matching alias hash must be accepted even when the local target path is absent.")

        try? FileManager.default.removeItem(at: archive)
        try? FileManager.default.removeItem(at: extra)
    }

    func testLegacyCommunityAppsAreProtectedReplacements() {
        let replacements: [(name: String, remote: String, target: String)] = [
            (
                "wifi_map",
                "/ext/apps/GPIO/wifi_map.fap",
                "/ext/apps/Module One/ESP32 Wi-Fi/wifi_map.fap"
            ),
            (
                "freq_analyzer_ext",
                "/ext/apps/Sub-GHz/freq_analyzer_ext.fap",
                "/ext/apps/Module One/Sub-GHz/freq_analyzer_ext.fap"
            ),
        ]

        for replacement in replacements {
            let target = PluginInstallRouting.targetPath(for: replacement.remote)
            XCTAssertEqual(target, replacement.target)
            XCTAssertTrue(PluginProtectionPolicy.isProtected(
                name: replacement.name,
                remotePath: target,
                excluded: PluginUpdater.builtInExcluded,
                unprotectedBuiltIns: []
            ))
        }
    }

    func testLegacyV2CacheMigratesRemovedRoutesIntoContentAddressedHistory() throws {
        let oldPath = "/ext/apps/Games/4inrow.fap"
        let oldMD5 = "67067213b636a3a5f3bba182390c0bde"
        let data = try JSONSerialization.data(withJSONObject: [
            "tag": "15aug2026",
            "map": [oldPath: oldMD5],
        ])
        var cache = try JSONDecoder().decode(PluginCatalogCache.self, from: data)

        cache.reconcileRoutes(current: [
            "/ext/apps/Games/Board/4inrow.fap": oldMD5,
        ])

        XCTAssertTrue(cache.map.isEmpty)
        XCTAssertEqual(cache.retiredRoutes[oldPath], [oldMD5])

        let roundTrip = try JSONDecoder().decode(
            PluginCatalogCache.self,
            from: JSONEncoder().encode(cache)
        )
        XCTAssertEqual(roundTrip, cache)
    }

    func test16AugustMovesAreDerivedWithoutReleaseSpecificDeleteList() throws {
        let sameMD5 = "67067213b636a3a5f3bba182390c0bde"
        let rebuiltOldMD5 = "1980d96bf22dbac11b3c2402562cd4ee"
        let rebuiltNewMD5 = "3d380c9c7adaa8175c4f7af1e49243de"
        let protectedMD5 = "11111111111111111111111111111111"
        let current = [
            routeUpdate(
                "4inrow",
                remotePath: "/ext/apps/Games/Board/4inrow.fap",
                md5: sameMD5
            ),
            routeUpdate(
                "24cxxprog",
                remotePath: "/ext/apps/GPIO/Programmers/24cxxprog.fap",
                md5: rebuiltNewMD5
            ),
            routeUpdate(
                "esp_flasher",
                remotePath: "/ext/apps/GPIO/ESP32/esp_flasher.fap",
                md5: protectedMD5
            ),
        ]

        let result = PluginRouteReconciliation.candidates(
            current: current,
            retiredRoutes: [
                "/ext/apps/Games/4inrow.fap": [sameMD5],
                "/ext/apps/GPIO/24cxxprog.fap": [rebuiltOldMD5],
                "/ext/apps/GPIO/esp_flasher.fap": [protectedMD5],
            ],
            excluded: ["esp_flasher"],
            unprotectedBuiltIns: []
        )
        let candidates = result.values.flatMap { $0 }

        XCTAssertEqual(Set(candidates.map(\.legacyPath)), [
            "/ext/apps/Games/4inrow.fap",
            "/ext/apps/GPIO/24cxxprog.fap",
        ])
        let rebuilt = try XCTUnwrap(candidates.first {
            $0.legacyPath == "/ext/apps/GPIO/24cxxprog.fap"
        })
        XCTAssertEqual(rebuilt.canonicalPath, "/ext/apps/GPIO/Programmers/24cxxprog.fap")
        XCTAssertEqual(rebuilt.canonicalMD5, rebuiltNewMD5)
        XCTAssertEqual(rebuilt.acceptedLegacyMD5s, [rebuiltOldMD5])
        XCTAssertFalse(candidates.contains { $0.legacyPath.contains("esp_flasher") })
    }

    func testRouteCleanupRequiresBothCanonicalAndHistoricalDeviceMD5() {
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: "/ext/apps/GPIO/Programmers/24cxxprog.fap",
            canonicalPath: "/ext/apps/GPIO/Programmers/24cxxprog.fap",
            legacyPath: "/ext/apps/GPIO/24cxxprog.fap",
            canonicalMD5: "33333333333333333333333333333333",
            acceptedLegacyMD5s: ["11111111111111111111111111111111"]
        )

        XCTAssertEqual(
            PluginRouteReconciliation.decision(
                for: candidate,
                canonicalDeviceMD5: candidate.canonicalMD5,
                legacyDeviceMD5: candidate.acceptedLegacyMD5s[0]
            ),
            .remove
        )
        XCTAssertEqual(
            PluginRouteReconciliation.decision(
                for: candidate,
                canonicalDeviceMD5: "22222222222222222222222222222222",
                legacyDeviceMD5: candidate.acceptedLegacyMD5s[0]
            ),
            .keep,
            "A non-canonical replacement must make cleanup fail closed"
        )
        XCTAssertEqual(
            PluginRouteReconciliation.decision(
                for: candidate,
                canonicalDeviceMD5: candidate.canonicalMD5,
                legacyDeviceMD5: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ),
            .keep,
            "A custom or unknown legacy build must be preserved"
        )
        XCTAssertEqual(
            PluginRouteReconciliation.decision(
                for: candidate,
                canonicalDeviceMD5: candidate.canonicalMD5,
                legacyDeviceMD5: nil
            ),
            .missing
        )
    }

    func testAmbiguousOrUnsafeRetiredRoutesAreNeverCandidates() {
        let md5 = "11111111111111111111111111111111"
        let duplicateNames = [
            routeUpdate("clock", remotePath: "/ext/apps/Tools/Clocks/clock.fap", md5: md5),
            routeUpdate("clock", remotePath: "/ext/apps/Media/Clocks/clock.fap", md5: md5),
        ]
        let result = PluginRouteReconciliation.candidates(
            current: duplicateNames,
            retiredRoutes: [
                "/ext/apps/Tools/clock.fap": [md5],
                "/ext/apps/../protected/clock.fap": [md5],
            ],
            excluded: [],
            unprotectedBuiltIns: []
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testCaseOnlyLegacyAliasCanNeverBecomeCleanupCandidate() {
        let md5 = "11111111111111111111111111111111"
        let canonical = "/ext/apps/Games/Board/Chess.fap"
        let caseOnlyAlias = "/EXT/APPS/GAMES/BOARD/chess.FAP"

        XCTAssertEqual(
            PluginRouteReconciliation.pathIdentity(canonical),
            PluginRouteReconciliation.pathIdentity(caseOnlyAlias)
        )
        let result = PluginRouteReconciliation.candidates(
            current: [routeUpdate("Chess", remotePath: canonical, md5: md5)],
            retiredRoutes: [caseOnlyAlias: [md5]],
            excluded: [],
            unprotectedBuiltIns: []
        )

        XCTAssertTrue(
            result.isEmpty,
            "A FAT case-only alias is the canonical file, never an obsolete route"
        )
    }

    func testCleanupExecutorRevalidatesBothPathsImmediatelyBeforeDelete() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate)
        )

        XCTAssertEqual(result.removed, [legacy])
        XCTAssertTrue(result.kept.isEmpty)
        XCTAssertTrue(result.failures.isEmpty)
        let canonicalAfter = await storage.hash(at: canonical)
        let legacyAfter = await storage.hash(at: legacy)
        let events = await storage.recordedEvents()
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(canonicalAfter, newMD5)
        XCTAssertNil(legacyAfter)
        XCTAssertNil(stagedAfter)
        XCTAssertEqual(events, [
            "md5:\(canonical)",
            "md5:\(legacy)",
            "md5:\(staged)",
            "move:\(legacy)->\(staged)",
            "md5:\(canonical)",
            "md5:\(legacy)",
            "md5:\(staged)",
            "delete:\(staged)",
            "md5:\(staged)",
        ])
    }

    func testInstalled15And16RoutesCanBeCleanedWithoutReinstall() async throws {
        let oldPath = "/ext/apps/Games/4inrow.fap"
        let newPath = "/ext/apps/Games/Board/4inrow.fap"
        let md5 = "67067213b636a3a5f3bba182390c0bde"

        // This is the exact legacy state produced when the old app cached 15aug,
        // installed 16aug at its new path, but never removed the old cache entry.
        var cache = PluginCatalogCache(
            tag: "16aug2026",
            map: [oldPath: md5, newPath: md5]
        )
        let current = [routeUpdate("4inrow", remotePath: newPath, md5: md5)]
        cache.reconcileRoutes(current: [newPath: md5])
        let pending = PluginRouteReconciliation.candidates(
            current: current,
            retiredRoutes: cache.retiredRoutes,
            excluded: [],
            unprotectedBuiltIns: [],
            includeInstallRoutes: false
        ).values.flatMap { $0 }
        XCTAssertEqual(pending.count, 1)

        let storage = PluginRouteMemoryStore(hashes: [
            oldPath: md5,
            newPath: md5,
        ])
        let cleanup = await PluginRouteCleanupExecutor.execute(
            pending,
            storage: storage
        )
        for path in cleanup.removed + cleanup.missing {
            cache.forgetRetiredRoute(path)
        }

        XCTAssertEqual(cleanup.removed, [oldPath])
        let canonicalAfter = await storage.hash(at: newPath)
        let legacyAfter = await storage.hash(at: oldPath)
        XCTAssertEqual(canonicalAfter, md5)
        XCTAssertNil(legacyAfter)
        XCTAssertNil(cache.retiredRoutes[oldPath])
        XCTAssertTrue(PluginRouteReconciliation.candidates(
            current: current,
            retiredRoutes: cache.retiredRoutes,
            excluded: [],
            unprotectedBuiltIns: [],
            includeInstallRoutes: false
        ).isEmpty)
    }

    func testInterruptedCleanupMarkerIsRecoveredContentSafely() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            staged: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate)
        )

        XCTAssertEqual(result.removed, [legacy])
        let canonicalAfter = await storage.hash(at: canonical)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(canonicalAfter, newMD5)
        XCTAssertNil(stagedAfter)
    }

    func testInterruptedCleanupRestoresLegacyWhenCanonicalIsNoLongerVerified() async {
        let oldMD5 = "11111111111111111111111111111111"
        let expectedCanonicalMD5 = "22222222222222222222222222222222"
        let changedCanonicalMD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: expectedCanonicalMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: changedCanonicalMD5,
            staged: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate)
        )

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.kept, [legacy])
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
    }

    func testCompletedCopyWithSourceStillPresentFinishesRecovery() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
            staged: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate)
        )

        XCTAssertEqual(result.removed, [legacy])
        XCTAssertTrue(result.failures.isEmpty)
        let canonicalAfter = await storage.hash(at: canonical)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(canonicalAfter, newMD5)
        XCTAssertNil(legacyAfter)
        XCTAssertNil(stagedAfter)
    }

    func testPartialRecoveryMarkerWithIntactSourceSelfHeals() async {
        let oldMD5 = "11111111111111111111111111111111"
        let partialMD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
            staged: partialMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate)
        )

        XCTAssertEqual(result.removed, [legacy])
        XCTAssertTrue(result.failures.isEmpty)
        let canonicalAfter = await storage.hash(at: canonical)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(canonicalAfter, newMD5)
        XCTAssertNil(legacyAfter)
        XCTAssertNil(stagedAfter)
        let events = await storage.recordedEvents()
        XCTAssertTrue(
            events.contains("delete:\(staged)"),
            "the journal-owned partial marker must be removed before retrying"
        )
    }

    func testUnownedPartialMarkerIsPreserved() async {
        let oldMD5 = "11111111111111111111111111111111"
        let partialMD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
            staged: partialMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage
        )

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.kept, [legacy])
        XCTAssertEqual(result.failures.count, 1)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertEqual(stagedAfter, partialMD5)
    }

    func testActiveRecoveryRunsBeforeNewCleanupCandidates() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let firstCanonical = "/ext/apps/Games/Board/alpha.fap"
        let firstLegacy = "/ext/apps/Games/alpha.fap"
        let recoveryCanonical = "/ext/apps/Games/Board/zulu.fap"
        let recoveryLegacy = "/ext/apps/Games/zulu.fap"
        let first = PluginRouteCleanupCandidate(
            catalogPath: firstCanonical,
            canonicalPath: firstCanonical,
            legacyPath: firstLegacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let recovery = PluginRouteCleanupCandidate(
            catalogPath: recoveryCanonical,
            canonicalPath: recoveryCanonical,
            legacyPath: recoveryLegacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let recoveryStage = PluginRouteCleanupExecutor.cleanupStagePath(for: recovery)
        let storage = PluginRouteMemoryStore(hashes: [
            firstCanonical: newMD5,
            firstLegacy: oldMD5,
            recoveryCanonical: newMD5,
            recoveryStage: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [first, recovery],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: recovery)
        )

        XCTAssertEqual(Set(result.removed), Set([firstLegacy, recoveryLegacy]))
        let events = await storage.recordedEvents()
        XCTAssertEqual(
            events.first,
            "md5:\(recoveryCanonical)",
            "the durable active marker must be reconciled before a new candidate can replace it"
        )
    }

    @MainActor
    func testCleanupJournalSurvivesBaselineResetAndRecoversCrashMarker() async {
        let suite = "PluginRouteCleanupJournalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = PluginRouteCleanupJournalStore(
            defaults: defaults,
            key: "cleanup-journal"
        )
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        XCTAssertTrue(journal.record([candidate]))
        XCTAssertTrue(journal.markStaging(candidate))

        let updater = PluginUpdater(
            cleanupJournalStore: journal,
            persistenceDefaults: defaults
        )
        XCTAssertEqual(updater.pendingCleanupCount, 1)
        updater.resetBaseline()
        XCTAssertEqual(
            updater.pendingCleanupCount,
            1,
            "Reset baseline must preserve in-flight cleanup recovery context"
        )

        // Simulate relaunch/check after a crash between move and marker delete.
        let relaunched = PluginUpdater(
            cleanupJournalStore: journal,
            persistenceDefaults: defaults
        )
        XCTAssertEqual(relaunched.pendingCleanupCount, 1)
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            staged: oldMD5,
        ])
        let result = await PluginRouteCleanupExecutor.execute(
            relaunched.pendingRouteCleanup,
            storage: storage,
            stagedRecoveryPaths: journal.recoveryPathIdentities()
        )
        journal.remove(legacyPaths: result.removed + result.missing)

        XCTAssertEqual(result.removed, [legacy])
        XCTAssertTrue(journal.load().isEmpty)
        let finalLaunch = PluginUpdater(
            cleanupJournalStore: journal,
            persistenceDefaults: defaults
        )
        XCTAssertEqual(finalLaunch.pendingCleanupCount, 0)
    }

    @MainActor
    func testProtectedActiveRecoveryRemainsVisibleAndRollsBackOnly() async {
        let suite = "PluginRouteProtectedRecoveryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = PluginRouteCleanupJournalStore(
            defaults: defaults,
            key: "cleanup-journal"
        )
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        XCTAssertTrue(journal.record([candidate]))
        XCTAssertTrue(journal.markStaging(candidate))

        let updater = PluginUpdater(
            cleanupJournalStore: journal,
            persistenceDefaults: defaults
        )
        updater.addExclusion("chess")
        defer { updater.removeExclusion("chess") }
        XCTAssertEqual(
            updater.pendingCleanupCount,
            1,
            "protecting after a crash must not hide the active recovery"
        )

        let relaunched = PluginUpdater(
            cleanupJournalStore: journal,
            persistenceDefaults: defaults
        )
        XCTAssertTrue(relaunched.isProtected("chess"))
        XCTAssertEqual(relaunched.pendingCleanupCount, 1)
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            staged: oldMD5,
        ])
        let recoveryPaths = journal.recoveryPathIdentities()
        let result = await PluginRouteCleanupExecutor.execute(
            relaunched.pendingRouteCleanup,
            storage: storage,
            stagedRecoveryPaths: recoveryPaths,
            rollbackOnlyPaths: recoveryPaths
        )
        XCTAssertTrue(journal.remove(legacyPaths: result.rolledBack))

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.rolledBack, [legacy])
        let canonicalAfter = await storage.hash(at: canonical)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(canonicalAfter, newMD5)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
        XCTAssertTrue(journal.load().isEmpty)
    }

    func testCleanupDoesNotMoveWhenActiveJournalCannotBePersisted() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            willStage: { _ in throw PluginRouteTestStoreError.unsupported }
        )

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.kept, [legacy])
        XCTAssertEqual(result.failures.count, 1)
        let legacyAfter = await storage.hash(at: legacy)
        let events = await storage.recordedEvents()
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertFalse(events.contains { $0.hasPrefix("move:") || $0.hasPrefix("delete:") })
    }

    @MainActor
    func testCleanupPreservesProtectedFALFamilyBeforeAnyLegacyMutation() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps_data/arf_subghz_full/modules/proto_pirate.fal"
        let legacy = "/ext/apps/Module One/Sub-GHz/proto_pirate.fal"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            shouldPreserve: { candidate in
                let name = ((candidate.catalogPath as NSString).lastPathComponent as NSString)
                    .deletingPathExtension
                return PluginProtectionPolicy.isProtected(
                    name: name,
                    remotePath: candidate.canonicalPath,
                    excluded: ["arf_subghz_full"],
                    unprotectedBuiltIns: []
                )
            }
        )

        XCTAssertEqual(result.rolledBack, [legacy])
        XCTAssertTrue(result.removed.isEmpty)
        let legacyAfter = await storage.hash(at: legacy)
        XCTAssertEqual(legacyAfter, oldMD5)
        let events = await storage.recordedEvents()
        XCTAssertFalse(events.contains { $0.hasPrefix("move:") || $0.hasPrefix("delete:\(legacy)") })
    }

    @MainActor
    func testProtectionAfterDurableStageIntentRollsBackWithoutMovingLegacy() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
        ])
        var durableStageIntentWritten = false
        var recoveryIntentCleared = false

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            shouldPreserve: { _ in durableStageIntentWritten },
            didObserveNoStage: { _ in recoveryIntentCleared = true },
            willStage: { _ in durableStageIntentWritten = true }
        )

        XCTAssertTrue(durableStageIntentWritten)
        XCTAssertTrue(recoveryIntentCleared)
        XCTAssertEqual(result.rolledBack, [legacy])
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(
            at: PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        )
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
        let events = await storage.recordedEvents()
        XCTAssertFalse(events.contains { $0.hasPrefix("move:") })
    }

    @MainActor
    func testProtectionAfterMarkerStagingRestoresLegacyThroughDynamicPolicy() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let staged = PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            staged: oldMD5,
        ])
        var clearedRecoveryIntent = false

        // This is the exact post-crash state after the legacy FAP has already been
        // staged. A protection added before recovery must be read dynamically,
        // restore the owned marker, and never continue cleanup from a stale snapshot.
        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            stagedRecoveryPaths: recoveryPaths(for: candidate),
            shouldPreserve: { _ in true },
            didObserveNoStage: { _ in clearedRecoveryIntent = true }
        )

        XCTAssertTrue(clearedRecoveryIntent)
        XCTAssertEqual(result.rolledBack, [legacy])
        XCTAssertTrue(result.removed.isEmpty)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
        let events = await storage.recordedEvents()
        XCTAssertFalse(events.contains("delete:\(legacy)"))
    }

    @MainActor
    func testPreProtectedCatalogEntryStaysPendingWhileAnotherAppInstalls() async throws {
        let suite = "PluginInstallCachePreProtectedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await makeCacheReconciliationFixture(
            storage: PluginInstallMemoryStore(),
            defaults: defaults
        )
        defer {
            fixture.archives.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: fixture.auditDirectory)
        }

        XCTAssertEqual(
            Set(fixture.updater.updates.map(\.remotePath)),
            [fixture.chessPath, fixture.checkersPath]
        )
        XCTAssertTrue(fixture.updater.addExclusion("chess"))
        XCTAssertEqual(
            fixture.updater.updates.map(\.remotePath),
            [fixture.checkersPath],
            "Protection removes chess from the mutable UI list before the transaction starts."
        )

        await fixture.updater.install()

        let cache = try XCTUnwrap(fixture.updater.cacheForTesting())
        XCTAssertEqual(
            cache.map[fixture.chessPath], fixture.oldChessMD5,
            "A path protected before the transaction must not be advanced just because it is absent from updates."
        )
        XCTAssertEqual(cache.map[fixture.checkersPath], fixture.newCheckersMD5)
        XCTAssertTrue(fixture.updater.removeExclusion("chess"))

        await fixture.updater.check()
        XCTAssertEqual(
            fixture.updater.updates.map(\.remotePath), [fixture.chessPath],
            "An ordinary Check must surface the still-pending pre-protected app."
        )
    }

    @MainActor
    func testUnprotectedButPreviouslyHiddenEntryStaysPendingUntilOrdinaryCheck() async throws {
        let suite = "PluginInstallCacheUnprotectedHiddenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await makeCacheReconciliationFixture(
            storage: PluginInstallMemoryStore(),
            defaults: defaults
        )
        defer {
            fixture.archives.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: fixture.auditDirectory)
        }

        XCTAssertTrue(fixture.updater.addExclusion("chess"))
        XCTAssertTrue(
            fixture.updater.removeExclusion("chess"),
            "Removing protection must not claim an unverified binary is current."
        )
        XCTAssertEqual(
            fixture.updater.updates.map(\.remotePath), [fixture.checkersPath],
            "Unprotecting does not recreate a row; only a subsequent Check may do that."
        )

        await fixture.updater.install()

        let cache = try XCTUnwrap(fixture.updater.cacheForTesting())
        XCTAssertEqual(cache.map[fixture.chessPath], fixture.oldChessMD5)
        XCTAssertEqual(cache.map[fixture.checkersPath], fixture.newCheckersMD5)

        await fixture.updater.check()
        XCTAssertEqual(
            fixture.updater.updates.map(\.remotePath), [fixture.chessPath],
            "An old cache entry hidden by a protection toggle must reappear after ordinary Check."
        )
    }

    @MainActor
    func testProtectionDuringStagingKeepsSelectedAndUnselectedUpdatesPending() async throws {
        let suite = "PluginInstallCacheStagingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let staging = PluginInstallTestLatch()
        let fixture = try await makeCacheReconciliationFixture(
            storage: PluginInstallMemoryStore(stagingLatch: staging),
            defaults: defaults
        )
        defer {
            fixture.archives.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: fixture.auditDirectory)
        }

        let checkersID = try XCTUnwrap(
            fixture.updater.updates.first { $0.remotePath == fixture.checkersPath }?.id
        )
        fixture.updater.setSelected(false, id: checkersID)
        XCTAssertEqual(
            fixture.updater.updates.filter(\.selected).map(\.remotePath), [fixture.chessPath]
        )

        let installation = Task { @MainActor in
            await fixture.updater.install()
        }
        await staging.waitForStaging()

        XCTAssertTrue(fixture.updater.addExclusion("chess"))
        XCTAssertTrue(fixture.updater.addExclusion("checkers"))
        XCTAssertTrue(
            fixture.updater.updates.isEmpty,
            "Both rows disappear from mutable UI state once protection is accepted."
        )
        await staging.release()
        await installation.value

        let cache = try XCTUnwrap(fixture.updater.cacheForTesting())
        XCTAssertEqual(cache.map[fixture.chessPath], fixture.oldChessMD5)
        XCTAssertEqual(
            cache.map[fixture.checkersPath], fixture.oldCheckersMD5,
            "The unselected pending row must not gain a new MD5 when it is protected during another app's staging."
        )
        XCTAssertTrue(fixture.updater.removeExclusion("chess"))
        XCTAssertTrue(fixture.updater.removeExclusion("checkers"))

        await fixture.updater.check()
        XCTAssertEqual(
            Set(fixture.updater.updates.map(\.remotePath)),
            [fixture.chessPath, fixture.checkersPath],
            "After protection is lifted, an ordinary Check must surface both untouched updates."
        )
    }

    @MainActor
    func testInstallCommitKeepsLiveTargetWhenProtectionArrivesAfterStaging() async throws {
        let suite = "PluginInstallProtectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = PluginUpdater(persistenceDefaults: defaults)
        let target = "/ext/apps/Games/Board/chess.fap"
        let temp = target + ".ucnew"
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let update = routeUpdate("chess", remotePath: target, md5: newMD5)
        let storage = PluginRouteMemoryStore(hashes: [
            target: oldMD5,
            temp: newMD5,
        ])

        XCTAssertTrue(updater.addExclusion("chess"))
        let committed = try await updater.commitStagedInstallForTesting(
            update,
            tempPath: temp,
            storage: storage
        )
        XCTAssertFalse(committed)

        let targetAfter = await storage.hash(at: target)
        let tempAfter = await storage.hash(at: temp)
        let events = await storage.recordedEvents()
        XCTAssertEqual(targetAfter, oldMD5)
        XCTAssertEqual(tempAfter, newMD5)
        XCTAssertFalse(events.contains { $0.hasPrefix("delete:\(target)") })
        XCTAssertFalse(events.contains { $0.hasPrefix("move:\(temp)->\(target)") })
    }

    @MainActor
    func testProtectionRequestInsideIrreversibleFenceIsNotAcknowledged() async {
        let suite = "PluginProtectionFenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = PluginProtectionMutationGate()
        let updater = PluginUpdater(
            persistenceDefaults: defaults,
            protectionMutationGate: gate
        )
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: oldMD5,
        ])
        var requestWasAccepted: Bool?

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage,
            shouldPreserve: { _ in updater.isProtected("chess") },
            beginIrreversibleMutation: {
                guard gate.begin() else { return false }
                requestWasAccepted = updater.addExclusion("chess")
                return true
            },
            endIrreversibleMutation: { gate.end() }
        )

        XCTAssertEqual(requestWasAccepted, false)
        XCTAssertFalse(updater.isProtected("chess"))
        XCTAssertNil(defaults.array(forKey: "pluginExcluded"))
        XCTAssertEqual(result.removed, [legacy])
    }

    @MainActor
    func testProtectionChangePersistsBeforeItIsAcknowledged() {
        let suite = "PluginProtectionPersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = PluginUpdater(persistenceDefaults: defaults)

        XCTAssertTrue(updater.addExclusion("chess"))
        let relaunched = PluginUpdater(persistenceDefaults: defaults)

        XCTAssertTrue(relaunched.isProtected("chess"))
        XCTAssertTrue((defaults.array(forKey: "pluginExcluded") as? [String] ?? [])
            .contains("chess"))
    }

    func testModifiedLegacyFileIsNeverMovedOrDeleted() async {
        let acceptedOldMD5 = "11111111111111111111111111111111"
        let customMD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let newMD5 = "22222222222222222222222222222222"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [acceptedOldMD5]
        )
        let storage = PluginRouteMemoryStore(hashes: [
            canonical: newMD5,
            legacy: customMD5,
        ])

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage
        )

        XCTAssertEqual(result.kept, [legacy])
        XCTAssertTrue(result.removed.isEmpty)
        let legacyAfter = await storage.hash(at: legacy)
        let events = await storage.recordedEvents()
        XCTAssertEqual(legacyAfter, customMD5)
        XCTAssertFalse(events.contains { $0.hasPrefix("move:") || $0.hasPrefix("delete:") })
    }

    func testCanonicalChangeAfterStagingRestoresLegacyInsteadOfDeleting() async {
        let oldMD5 = "11111111111111111111111111111111"
        let newMD5 = "22222222222222222222222222222222"
        let changedMD5 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let canonical = "/ext/apps/Games/Board/chess.fap"
        let legacy = "/ext/apps/Games/chess.fap"
        let candidate = PluginRouteCleanupCandidate(
            catalogPath: canonical,
            canonicalPath: canonical,
            legacyPath: legacy,
            canonicalMD5: newMD5,
            acceptedLegacyMD5s: [oldMD5]
        )
        let storage = PluginRouteMemoryStore(
            hashes: [canonical: newMD5, legacy: oldMD5],
            hashesAfterMove: [canonical: changedMD5]
        )

        let result = await PluginRouteCleanupExecutor.execute(
            [candidate],
            storage: storage
        )

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.kept, [legacy])
        XCTAssertEqual(result.failures.count, 1)
        let canonicalAfter = await storage.hash(at: canonical)
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(
            at: PluginRouteCleanupExecutor.cleanupStagePath(for: candidate)
        )
        XCTAssertEqual(canonicalAfter, changedMD5)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
    }

    @MainActor
    func testCommunityMutationGateRejectsConcurrentTransaction() async {
        let gate = PluginTransactionGate()
        let entered = expectation(description: "first mutation entered")
        let release = PluginRouteTestLatch()
        let first = Task { @MainActor in
            XCTAssertTrue(gate.begin())
            entered.fulfill()
            await release.wait()
            gate.end()
        }

        await fulfillment(of: [entered], timeout: 1)
        XCTAssertFalse(
            gate.begin(),
            "cleanup must not overlap an install suspended on device I/O"
        )

        await release.open()
        await first.value
        XCTAssertTrue(gate.begin(), "the next mutation may start after completion")
        gate.end()
    }

    func testIntentionalAppsDataRouteStillUsesGuardedCleanup() throws {
        let md5 = "11111111111111111111111111111111"
        let remotePath = "/ext/apps/Sub-GHz/proto_pirate.fap"
        let result = PluginRouteReconciliation.candidates(
            current: [routeUpdate("proto_pirate", remotePath: remotePath, md5: md5)],
            retiredRoutes: [:],
            excluded: [],
            unprotectedBuiltIns: []
        )

        let candidate = try XCTUnwrap(result[remotePath]?.first)
        XCTAssertEqual(
            candidate.canonicalPath,
            "/ext/apps_data/arf_subghz_full/modules/proto_pirate.fap"
        )
        XCTAssertEqual(candidate.legacyPath, remotePath)
        XCTAssertEqual(candidate.acceptedLegacyMD5s, [md5])
    }

    func testCatalogCannotOverwriteProtectedClaudeBuddy() {
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "claude_buddy"))
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "claude_buddy.fap"))
        XCTAssertNil(CatalogInstallPolicy.protectionReason(alias: "weather_station"))
    }

    func testCatalogCannotOverwriteTumoKeyVariants() {
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "tumokey"))
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "tumokey.fap"))
        XCTAssertNotNil(CatalogInstallPolicy.protectionReason(alias: "tumokey_phase_a"))
    }
}

private enum PluginRouteTestStoreError: Error {
    case unsupported
}

private actor PluginRouteMemoryStore: DeviceFileStore {
    nonisolated let channel: TransferChannel = .usb
    private var hashes: [String: String]
    private let hashesAfterMove: [String: String]
    private var events: [String] = []

    init(hashes: [String: String], hashesAfterMove: [String: String] = [:]) {
        self.hashes = Dictionary(
            uniqueKeysWithValues: hashes.map {
                (PluginRouteReconciliation.pathIdentity($0.key), $0.value)
            }
        )
        self.hashesAfterMove = Dictionary(
            uniqueKeysWithValues: hashesAfterMove.map {
                (PluginRouteReconciliation.pathIdentity($0.key), $0.value)
            }
        )
    }

    func hash(at path: String) -> String? {
        hashes[PluginRouteReconciliation.pathIdentity(path)]
    }

    func recordedEvents() -> [String] {
        events
    }

    func list(_ path: String) async throws -> [FlipperFile] {
        throw PluginRouteTestStoreError.unsupported
    }

    func read(_ path: String) async throws -> Data {
        throw PluginRouteTestStoreError.unsupported
    }

    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)?
    ) async throws {
        throw PluginRouteTestStoreError.unsupported
    }

    func makeDirectory(_ path: String) async throws {}

    func delete(_ path: String, recursive: Bool) async throws {
        events.append("delete:\(path)")
        hashes.removeValue(forKey: PluginRouteReconciliation.pathIdentity(path))
    }

    func move(_ from: String, to newPath: String) async throws {
        events.append("move:\(from)->\(newPath)")
        let source = PluginRouteReconciliation.pathIdentity(from)
        guard let hash = hashes.removeValue(forKey: source) else {
            throw PluginRouteTestStoreError.unsupported
        }
        hashes[PluginRouteReconciliation.pathIdentity(newPath)] = hash
        hashes.merge(hashesAfterMove) { _, replacement in replacement }
    }

    func md5(_ path: String) async -> String? {
        hashes[PluginRouteReconciliation.pathIdentity(path)]
    }

    func checkedMD5(_ path: String) async throws -> String? {
        events.append("md5:\(path)")
        return hashes[PluginRouteReconciliation.pathIdentity(path)]
    }

    func exists(_ path: String) async -> Bool {
        hashes[PluginRouteReconciliation.pathIdentity(path)] != nil
    }

    func uploadFolder(
        localURL: URL,
        to destination: String,
        progress: @escaping (UploadProgress) -> Void
    ) async throws {
        throw PluginRouteTestStoreError.unsupported
    }
}

private actor PluginRouteTestLatch {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private enum PluginInstallTestStoreError: Error {
    case missing
    case unsupported
}

/// A deterministic USB-like store for the real PluginUpdater.install() path. It can
/// pause only after the temporary FAP is whole, which gives the test a precise point
/// to submit protection changes before the irreversible live-target commit.
private actor PluginInstallMemoryStore: DeviceFileStore {
    nonisolated let channel: TransferChannel = .usb
    private var files: [String: Data] = [:]
    private let stagingLatch: PluginInstallTestLatch?

    init(stagingLatch: PluginInstallTestLatch? = nil) {
        self.stagingLatch = stagingLatch
    }

    private func identity(_ path: String) -> String {
        PluginRouteReconciliation.pathIdentity(path)
    }

    private func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func list(_ path: String) async throws -> [FlipperFile] {
        []
    }

    func read(_ path: String) async throws -> Data {
        guard let data = files[identity(path)] else {
            throw PluginInstallTestStoreError.missing
        }
        return data
    }

    func write(
        _ path: String,
        data: Data,
        progress: (@Sendable (Int) -> Void)?
    ) async throws {
        files[identity(path)] = data
        progress?(data.count)
        if path.hasSuffix(".ucnew") {
            await stagingLatch?.stageAndWaitForRelease()
        }
    }

    func makeDirectory(_ path: String) async throws {}

    func delete(_ path: String, recursive: Bool) async throws {
        files.removeValue(forKey: identity(path))
    }

    func move(_ from: String, to newPath: String) async throws {
        guard let data = files.removeValue(forKey: identity(from)) else {
            throw PluginInstallTestStoreError.missing
        }
        files[identity(newPath)] = data
    }

    func md5(_ path: String) async -> String? {
        files[identity(path)].map(md5)
    }

    func checkedMD5(_ path: String) async throws -> String? {
        files[identity(path)].map(md5)
    }

    func exists(_ path: String) async -> Bool {
        files[identity(path)] != nil
    }

    func uploadFolder(
        localURL: URL,
        to destination: String,
        progress: @escaping (UploadProgress) -> Void
    ) async throws {
        throw PluginInstallTestStoreError.unsupported
    }
}

private actor PluginInstallTestLatch {
    private var staged = false
    private var released = false
    private var stagingContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func stageAndWaitForRelease() async {
        staged = true
        stagingContinuation?.resume()
        stagingContinuation = nil
        await withCheckedContinuation { continuation in
            if released {
                continuation.resume()
            } else {
                releaseContinuation = continuation
            }
        }
    }

    func waitForStaging() async {
        guard !staged else { return }
        await withCheckedContinuation { continuation in
            stagingContinuation = continuation
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
