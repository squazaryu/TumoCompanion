import XCTest
@testable import UnleashedCompanion

/// Tests for the tumoflip package "Up to date / Update available" status check
/// (companion #9): pure ledger↔manifest comparison, by content hash, per group.
final class TumoflipStatusTests: XCTestCase {

    private let rid = String(repeating: "c", count: 64)

    private func pkg(_ source: String, _ target: String, _ sha: String) -> TumoflipManifest.PackageFile {
        .init(bytes: 1, sha256: sha, source: source, target: target)
    }
    private func manifest(_ packages: [String: [TumoflipManifest.PackageFile]]) -> TumoflipManifest {
        TumoflipManifest(schema: 2, releaseId: rid,
                         firmware: .init(api: "87.14", name: "tumoflip", version: "v", target: 7, radioAddress: nil),
                         artifacts: [:], packages: packages, cleanup: [], safety: nil)
    }
    private func ledger(_ entries: [(String, String)]) -> [String: TumoflipState.LedgerEntry] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.0, TumoflipState.LedgerEntry(sha256: $0.1, md5: "m", releaseId: rid)) })
    }
    private func status(_ group: String, _ m: TumoflipManifest,
                        _ l: [String: TumoflipState.LedgerEntry]) -> TumoflipInstaller.GroupStatus {
        TumoflipInstaller.groupStatus(for: group, manifest: m, ledger: l)
    }

    private func twoFileBase() -> TumoflipManifest {
        manifest(["base": [pkg("a", "/ext/a", "aa"), pkg("b", "/ext/b", "bb")],
                  "arf": [], "module_one": [], "protocol_packs": []])
    }

    func testNotInstalledWhenLedgerEmpty() {
        XCTAssertEqual(status("base", twoFileBase(), [:]), .notInstalled)
    }

    func testUpToDateWhenAllMatch() {
        let l = ledger([("/ext/a", "aa"), ("/ext/b", "bb")])
        XCTAssertEqual(status("base", twoFileBase(), l), .upToDate)
    }

    func testUpdateAvailableWhenOneShaDiffers() {
        // /ext/b recorded at an OLD sha → out of date, even though it's present.
        let l = ledger([("/ext/a", "aa"), ("/ext/b", "OLDSHA")])
        XCTAssertEqual(status("base", twoFileBase(), l), .updateAvailable)
    }

    func testUpdateAvailableWhenPartiallyInstalled() {
        let l = ledger([("/ext/a", "aa")])     // only one of the two targets present
        XCTAssertEqual(status("base", twoFileBase(), l), .updateAvailable)
    }

    func testEmptyGroupHasNoStatus() {
        let m = manifest(["base": [], "arf": [], "module_one": [], "protocol_packs": []])
        XCTAssertEqual(status("base", m, [:]), .empty)
    }

    func testGroupsAreIndependent() {
        // Base installed up to date; ARF not installed — incremental groups don't bleed.
        let m = manifest(["base": [pkg("a", "/ext/a", "aa")],
                          "arf": [pkg("c", "/ext/c", "cc")],
                          "module_one": [], "protocol_packs": []])
        let l = ledger([("/ext/a", "aa")])
        XCTAssertEqual(status("base", m, l), .upToDate)
        XCTAssertEqual(status("arf", m, l), .notInstalled)
    }

    func testPendingInstallTargetsExcludeOnlyVerifiedCurrentSelections() {
        let selected: Set<String> = ["/ext/current", "/ext/changed", "/ext/missing", "/ext/unknown"]
        let statuses: [String: TumoflipInstaller.FileStatus] = [
            "/ext/current": .upToDate,
            "/ext/changed": .needsUpdate,
            "/ext/missing": .missing,
        ]

        XCTAssertEqual(
            TumoflipUpdater.pendingInstallTargets(
                selected: selected,
                statuses: statuses
            ),
            Set(["/ext/changed", "/ext/missing", "/ext/unknown"])
        )
    }

    func testPendingInstallTargetsKeepValidationFailuresFailClosed() {
        XCTAssertEqual(
            TumoflipUpdater.pendingInstallTargets(
                selected: ["/ext/failed", "/ext/unselected"],
                statuses: [
                    "/ext/failed": .validationError,
                    "/ext/unselected": .upToDate,
                    "/ext/not-selected": .needsUpdate,
                ]
            ),
            Set(["/ext/failed"])
        )
    }

    @MainActor
    func testFWPackageTransactionGateRejectsOverlappingMutation() {
        let gate = TumoflipTransactionGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin(), "a second install must not queue another staging upload")

        gate.end()
        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin(), "the next user transaction may start after completion")
        gate.end()
    }
}
