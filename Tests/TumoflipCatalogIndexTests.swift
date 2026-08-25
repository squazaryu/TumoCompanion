import XCTest
@testable import UnleashedCompanion

final class TumoflipCatalogIndexTests: XCTestCase {
    private func index(state: TumoflipCatalogIndex.Release.State = .active) -> TumoflipCatalogIndex {
        let release = TumoflipCatalogIndex.Release(
            revision: 4,
            tag: "fw-packages-stable-004",
            repository: "squazaryu/tumoflip-fw-packages",
            releaseId: String(repeating: "a", count: 64),
            manifestSHA256: String(repeating: "b", count: 64),
            archiveSHA256: String(repeating: "c", count: 64),
            state: state,
            compatibility: .init(targets: [7], apiMajors: [88])
        )
        return TumoflipCatalogIndex(
            schema: 1,
            repository: "squazaryu/tumoflip-fw-packages",
            generatedAt: "2026-08-24T00:00:00Z",
            selectionPolicy: .init(
                auto: "highest compatible active revision",
                manual: "any compatible active or legacy revision",
                withdrawal: "immutable release retained; index state becomes withdrawn"
            ),
            channels: [
                "stable": .init(currentRevision: 4, releases: [release]),
                "dev": .init(currentRevision: 4, releases: [
                    .init(
                        revision: 4,
                        tag: "fw-packages-dev-004",
                        repository: "squazaryu/tumoflip-fw-packages",
                        releaseId: String(repeating: "d", count: 64),
                        manifestSHA256: String(repeating: "e", count: 64),
                        archiveSHA256: String(repeating: "f", count: 64),
                        state: .active,
                        compatibility: .init(targets: [7], apiMajors: [88])
                    ),
                ]),
            ]
        )
    }

    func testCompatibleReleasesExcludeWithdrawn() throws {
        let index = index(state: .withdrawn)
        XCTAssertThrowsError(try index.validate())
    }

    func testValidIndexExposesCurrentRevision() throws {
        let index = index()
        XCTAssertNoThrow(try index.validate())
        XCTAssertEqual(index.releases(for: .stable, api: "88.4", target: 7).map(\.revision), [4])
    }

    func testDecodesPublishedSnakeCaseReleaseFields() throws {
        let json = """
        {
          "schema": 1,
          "repository": "squazaryu/tumoflip-fw-packages",
          "generated_at": "2026-08-25T00:00:00Z",
          "selection_policy": {
            "auto": "highest compatible active revision",
            "manual": "any compatible active or legacy revision",
            "withdrawal": "immutable release retained; index state becomes withdrawn"
          },
          "channels": {
            "stable": {
              "current_revision": 4,
              "releases": [
                {
                  "revision": 4,
                  "tag": "fw-packages-stable-004",
                  "repository": "squazaryu/tumoflip-fw-packages",
                  "release_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "manifest_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "archive_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                  "state": "active",
                  "compatibility": { "targets": [7], "api_majors": [88] }
                }
              ]
            },
            "dev": {
              "current_revision": 8,
              "releases": [
                {
                  "revision": 8,
                  "tag": "fw-packages-dev-008",
                  "repository": "squazaryu/tumoflip-fw-packages",
                  "release_id": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                  "manifest_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                  "archive_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                  "state": "active",
                  "compatibility": { "targets": [7], "api_majors": [88] }
                }
              ]
            }
          }
        }
        """

        let decoded = try JSONDecoder().decode(
            TumoflipCatalogIndex.self,
            from: Data(json.utf8)
        )

        XCTAssertNoThrow(try decoded.validate())
        XCTAssertEqual(
            decoded.channels["stable"]?.releases.first?.releaseId,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            decoded.channels["dev"]?.releases.first?.archiveSHA256,
            String(repeating: "f", count: 64)
        )
    }
}
