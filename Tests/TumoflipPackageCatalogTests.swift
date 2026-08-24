import Foundation
import XCTest
@testable import UnleashedCompanion

final class TumoflipPackageCatalogTests: XCTestCase {
    func testPrimaryCatalogWinsWithoutMixingLegacyRevisions() async throws {
        let primary = release(id: 9, tag: "fw-packages-dev-009")
        let legacy = release(id: 108, tag: "fw-packages-dev-108")
        let client = makeClient(
            primaryPages: [releasesData([primary])],
            legacyPages: [releasesData([legacy])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(tag: "fw-packages-dev-009", revision: 9),
                manifestURL("fw-packages-dev-108"): manifest(tag: "fw-packages-dev-108", revision: 108),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015"
        )

        XCTAssertEqual(selected.release.repository, .primary)
        XCTAssertEqual(selected.release.tag, "fw-packages-dev-009")
        XCTAssertEqual(selected.identity.catalogRevision, 9)
    }

    func testCatalogIndexDigestMismatchFailsClosedBeforeSelection() async throws {
        let tag = "fw-packages-dev-009"
        let manifestData = manifest(tag: tag, revision: 9)
        let client = makeClient(
            primaryPages: [releasesData([release(id: 9, tag: tag)])],
            manifests: [manifestURL(tag): manifestData],
            catalogIndex: catalogIndex(
                channel: "dev",
                tag: tag,
                revision: 9,
                manifestReleaseID: String(repeating: "d", count: 64),
                manifestSHA256: String(repeating: "a", count: 64)
            )
        )

        do {
            _ = try await client.latest(
                for: .dev,
                installedVersion: "t-dev-004-015",
                installedAPI: "88.0",
                installedTarget: 7
            )
            XCTFail("An index digest mismatch must stop catalog selection")
        } catch let error as TumoflipPackageCatalogError {
            guard case .malformedPrimary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAvailableReturnsImmutableHistoryNewestFirst() async throws {
        let newer = release(id: 9, tag: "fw-packages-dev-009")
        let older = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            primaryPages: [releasesData([older, newer])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(tag: "fw-packages-dev-009", revision: 9),
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        let selections = try await client.available(
            for: .dev,
            installedVersion: "t-dev-004-015",
            installedAPI: "88.0",
            installedTarget: 7
        )

        XCTAssertEqual(selections.map(\.revision), [9, 8])
    }

    func testLatestCanPinAnOlderRevisionForRollback() async throws {
        let newer = release(id: 9, tag: "fw-packages-dev-009")
        let older = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            primaryPages: [releasesData([newer, older])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(tag: "fw-packages-dev-009", revision: 9),
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015",
            installedAPI: "88.0",
            installedTarget: 7,
            requestedRevision: 8
        )

        XCTAssertEqual(selected.revision, 8)
    }

    func testUnavailablePrimaryFallsBackToImmutableLegacyCatalog() async throws {
        let legacy = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            legacyPages: [releasesData([legacy])],
            primaryError: GitHubAPIError.httpStatus(404),
            manifests: [
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015"
        )

        XCTAssertEqual(selected.release.repository, .legacy)
        XCTAssertEqual(selected.release.tag, "fw-packages-dev-008")
    }

    func testPrimaryWithoutRequestedChannelUsesLegacyDuringTransition() async throws {
        let primaryStable = release(id: 2, tag: "fw-packages-stable-002")
        let legacyDev = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            primaryPages: [releasesData([primaryStable])],
            legacyPages: [releasesData([legacyDev])],
            manifests: [
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015"
        )

        XCTAssertEqual(selected.release.repository, .legacy)
        XCTAssertEqual(selected.identity.catalogRevision, 8)
    }

    func testMalformedAuthoritativePrimaryDoesNotDowngradeToLegacy() async throws {
        let primary = release(id: 9, tag: "fw-packages-dev-009")
        let legacy = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            primaryPages: [releasesData([primary])],
            legacyPages: [releasesData([legacy])],
            manifests: [
                manifestURL("fw-packages-dev-009"): Data("{malformed".utf8),
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        do {
            _ = try await client.latest(
                for: .dev,
                installedVersion: "t-dev-004-015"
            )
            XCTFail("Expected authoritative catalog failure")
        } catch let error as TumoflipPackageCatalogError {
            guard case .malformedPrimary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWellFormedNewerIncompatibleRevisionFallsBackWithinPrimaryCatalog() async throws {
        let newer = release(id: 10, tag: "fw-packages-dev-010")
        let compatible = release(id: 9, tag: "fw-packages-dev-009")
        let client = makeClient(
            primaryPages: [releasesData([newer, compatible])],
            manifests: [
                manifestURL("fw-packages-dev-010"): manifest(
                    tag: "fw-packages-dev-010", revision: 10, api: "89.0"),
                manifestURL("fw-packages-dev-009"): manifest(
                    tag: "fw-packages-dev-009", revision: 9, api: "88.0"),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015",
            installedAPI: "88.0",
            installedTarget: 7
        )

        XCTAssertEqual(selected.release.repository, .primary)
        XCTAssertEqual(selected.release.tag, "fw-packages-dev-009")
    }

    func testCatalogMinorAPIDriftRemainsCompatible() async throws {
        let release = release(id: 9, tag: "fw-packages-dev-009")
        let client = makeClient(
            primaryPages: [releasesData([release])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(
                    tag: "fw-packages-dev-009", revision: 9, api: "88.0"),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-017",
            installedAPI: "88.2",
            installedTarget: 7
        )

        XCTAssertEqual(selected.release.tag, "fw-packages-dev-009")
    }

    func testFirmwareSnapshotRequiresExactCleanFirmwareIdentity() async throws {
        let tag = "fw-packages-stable-003"
        let commit = "8ab2ccdf7a34bbf3e07f2d4cbd459de1c6de8758"
        for explicitScope in [true, false] {
            let client = makeClient(
                primaryPages: [releasesData([release(id: 3, tag: tag)])],
                manifests: [
                    manifestURL(tag): manifest(
                        tag: tag,
                        revision: 3,
                        api: "88.0",
                        firmwareVersion: "t-flppr-fw-006",
                        snapshotCommit: commit,
                        snapshotExplicitScope: explicitScope
                    ),
                ]
            )

            let selected = try await client.latest(
                for: .stable,
                installedVersion: "t-flppr-fw-006",
                installedAPI: "88.0",
                installedTarget: 7,
                installedCommit: "8ab2ccdf",
                installedCommitDirty: false
            )

            XCTAssertEqual(selected.release.tag, tag)
            XCTAssertTrue(selected.manifest.isFirmwareSnapshotCatalog)
            XCTAssertEqual(selected.manifest.packageManagedManifest().packages["base"]?.count, 1)
        }
    }

    func testIndependentBaselineSelectsAcrossStableFirmwareVersions() async throws {
        let tag = "fw-packages-stable-004"
        let client = makeClient(
            primaryPages: [releasesData([release(id: 4, tag: tag)])],
            manifests: [
                manifestURL(tag): manifest(
                    tag: tag,
                    revision: 4,
                    api: "88.4",
                    firmwareVersion: "t-flppr-fw-007",
                    catalogInstallScope: "baseline"
                ),
            ]
        )

        let selected = try await client.latest(
            for: .stable,
            installedVersion: "t-flppr-fw-008",
            installedAPI: "88.4",
            installedTarget: 7
        )

        XCTAssertEqual(selected.release.tag, tag)
        XCTAssertTrue(selected.manifest.isIndependentBaselineCatalog)
        XCTAssertTrue(selected.manifest.packageManagedManifest().packages.values.allSatisfy(\.isEmpty))
    }

    func testFirmwareSnapshotRejectsWrongOrDirtyBuild() async throws {
        let tag = "fw-packages-stable-003"
        let commit = "8ab2ccdf7a34bbf3e07f2d4cbd459de1c6de8758"
        let client = makeClient(
            primaryPages: [releasesData([release(id: 3, tag: tag)])],
            manifests: [
                manifestURL(tag): manifest(
                    tag: tag,
                    revision: 3,
                    firmwareVersion: "t-flppr-fw-006",
                    snapshotCommit: commit
                ),
            ]
        )

        let identities: [(commit: String?, dirty: Bool?)] = [
            ("deadbeef", false),
            ("8ab2ccdf", true),
            (nil, false),
            ("8ab2ccdf", nil),
        ]
        for identity in identities {
            do {
                _ = try await client.latest(
                    for: .stable,
                    installedVersion: "t-flppr-fw-006",
                    installedAPI: "88.0",
                    installedTarget: 7,
                    installedCommit: identity.commit,
                    installedCommitDirty: identity.dirty
                )
                XCTFail("Snapshot must reject identity \(identity)")
            } catch let error as TumoflipPackageCatalogError {
                guard case .noMatchingRelease = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testFrozenLegacyStable003ContractSelectsAndInstallsOnlyOnExactBuild() async throws {
        let tag = "fw-packages-stable-003"
        let manifestData = try frozenLegacyStable003Manifest()
        let client = makeClient(
            primaryPages: [releasesData([release(id: 3, tag: tag)])],
            manifests: [manifestURL(tag): manifestData]
        )

        let selected = try await client.latest(
            for: .stable,
            installedVersion: "t-flppr-fw-006",
            installedAPI: "88.0",
            installedTarget: 7,
            installedCommit: "8ab2ccdf",
            installedCommitDirty: false
        )
        let managed = selected.manifest.packageManagedManifest()
        XCTAssertNil(selected.manifest.packageRelease?.catalogInstallScope)
        XCTAssertTrue(selected.manifest.isFirmwareSnapshotCatalog)
        XCTAssertEqual(managed.packages["base"]?.count, 23)
        XCTAssertEqual(managed.packages["arf"]?.count, 12)
        XCTAssertEqual(managed.packages["module_one"]?.count, 43)
        XCTAssertEqual(managed.packages["protocol_packs"]?.count, 31)
        XCTAssertEqual(managed.cleanup.count, 34)

        let plan = try TumoflipInstallPlan.make(
            manifest: managed,
            groups: Set(TumoflipManifest.knownGroups)
        )
        XCTAssertEqual(plan.files.count, 109)
        XCTAssertEqual(plan.cleanup.count, 34)
        XCTAssertNoThrow(try TumoflipCompat.check(
            deviceTarget: 7,
            deviceAPI: "88.0",
            deviceVersion: "t-flppr-fw-006",
            deviceOriginFork: "tumoflip",
            deviceCommit: "8ab2ccdf",
            deviceCommitDirty: false,
            manifest: managed
        ))

        let rejected: [(commit: String?, dirty: Bool?)] = [
            (nil, false),
            ("deadbeef", false),
            ("8ab2ccdf", true),
        ]
        for identity in rejected {
            do {
                _ = try await client.latest(
                    for: .stable,
                    installedVersion: "t-flppr-fw-006",
                    installedAPI: "88.0",
                    installedTarget: 7,
                    installedCommit: identity.commit,
                    installedCommitDirty: identity.dirty
                )
                XCTFail("Legacy Stable003 must reject identity \(identity)")
            } catch let error as TumoflipPackageCatalogError {
                guard case .noMatchingRelease = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertThrowsError(try TumoflipCompat.check(
                deviceTarget: 7,
                deviceAPI: "88.0",
                deviceVersion: "t-flppr-fw-006",
                deviceOriginFork: "tumoflip",
                deviceCommit: identity.commit,
                deviceCommitDirty: identity.dirty,
                manifest: managed
            ))
        }
    }

    func testMalformedInstalledAPIFailsClosed() async throws {
        let release = release(id: 9, tag: "fw-packages-dev-009")
        let client = makeClient(
            primaryPages: [releasesData([release])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(
                    tag: "fw-packages-dev-009", revision: 9, api: "88.0"),
            ]
        )

        do {
            _ = try await client.latest(
                for: .dev,
                installedVersion: "t-dev-004-017",
                installedAPI: "88.beta",
                installedTarget: 7
            )
            XCTFail("Malformed device API must not select a catalog")
        } catch let error as TumoflipPackageCatalogError {
            guard case .noMatchingRelease = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWellFormedCatalogWithoutCompatibleRevisionReportsNoMatch() async throws {
        let client = makeClient(
            primaryPages: [releasesData([release(id: 10, tag: "fw-packages-dev-010")])],
            manifests: [
                manifestURL("fw-packages-dev-010"): manifest(
                    tag: "fw-packages-dev-010", revision: 10, api: "89.0"),
            ]
        )

        do {
            _ = try await client.latest(
                for: .dev,
                installedVersion: "t-dev-004-015",
                installedAPI: "88.0",
                installedTarget: 7
            )
            XCTFail("Expected an ordinary compatibility miss")
        } catch let error as TumoflipPackageCatalogError {
            guard case .noMatchingRelease = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRateLimitedPrimaryDoesNotFallBackToLegacy() async throws {
        let legacy = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            legacyPages: [releasesData([legacy])],
            primaryError: GitHubAPIError.rateLimited(resetAt: nil),
            manifests: [
                manifestURL("fw-packages-dev-008"): manifest(
                    tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        do {
            _ = try await client.latest(for: .dev, installedVersion: "t-dev-004-015")
            XCTFail("Rate limiting must remain visible instead of selecting legacy data")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .rateLimited(resetAt: nil))
        }
    }

    func testMalformedLegacyCatalogHasDistinctFailure() async throws {
        let legacy = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            legacyPages: [releasesData([legacy])],
            primaryError: GitHubAPIError.httpStatus(404),
            manifests: [manifestURL("fw-packages-dev-008"): Data("bad".utf8)]
        )

        do {
            _ = try await client.latest(for: .dev, installedVersion: "t-dev-004-015")
            XCTFail("Expected malformed legacy catalog")
        } catch let error as TumoflipPackageCatalogError {
            guard case .malformedLegacy = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testReleaseDiscoveryPaginatesPastFirstHundredRows() async throws {
        let filler = (1...100).map {
            release(id: Int64(10_000 + $0), tag: "firmware-archive-\($0)", includeAssets: false)
        }
        let primary = release(id: 9, tag: "fw-packages-dev-009")
        let client = makeClient(
            primaryPages: [releasesData(filler), releasesData([primary])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(tag: "fw-packages-dev-009", revision: 9),
            ]
        )

        let selected = try await client.latest(
            for: .dev,
            installedVersion: "t-dev-004-015"
        )

        XCTAssertEqual(selected.release.githubID, 9)
        XCTAssertEqual(selected.release.repository, .primary)
    }

    func testRequiredRepositoryRecheckNeverFallsAcrossRepositories() async throws {
        let legacy = release(id: 8, tag: "fw-packages-dev-008")
        let client = makeClient(
            legacyPages: [releasesData([legacy])],
            primaryError: GitHubAPIError.transportFailure,
            manifests: [
                manifestURL("fw-packages-dev-008"): manifest(tag: "fw-packages-dev-008", revision: 8),
            ]
        )

        do {
            _ = try await client.latest(
                for: .dev,
                installedVersion: "t-dev-004-015",
                forceRemote: true,
                requiredRepository: .primary
            )
            XCTFail("Exact recheck must not switch repositories")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .transportFailure)
        }
    }

    func testSelectionIdentityIncludesGitHubReleaseAndManifestProvenance() async throws {
        let initialClient = makeClient(
            primaryPages: [releasesData([release(id: 9, tag: "fw-packages-dev-009")])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(
                    tag: "fw-packages-dev-009",
                    revision: 9,
                    releaseID: String(repeating: "a", count: 64)
                ),
            ]
        )
        let replacedClient = makeClient(
            primaryPages: [releasesData([release(id: 10, tag: "fw-packages-dev-009")])],
            manifests: [
                manifestURL("fw-packages-dev-009"): manifest(
                    tag: "fw-packages-dev-009",
                    revision: 9,
                    releaseID: String(repeating: "b", count: 64)
                ),
            ]
        )

        let initial = try await initialClient.latest(for: .dev, installedVersion: "t-dev-004-015")
        let replaced = try await replacedClient.latest(for: .dev, installedVersion: "t-dev-004-015")

        XCTAssertNotEqual(initial.identity, replaced.identity)
    }

    private func makeClient(
        primaryPages: [Data] = [Data("[]".utf8)],
        legacyPages: [Data] = [Data("[]".utf8)],
        primaryError: Error? = nil,
        manifests: [URL: Data],
        catalogIndex: Data? = nil
    ) -> TumoflipPackageCatalogClient {
        TumoflipPackageCatalogClient(
            apiFetch: { repository, page, _ in
                if repository == .primary, let primaryError { throw primaryError }
                let pages = repository == .primary ? primaryPages : legacyPages
                return page <= pages.count ? pages[page - 1] : Data("[]".utf8)
            },
            assetFetch: { url, _ in
                guard let data = manifests[url] else { throw URLError(.fileDoesNotExist) }
                return data
            },
            indexFetch: catalogIndex.map { data in { _ in data } }
        )
    }

    private func catalogIndex(
        channel: String,
        tag: String,
        revision: Int,
        manifestReleaseID: String,
        manifestSHA256: String
    ) -> Data {
        func release(
            channel: String,
            tag: String,
            revision: Int,
            releaseID: String,
            manifestSHA256: String
        ) -> [String: Any] {
            [
                "revision": revision,
                "tag": tag,
                "repository": "squazaryu/tumoflip-fw-packages",
                "release_id": releaseID,
                "manifest_sha256": manifestSHA256,
                "archive_sha256": String(repeating: "b", count: 64),
                "state": "active",
                "compatibility": ["targets": [7], "api_majors": [88]],
            ]
        }
        let stable = channel == "stable"
            ? release(
                channel: "stable",
                tag: tag,
                revision: revision,
                releaseID: manifestReleaseID,
                manifestSHA256: manifestSHA256
            )
            : release(
                channel: "stable",
                tag: "fw-packages-stable-001",
                revision: 1,
                releaseID: String(repeating: "c", count: 64),
                manifestSHA256: String(repeating: "d", count: 64)
            )
        let dev = channel == "dev"
            ? release(
                channel: "dev",
                tag: tag,
                revision: revision,
                releaseID: manifestReleaseID,
                manifestSHA256: manifestSHA256
            )
            : release(
                channel: "dev",
                tag: "fw-packages-dev-001",
                revision: 1,
                releaseID: String(repeating: "e", count: 64),
                manifestSHA256: String(repeating: "f", count: 64)
            )
        let object: [String: Any] = [
            "schema": 1,
            "repository": "squazaryu/tumoflip-fw-packages",
            "generated_at": "2026-08-24T20:00:00Z",
            "selection_policy": [
                "auto": "highest compatible active revision",
                "manual": "any compatible active or legacy revision",
                "withdrawal": "immutable release retained; index state becomes withdrawn",
            ],
            "channels": [
                "stable": ["current_revision": stable["revision"]!, "releases": [stable]],
                "dev": ["current_revision": dev["revision"]!, "releases": [dev]],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func release(
        id: Int64,
        tag: String,
        includeAssets: Bool = true
    ) -> [String: Any] {
        let assets: [[String: Any]] = includeAssets ? [
            [
                "name": "tumoflip-packages.json",
                "browser_download_url": manifestURL(tag).absoluteString,
                "updated_at": "2026-08-13T10:00:00Z",
            ],
            [
                "name": "tumoflip-packages.zip",
                "browser_download_url": "https://example.test/\(tag)/tumoflip-packages.zip",
                "updated_at": "2026-08-13T10:00:00Z",
            ],
        ] : []
        return [
            "id": id,
            "tag_name": tag,
            "body": "",
            "draft": false,
            "assets": assets,
        ]
    }

    private func releasesData(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases, options: [.sortedKeys])
    }

    private func manifestURL(_ tag: String) -> URL {
        URL(string: "https://example.test/\(tag)/tumoflip-packages.json")!
    }

    /// Freeze Stable003's public identity and aggregate surface without checking a
    /// 1000-line release manifest into the app repository. The fixture values are the
    /// immutable release metadata; deterministic entries exercise the same decoder,
    /// catalog selector and install-plan contract at the exact published cardinality.
    private func frozenLegacyStable003Manifest() throws -> Data {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/fw-packages-stable-003-contract.json")
        let fixtureData = try Data(contentsOf: fixtureURL)
        guard var object = try JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let expectations = object.removeValue(forKey: "fixture_expectations")
                as? [String: Any],
              let packageCounts = expectations["package_counts"] as? [String: Int],
              let cleanupCount = expectations["cleanup_count"] as? Int else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var packages: [String: [[String: Any]]] = [:]
        var targets: [String] = []
        for group in TumoflipManifest.knownGroups {
            guard let count = packageCounts[group] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let entries = (0..<count).map { index -> [String: Any] in
                let source = "apps/\(group)/snapshot-\(index).fap"
                let target = "/ext/apps/\(group)/snapshot-\(index).fap"
                targets.append(target)
                return [
                    "bytes": 1,
                    "sha256": String(repeating: "a", count: 64),
                    "md5": String(repeating: "b", count: 32),
                    "source": source,
                    "target": target,
                ]
            }
            packages[group] = entries
        }
        guard cleanupCount <= targets.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["schema"] = 2
        object["artifacts"] = [String: Any]()
        object["packages"] = packages
        object["cleanup"] = targets.prefix(cleanupCount).enumerated().map { index, target in
            [
                "canonical": target,
                "legacy": "/ext/apps/legacy/stable003-\(index).fap",
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func manifest(
        tag: String,
        revision: Int,
        releaseID: String = String(repeating: "d", count: 64),
        api: String = "88.0",
        firmwareVersion explicitFirmwareVersion: String? = nil,
        snapshotCommit: String? = nil,
        snapshotExplicitScope: Bool = true,
        catalogInstallScope: String? = nil
    ) -> Data {
        let channel = tag.contains("-stable-") ? "stable" : "dev"
        let firmwareVersion = explicitFirmwareVersion ??
            (channel == "stable" ? "t-flppr-fw-004" : "t-dev-004-015")
        var packageRelease: [String: Any] = [
            "id": tag,
            "type": "package-only",
            "source_commit": snapshotCommit ?? String(repeating: "c", count: 40),
            "source_dirty": false,
            "source_firmware_version": firmwareVersion,
            "target_release_tag": channel == "stable" ? "v1.0.4" : "t-dev-004-015",
            "firmware_flash_unchanged": true,
            "catalog_channel": channel,
            "catalog_revision": revision,
            "catalog_release_tag": tag,
        ]
        if let snapshotCommit {
            if snapshotExplicitScope {
                packageRelease["catalog_install_scope"] = "firmwareSnapshot"
            }
            packageRelease["overlay_targets"] = []
            packageRelease["compatible_releases"] = []
            packageRelease["target_firmware_commit"] = snapshotCommit
            packageRelease["target_source_commit"] = snapshotCommit
            packageRelease["target_release_id"] = String(repeating: "e", count: 64)
        }
        if let catalogInstallScope {
            packageRelease["catalog_install_scope"] = catalogInstallScope
            if catalogInstallScope == "baseline" {
                packageRelease["catalog_modified_targets"] = []
                packageRelease["overlay_targets"] = []
                packageRelease["compatible_releases"] = []
            }
        }
        let object: [String: Any] = [
            "schema": 2,
            "release_id": releaseID,
            "firmware": [
                "api": api,
                "name": "tumoflip",
                "version": firmwareVersion,
                "target": 7,
            ],
            "artifacts": [:],
            "packages": [
                "base": snapshotCommit == nil ? [] : [[
                    "bytes": 1,
                    "sha256": String(repeating: "a", count: 64),
                    "md5": String(repeating: "a", count: 32),
                    "source": "apps/fixture.fap",
                    "target": "/ext/apps/fixture.fap",
                ]],
                "arf": [],
                "module_one": [],
                "protocol_packs": [],
            ],
            "cleanup": [],
            "package_release": packageRelease,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
