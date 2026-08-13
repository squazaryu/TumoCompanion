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
        manifests: [URL: Data]
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
            }
        )
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

    private func manifest(
        tag: String,
        revision: Int,
        releaseID: String = String(repeating: "d", count: 64),
        api: String = "88.0"
    ) -> Data {
        let channel = tag.contains("-stable-") ? "stable" : "dev"
        let firmwareVersion = channel == "stable" ? "t-flppr-fw-004" : "t-dev-004-015"
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
                "base": [],
                "arf": [],
                "module_one": [],
                "protocol_packs": [],
            ],
            "cleanup": [],
            "package_release": [
                "id": tag,
                "type": "package-only",
                "source_commit": String(repeating: "c", count: 40),
                "source_dirty": false,
                "source_firmware_version": firmwareVersion,
                "target_release_tag": channel == "stable" ? "v1.0.4" : "t-dev-004-015",
                "firmware_flash_unchanged": true,
                "catalog_channel": channel,
                "catalog_revision": revision,
                "catalog_release_tag": tag,
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
