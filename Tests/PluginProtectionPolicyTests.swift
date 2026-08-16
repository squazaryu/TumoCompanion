import XCTest
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
            storage: storage
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
            storage: storage
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
            storage: storage
        )

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.kept, [legacy])
        let legacyAfter = await storage.hash(at: legacy)
        let stagedAfter = await storage.hash(at: staged)
        XCTAssertEqual(legacyAfter, oldMD5)
        XCTAssertNil(stagedAfter)
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
