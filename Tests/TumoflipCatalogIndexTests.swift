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
}
