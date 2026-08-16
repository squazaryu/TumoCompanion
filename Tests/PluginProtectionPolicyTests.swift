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
