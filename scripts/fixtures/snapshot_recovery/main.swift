@main struct Main {
    static func main() throws {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            FileHandle.standardError.write(Data("\(condition ? "PASS" : "FAIL"): \(label)\n".utf8))
            if !condition { failures += 1 }
        }
        var package: [String: Any] = [
            "type": "package-only", "id": "fw-packages-dev-032", "catalog_release_tag": "fw-packages-dev-032",
            "source_commit": String(repeating: "1", count: 40), "source_dirty": false,
            "source_firmware_version": "t-dev-011-001", "target_release_tag": "t-dev-011-001",
            "target_release_id": String(repeating: "e", count: 64),
            "target_source_commit": String(repeating: "1", count: 40),
            "target_firmware_commit": String(repeating: "1", count: 40),
            "firmware_flash_unchanged": true, "catalog_channel": "dev", "catalog_revision": 32,
            "catalog_install_scope": "firmwareSnapshot", "overlay_targets": [], "compatible_releases": [],
        ]
        var json: [String: Any] = [
            "schema": 2, "release_id": String(repeating: "a", count: 64),
            "firmware": ["name": "tumoflip", "version": "t-dev-011-001", "api": "88.23", "target": 7],
            "artifacts": [:], "cleanup": [],
            "packages": ["base": [["source": "apps/Tools/fixture.fap", "target": "/ext/apps/Tools/fixture.fap",
                                   "bytes": 1, "sha256": String(repeating: "b", count: 64)]],
                         "arf": [], "module_one": [], "protocol_packs": []],
            "package_release": package,
        ]
        func manifest(_ value: [String: Any]) throws -> TumoflipManifest {
            try TumoflipManifest.decode(JSONSerialization.data(withJSONObject: value))
        }
        do {
            let value = try manifest(json)
            try value.validate()
            check(value.isFirmwareSnapshotCatalog && !value.isReferenceOnlyCatalog,
                  "explicit Dev snapshot exposes the complete exact-build surface")
        } catch { check(false, "Dev snapshot rejected: \(error)") }
        for field in ["target_source_commit", "target_firmware_commit"] {
            var changed = package
            changed[field] = String(repeating: "2", count: 40)
            var invalid = json
            invalid["package_release"] = changed
            do { try manifest(invalid).validate(); check(false, "mismatched \(field) accepted") }
            catch { check(true, "mismatched \(field) rejected") }
        }
        package["target_release_tag"] = "t-dev-011-002"
        json["package_release"] = package
        do { try manifest(json).validate(); check(false, "different Dev tag accepted") }
        catch { check(true, "different Dev tag rejected") }

        let suite = "tumo-recovery-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        func recoveryChecks() throws {
            defer { defaults.removePersistentDomain(forName: suite) }
            let first = TransferRecoveryStore(defaults: defaults, key: "first")
            let second = TransferRecoveryStore(defaults: defaults, key: "second")
            let firmware = TransferRecoveryCheckpoint(kind: .firmware, completed: 1, total: 3, detail: "test")
            let packages = TransferRecoveryCheckpoint(kind: .packages, completed: 2, total: 4, detail: "test")
            check(first.save(firmware) && first.save(packages), "checkpoint writes verified")
            check(first.load(kind: .firmware) == firmware, "transfer kinds are isolated")
            check(second.loadAll().isEmpty, "store prefixes are isolated")
            first.clear(kind: .firmware)
            check(first.load(kind: .packages) == packages && first.load(kind: .firmware) == nil,
                  "clearing one kind retains the other")
            defaults.set(try JSONEncoder().encode(packages), forKey: "(key).(kind.rawValue)")
            let standard = TransferRecoveryStore(defaults: defaults)
            check(standard.load(kind: .packages) == packages && standard.load(kind: .firmware) == nil,
                  "known broken legacy key is scoped to the default store and matching kind")
            standard.clear(kind: .firmware)
            check(defaults.data(forKey: "(key).(kind.rawValue)") != nil, "other legacy kind retained")
            standard.clear(kind: .packages)
            check(defaults.data(forKey: "(key).(kind.rawValue)") == nil, "matching legacy checkpoint cleared")
            defaults.set(try JSONEncoder().encode(packages), forKey: "first.firmware")
            check(first.load(kind: .firmware) == nil, "scoped wrong-kind payload rejected")
        }
        try recoveryChecks()
        if failures > 0 { throw NSError(domain: "snapshot-recovery-fixture", code: failures) }
    }
}
