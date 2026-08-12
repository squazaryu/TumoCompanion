import XCTest
@testable import UnleashedCompanion

final class ProtectedPluginAuditTests: XCTestCase {
    private let baseSHA = String(repeating: "1", count: 64)
    private let extraSHA = String(repeating: "2", count: 64)

    func testBundledBootstrapLedgerContainsExact9AugustAudit() throws {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "ProtectedPluginAuditLedger", withExtension: "json"))
        let document = try ProtectedPluginAuditValidator.decode(Data(contentsOf: url))
        let audit = try XCTUnwrap(document.audits.first { $0.sourceTag == "9aug2026" })

        XCTAssertEqual(audit.entries.count, 24)
        XCTAssertEqual(audit.sourceCommit, "0b71d9f34fec8ae3ba763b8de27ef15d1d604c5b")
        XCTAssertTrue(audit.auditIssue.hasSuffix("/281"))
        XCTAssertEqual(
            audit.entries.filter { $0.remotePath.hasPrefix("/ext/apps_data/totp/") }.count,
            14)
        XCTAssertEqual(
            audit.entries.first { $0.remotePath.hasSuffix("claude_remote_ble.fap") }?.disposition,
            .intentionallyReplaced)
    }

    func testRemoteExactAuditIsCachedAndReusedOnlyForSamePack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProtectedPluginAuditCache(directory: directory)
        let provenance = try XCTUnwrap(makeProvenance())
        let data = try makeDocumentData()
        let remote = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: cache,
            fetch: { _ in data },
            bundledData: { nil })

        let first = await remote.resolve(for: provenance)
        XCTAssertEqual(first.origin, .remote)
        XCTAssertEqual(first.audit?.sourceTag, "9aug2026")

        let offline = ProtectedPluginAuditService(
            url: remote.url,
            cache: cache,
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            bundledData: { nil })
        let cached = await offline.resolve(for: provenance)
        XCTAssertEqual(cached.origin, .cache)

        let unseen = try XCTUnwrap(ProtectedPluginPackProvenance(
            sourceTag: "10aug2026",
            archiveSHA256: ["base": baseSHA, "extra": extraSHA]))
        let rejected = await offline.resolve(for: unseen)
        XCTAssertNil(rejected.audit)
        XCTAssertNotNil(rejected.failure)
    }

    func testMalformedAuthoritativeLedgerDoesNotFallBackToCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProtectedPluginAuditCache(directory: directory)
        let provenance = try XCTUnwrap(makeProvenance())
        let validDocument = try ProtectedPluginAuditValidator.decode(makeDocumentData())
        let audit = try XCTUnwrap(validDocument.audits.first)
        try cache.save(audit, for: provenance)

        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: cache,
            fetch: { _ in Data("{\"schema\":999}".utf8) },
            bundledData: { try? self.makeDocumentData() })
        let resolution = await service.resolve(for: provenance)

        XCTAssertNil(resolution.audit)
        XCTAssertNil(resolution.origin)
        XCTAssertNotNil(resolution.failure)
    }

    func testReachableValidLedgerWithoutExactPackRevokesCachedAcceptance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ProtectedPluginAuditCache(directory: directory)
        let provenance = try XCTUnwrap(makeProvenance())
        let validDocument = try ProtectedPluginAuditValidator.decode(makeDocumentData())
        try cache.save(try XCTUnwrap(validDocument.audits.first), for: provenance)

        let empty = ProtectedPluginAuditDocument(
            schema: 1,
            sourceRepository: "xMasterX/all-the-plugins",
            generatedAt: "2026-08-12T01:00:00Z",
            audits: [])
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: cache,
            fetch: { _ in try JSONEncoder().encode(empty) },
            bundledData: { try? self.makeDocumentData() })
        let resolution = await service.resolve(for: provenance)

        XCTAssertNil(resolution.audit)
        XCTAssertNil(resolution.origin)
        XCTAssertNotNil(resolution.failure)
    }

    func testOfflineBundledBootstrapRequiresExactPack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try makeDocumentData()
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: ProtectedPluginAuditCache(directory: directory),
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            bundledData: { data })

        let exact = await service.resolve(for: try XCTUnwrap(makeProvenance()))
        XCTAssertEqual(exact.origin, .bundled)

        let changed = try XCTUnwrap(ProtectedPluginPackProvenance(
            sourceTag: "9aug2026",
            archiveSHA256: [
                "base": String(repeating: "f", count: 64),
                "extra": extraSHA,
            ]))
        let rejected = await service.resolve(for: changed)
        XCTAssertNil(rejected.audit)
        XCTAssertNotNil(rejected.failure)
    }

    func testAuditRequiresExactArchiveHashesSourceBytesAndRoute() throws {
        let document = try ProtectedPluginAuditValidator.decode(makeDocumentData())
        let audit = try XCTUnwrap(document.audits.first)
        XCTAssertTrue(audit.matches(try XCTUnwrap(makeProvenance())))

        let changedArchive = try XCTUnwrap(ProtectedPluginPackProvenance(
            sourceTag: "9aug2026",
            archiveSHA256: ["base": String(repeating: "f", count: 64), "extra": extraSHA]))
        XCTAssertFalse(audit.matches(changedArchive))

        let accepted = makeReview()
        XCTAssertNotNil(audit.entry(matching: accepted))
        XCTAssertNil(audit.entry(matching: makeReview(
            targetPath: "/ext/apps/Module One/ESP32 Wi-Fi v2/esp_flasher.fap")))
        XCTAssertNil(audit.entry(matching: makeReview(
            sourceMD5: String(repeating: "3", count: 32))))
    }

    func testPolicyCoversOnlyAuditedDifferenceAndIntentionalMissingReplacement() throws {
        let audit = try XCTUnwrap(
            ProtectedPluginAuditValidator.decode(makeDocumentData()).audits.first)
        let compatible = FapCompatibilityState.compatible(
            FapMetadata(apiMajor: 88, apiMinor: 2, hardwareTarget: 7))

        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                makeReview(), compatibility: compatible, audit: audit),
            .verified)
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                makeReview(deviceMD5: nil), compatibility: compatible, audit: audit),
            .needsReview,
            "Ordinary audited differences must not hide a missing protected app")

        let replacement = ProtectedPluginReview(
            remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
            targetPath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
            name: "claude_remote_ble", category: "Bluetooth", pack: "extra",
            newMD5: String(repeating: "4", count: 32),
            deviceMD5: nil, deviceKnown: true, size: 1)
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                replacement, compatibility: compatible, audit: audit),
            .intentionallyReplaced)
        let unexpectedDuplicate = ProtectedPluginReview(
            remotePath: replacement.remotePath,
            targetPath: replacement.targetPath,
            name: replacement.name,
            category: replacement.category,
            pack: replacement.pack,
            newMD5: replacement.newMD5,
            deviceMD5: replacement.newMD5,
            deviceKnown: true,
            size: replacement.size)
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                unexpectedDuplicate, compatibility: compatible, audit: audit),
            .needsReview,
            "An intentionally replaced app must not silently reappear as a duplicate")

        let unknown = makeReview(deviceKnown: false)
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                unknown, compatibility: compatible, audit: audit),
            .needsReview)
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                makeReview(),
                compatibility: .incompatible(reason: "wrong target"),
                audit: audit),
            .needsReview)
    }

    private func makeProvenance() -> ProtectedPluginPackProvenance? {
        ProtectedPluginPackProvenance(
            sourceTag: "9aug2026",
            archiveSHA256: ["base": baseSHA, "extra": extraSHA])
    }

    private func makeDocumentData() throws -> Data {
        let document = ProtectedPluginAuditDocument(
            schema: 1,
            sourceRepository: "xMasterX/all-the-plugins",
            generatedAt: "2026-08-12T00:00:00Z",
            audits: [ProtectedPluginAudit(
                sourceTag: "9aug2026",
                sourceCommit: String(repeating: "a", count: 40),
                auditIssue: "https://github.com/squazaryu/tumoflip/issues/281",
                archives: [
                    ProtectedPluginAuditArchive(
                        pack: "base", fileName: "all-the-apps-base.zip", sha256: baseSHA),
                    ProtectedPluginAuditArchive(
                        pack: "extra", fileName: "all-the-apps-extra.zip", sha256: extraSHA),
                ],
                entries: [
                    ProtectedPluginAuditEntry(
                        remotePath: "/ext/apps/GPIO/esp_flasher.fap",
                        targetPath: "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
                        sourceMD5: String(repeating: "1", count: 32),
                        disposition: .auditedDifference,
                        note: nil),
                    ProtectedPluginAuditEntry(
                        remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                        targetPath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                        sourceMD5: String(repeating: "4", count: 32),
                        disposition: .intentionallyReplaced,
                        note: nil),
                ])])
        return try JSONEncoder().encode(document)
    }

    private func makeReview(
        targetPath: String = "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
        sourceMD5: String = String(repeating: "1", count: 32),
        deviceMD5: String? = String(repeating: "a", count: 32),
        deviceKnown: Bool = true
    ) -> ProtectedPluginReview {
        ProtectedPluginReview(
            remotePath: "/ext/apps/GPIO/esp_flasher.fap",
            targetPath: targetPath,
            name: "esp_flasher", category: "GPIO", pack: "extra",
            newMD5: sourceMD5,
            deviceMD5: deviceMD5,
            deviceKnown: deviceKnown,
            size: 6_000_000)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectedPluginAuditTests-\(UUID().uuidString)")
    }
}
