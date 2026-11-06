"""Execute real cleanup/cache code on macOS without a device or Simulator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Sources/Features/Updates/PluginUpdater.swift').read_text()


def function(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


models = source[source.index('enum PluginInstallRouting {'):source.index('\nenum PluginCatalogMetadata:')]
core = source[source.index('struct PluginCatalogCache:'):source.index('\nstruct InstallRecord:')]
extras = ''
for name in ('enum PluginRouteCleanupKeepReason:', 'enum PluginRouteCleanupAssessment:'):
    if name in source:
        start = source.index(name)
        extras += source[start:source.index('\n}', start) + 2] + '\n'
methods = '\n'.join(function(name) for name in (
    '    private func standaloneCleanupCandidates(',
    '    private func isCleanupAllowed(',
    '    private func eligibleJournalCleanupCandidates(',
    '    private func cleanupCandidates(',
))
program = 'import Foundation\n' + models + extras + r'''
protocol DeviceFileStore: Sendable {
    func checkedMD5(_ path: String) async throws -> String?
    func move(_ from: String, to: String) async throws
    func delete(_ path: String, recursive: Bool) async throws
}
''' + core + r'''
@MainActor final class CandidateState {
    var allManifest: [String: PluginUpdate]
    let excluded: Set<String> = []
    let unprotectedBuiltIns: Set<String> = []
    let cleanupJournalStore: PluginRouteCleanupJournalStore
    init(_ current: [PluginUpdate], _ journal: PluginRouteCleanupJournalStore) {
        allManifest = Dictionary(uniqueKeysWithValues: current.map { ($0.remotePath, $0) })
        cleanupJournalStore = journal
    }
    func pending(_ cache: PluginCatalogCache?) -> [PluginRouteCleanupCandidate] {
        cleanupCandidates(cache: cache)
    }
''' + methods + r'''
}
@main struct Main {
    @MainActor static func main() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let old = "/ext/apps/Sub-GHz/tpms_bridge.fap"
        let current = "/ext/apps/Sub-GHz/Sensors/tpms_bridge.fap"
        let before = String(repeating: "1", count: 32)
        let now = String(repeating: "2", count: 32)
        let legacy = String(repeating: "3", count: 32)
        let update = PluginUpdate(remotePath: current, name: "tpms_bridge", category: "Sensors",
            pack: "extra", newMD5: now, oldMD5: before, size: 40_680)
        var cache = PluginCatalogCache(tag: "new", map: [current: now],
            retiredRoutes: [old: [legacy], old.uppercased(): [legacy]])
        cache.forgetRetiredRoute(old.lowercased())
        check(cache.retiredRoutes.isEmpty, "forget removes every FAT-equivalent history key")

        let suite = "CommunityCleanupHost." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = PluginRouteCleanupJournalStore(defaults: defaults, key: "pending")
        let stale = PluginRouteCleanupCandidate(catalogPath: current, canonicalPath: current,
            legacyPath: old, canonicalMD5: before, acceptedLegacyMD5s: [legacy])
        check(journal.record([stale]), "initial pending context persisted")
        let state = CandidateState([update], journal)
        let freshCache = PluginCatalogCache(tag: "new", map: [current: now],
            retiredRoutes: [old: [legacy]])
        let refreshed = state.pending(freshCache)
        check(refreshed.count == 1 && refreshed.first?.canonicalMD5 == now,
            "unstaged pending journal follows current catalog hash")
        let fresh = PluginRouteCleanupCandidate(catalogPath: current, canonicalPath: current,
            legacyPath: old, canonicalMD5: now, acceptedLegacyMD5s: [legacy])
        check(journal.record([fresh]) && journal.load() == [fresh],
            "pending metadata update is durable and not dropped as a conflict")

        let active = PluginRouteCleanupJournalStore(defaults: defaults, key: "active")
        check(active.record([stale]) && active.markStaging(stale), "owned staging context persisted")
        let activeState = CandidateState([update], active)
        check(activeState.pending(freshCache) == [stale],
            "active recovery retains its exact old ownership and hash")
        _ = active.record([fresh])
        check(active.load() == [stale], "pending refresh cannot overwrite active recovery")
        let migration = PluginRouteCleanupCandidate(catalogPath: current, canonicalPath: current,
            legacyPath: old, canonicalMD5: now, acceptedLegacyMD5s: [now])
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: now,
            legacyDeviceMD5: legacy, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .removable, "both content proofs allow cleanup")
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: nil,
            legacyDeviceMD5: legacy, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .review(.canonicalMissing), "missing replacement is review, not cleanable")
        check(PluginRouteReconciliation.assessment(for: migration, canonicalDeviceMD5: nil,
            legacyDeviceMD5: now, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .needsMigration, "same bytes at old route need explicit migration")
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: before,
            legacyDeviceMD5: legacy, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .review(.canonicalMismatch), "different replacement stays protected")
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: now,
            legacyDeviceMD5: before, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .review(.legacyUnrecognized), "unknown legacy is not deleted")
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: now,
            legacyDeviceMD5: nil, stagedDeviceMD5: nil, ownsRecovery: false,
            catalogMatches: true) == .missing, "absent old path is resolved without deletion")
        check(PluginRouteReconciliation.assessment(for: fresh, canonicalDeviceMD5: now,
            legacyDeviceMD5: legacy, stagedDeviceMD5: legacy, ownsRecovery: false,
            catalogMatches: true) == .review(.unownedRecovery), "unowned marker is never adopted")
        check(PluginRouteReconciliation.assessment(for: stale, canonicalDeviceMD5: now,
            legacyDeviceMD5: nil, stagedDeviceMD5: legacy, ownsRecovery: true,
            catalogMatches: false) == .recovery, "owned recovery can safely roll back stale catalog context")
        check(!PluginRouteCleanupAssessment.review(.canonicalMissing).isActionable,
            "kept review does not inflate Clean Up count")
        check(PluginRouteCleanupAssessment.removable.isActionable
            && PluginRouteCleanupAssessment.recovery.isActionable, "only cleanup/recovery is actionable")
        print("Cleanup/cache host failures: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='tumo-community-cleanup-host-') as directory:
    work = Path(directory)
    (work / 'probe.swift').write_text(program)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
                    str(work / 'probe.swift'), '-o', str(work / 'probe')], check=True)
    subprocess.run([str(work / 'probe')], check=True)
