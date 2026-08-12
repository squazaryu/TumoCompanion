import XCTest
@testable import UnleashedCompanion

final class ProtectedPluginAuditTests: XCTestCase {
    private let baseSHA = String(repeating: "1", count: 64)
    private let extraSHA = String(repeating: "2", count: 64)

    private actor MutableLedger {
        private var data: Data
        private var regularReads = 0
        private var freshReads = 0

        init(_ data: Data) {
            self.data = data
        }

        func read(fresh: Bool) -> Data {
            if fresh { freshReads += 1 } else { regularReads += 1 }
            return data
        }
        func replace(with data: Data) { self.data = data }
        func counts() -> (regular: Int, fresh: Int) { (regularReads, freshReads) }
    }

    private actor DeferredFirstLedger {
        private let laterData: Data
        private var calls = 0
        private var firstContinuation: CheckedContinuation<Data, Never>?
        private var firstIsWaiting = false

        init(laterData: Data) { self.laterData = laterData }

        func read() async -> Data {
            calls += 1
            guard calls == 1 else { return laterData }
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
                firstIsWaiting = true
            }
        }

        func waitUntilFirstIsWaiting() async {
            while !firstIsWaiting { await Task.yield() }
        }

        func resumeFirst(with data: Data) {
            firstContinuation?.resume(returning: data)
            firstContinuation = nil
        }
    }

    func testBundledBootstrapLedgerContainsExact9AugustAudit() throws {
        let url = try XCTUnwrap(Bundle.main.url(
            forResource: "ProtectedPluginAuditLedger", withExtension: "json"))
        let document = try ProtectedPluginAuditValidator.decode(Data(contentsOf: url))
        let audit = try XCTUnwrap(document.audits.first { $0.sourceTag == "9aug2026" })

        XCTAssertEqual(audit.entries.count, 9)
        XCTAssertEqual(audit.sourceCommit, "0b71d9f34fec8ae3ba763b8de27ef15d1d604c5b")
        XCTAssertTrue(audit.auditIssue.hasSuffix("/302"))
        XCTAssertEqual(
            audit.entries.filter { $0.remotePath.hasPrefix("/ext/apps_data/totp/") }.count,
            0,
            "TOTP FALs remain fail-closed until a published package manifest attests their targets")
        XCTAssertEqual(
            audit.entries.first { $0.remotePath.hasSuffix("claude_remote_ble.fap") }?.disposition,
            .intentionallyReplaced)
        XCTAssertNil(
            audit.entries.first { $0.remotePath.hasSuffix("subghz_raw_edit.fap") },
            "RAW Edit remains unresolved until FW Packages publication, device acceptance, and #281 closure")
        XCTAssertEqual(
            audit.entries.first { $0.remotePath.hasSuffix("subghz_wardriving.fap") }?.targetPath,
            "/ext/apps/Sub-GHz/subghz_wardriving.fap")
        for entry in audit.entries where entry.disposition != .intentionallyReplaced {
            XCTAssertFalse(entry.targetMD5s.isEmpty)
            XCTAssertEqual(Set(entry.targetMD5s), Set(entry.targetProvenance.map(\.targetMD5)))
        }
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
            schema: ProtectedPluginAuditDocument.supportedSchema,
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

        let offline = ProtectedPluginAuditService(
            url: service.url,
            cache: cache,
            fetch: { _ in throw URLError(.notConnectedToInternet) },
            bundledData: { try? self.makeDocumentData() })
        let stillRevoked = await offline.resolve(for: provenance)
        XCTAssertNil(stillRevoked.audit)
        XCTAssertNil(stillRevoked.origin)
        XCTAssertNotNil(stillRevoked.failure)
        XCTAssertTrue(cache.isRevoked(for: provenance))

        let reaccepted = ProtectedPluginAuditService(
            url: service.url,
            cache: cache,
            fetch: { _ in try self.makeDocumentData() },
            bundledData: { nil })
        let refreshed = await reaccepted.resolve(for: provenance)
        XCTAssertEqual(refreshed.origin, .remote)
        XCTAssertFalse(cache.isRevoked(for: provenance))
        let cachedAgain = await offline.resolve(for: provenance)
        XCTAssertEqual(cachedAgain.origin, .cache)
    }

    @MainActor
    func testDeviceVerificationRefreshReacceptsAuditPublishedAfterPackCheck() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenance = try XCTUnwrap(makeProvenance())
        let noAudits = ProtectedPluginAuditDocument(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            generatedAt: "2026-08-12T01:00:00Z",
            audits: [])
        let remote = MutableLedger(try JSONEncoder().encode(noAudits))
        let cache = ProtectedPluginAuditCache(directory: directory)
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: cache,
            fetch: { _ in await remote.read(fresh: false) },
            fetchFresh: { _ in await remote.read(fresh: true) },
            bundledData: { nil })
        let updater = PluginUpdater(protectedAuditService: service)
        updater.configureProtectedAuditProvenanceForTesting(provenance)

        // The pack was checked before automation published its exact audit. This
        // creates the fail-closed revocation tombstone seen by the user as DIFF.
        await updater.refreshProtectedAuditResolutionForTesting()
        XCTAssertNil(updater.protectedAuditResolution?.audit)
        XCTAssertTrue(cache.isRevoked(for: provenance))
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                makeReview(),
                compatibility: .compatible(
                    FapMetadata(apiMajor: 88, apiMinor: 2, hardwareTarget: 7)),
                audit: updater.protectedAuditResolution?.audit),
            .needsReview)

        // Verify on device reuses the retained exact pack provenance. Once the
        // authoritative ledger contains that identity, it clears the tombstone and
        // the already-known exact target bytes become VERIFIED without re-downloading.
        await remote.replace(with: try makeDocumentData())
        await updater.refreshProtectedAuditResolutionForTesting(forceRemote: true)

        XCTAssertEqual(updater.protectedAuditResolution?.origin, .remote)
        XCTAssertFalse(cache.isRevoked(for: provenance))
        let counts = await remote.counts()
        XCTAssertEqual(counts.regular, 1)
        XCTAssertEqual(counts.fresh, 1, "Verify must bypass the ordinary ledger fetch path")
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                makeReview(),
                compatibility: .compatible(
                    FapMetadata(apiMajor: 88, apiMinor: 2, hardwareTarget: 7)),
                audit: updater.protectedAuditResolution?.audit),
            .verified)
    }

    @MainActor
    func testLateAuditResponseCannotOverwriteNewerCatalogResolution() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstProvenance = try XCTUnwrap(makeProvenance())
        let nextBase = String(repeating: "3", count: 64)
        let nextExtra = String(repeating: "4", count: 64)
        let nextProvenance = try XCTUnwrap(ProtectedPluginPackProvenance(
            sourceTag: "12aug2026",
            archiveSHA256: ["base": nextBase, "extra": nextExtra]))
        let firstData = try makeDocumentData()
        let nextData = try makeDocumentData(
            sourceTag: "12aug2026", baseArchiveSHA: nextBase, extraArchiveSHA: nextExtra)
        let remote = DeferredFirstLedger(laterData: nextData)
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: ProtectedPluginAuditCache(directory: directory),
            fetch: { _ in await remote.read() },
            bundledData: { nil })
        let updater = PluginUpdater(protectedAuditService: service)
        updater.configureProtectedAuditProvenanceForTesting(firstProvenance)

        let staleRequest = Task { @MainActor in
            await updater.refreshProtectedAuditResolutionForTesting()
        }
        await remote.waitUntilFirstIsWaiting()

        updater.configureProtectedAuditProvenanceForTesting(nextProvenance)
        await updater.refreshProtectedAuditResolutionForTesting()
        XCTAssertEqual(updater.protectedAuditResolution?.audit?.sourceTag, "12aug2026")

        await remote.resumeFirst(with: firstData)
        await staleRequest.value
        XCTAssertEqual(
            updater.protectedAuditResolution?.audit?.sourceTag,
            "12aug2026",
            "An older async response must not replace the exact audit for the current catalog")
    }

    @MainActor
    func testLateOmissionCannotOverwriteNewerExactResolutionForSamePack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provenance = try XCTUnwrap(makeProvenance())
        let noAudits = ProtectedPluginAuditDocument(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            generatedAt: "2026-08-12T01:00:00Z",
            audits: [])
        let remote = DeferredFirstLedger(laterData: try makeDocumentData())
        let service = ProtectedPluginAuditService(
            url: URL(string: "https://example.test/latest.json")!,
            cache: ProtectedPluginAuditCache(directory: directory),
            fetch: { _ in await remote.read() },
            fetchFresh: { _ in await remote.read() },
            bundledData: { nil })
        let updater = PluginUpdater(protectedAuditService: service)
        updater.configureProtectedAuditProvenanceForTesting(provenance)

        let staleOmission = Task { @MainActor in
            await updater.refreshProtectedAuditResolutionForTesting()
        }
        await remote.waitUntilFirstIsWaiting()

        await updater.refreshProtectedAuditResolutionForTesting(forceRemote: true)
        XCTAssertEqual(updater.protectedAuditResolution?.origin, .remote)

        await remote.resumeFirst(with: try JSONEncoder().encode(noAudits))
        await staleOmission.value
        XCTAssertFalse(
            service.cache.isRevoked(for: provenance),
            "A cancelled stale omission must not revoke the newer exact audit cache")
        XCTAssertEqual(
            updater.protectedAuditResolution?.origin,
            .remote,
            "An older omission for the same pack must not replace a newer exact audit")
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

    func testSameTagWithCorrectedArchiveIsASeparateAuditIdentity() throws {
        let original = try XCTUnwrap(
            ProtectedPluginAuditValidator.decode(makeDocumentData()).audits.first)
        let corrected = ProtectedPluginAudit(
            sourceTag: original.sourceTag,
            sourceCommit: original.sourceCommit,
            auditIssue: original.auditIssue,
            archives: [
                ProtectedPluginAuditArchive(
                    pack: "base", fileName: "all-the-apps-base.zip",
                    sha256: String(repeating: "f", count: 64)),
                ProtectedPluginAuditArchive(
                    pack: "extra", fileName: "all-the-apps-extra.zip", sha256: extraSHA),
            ],
            entries: original.entries)
        let valid = ProtectedPluginAuditDocument(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            generatedAt: "2026-08-12T00:00:00Z",
            audits: [original, corrected])

        XCTAssertNoThrow(try ProtectedPluginAuditValidator.validate(valid))

        let duplicate = ProtectedPluginAuditDocument(
            schema: valid.schema,
            sourceRepository: valid.sourceRepository,
            generatedAt: valid.generatedAt,
            audits: [original, original])
        XCTAssertThrowsError(try ProtectedPluginAuditValidator.validate(duplicate))
    }

    func testTargetProvenanceAllowsSameBytesAcrossDistinctReleases() throws {
        let target = String(repeating: "a", count: 32)
        let entry = ProtectedPluginAuditEntry(
            remotePath: "/ext/apps/GPIO/esp_flasher.fap",
            targetPath: "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
            sourceMD5: String(repeating: "1", count: 32),
            targetMD5s: [target],
            targetProvenance: [
                ProtectedPluginTargetProvenance(
                    targetMD5: target, channel: .stable,
                    releaseTag: "fw-packages-stable-001",
                    manifestSHA256: String(repeating: "c", count: 64)),
                ProtectedPluginTargetProvenance(
                    targetMD5: target, channel: .dev,
                    releaseTag: "fw-packages-dev-003",
                    manifestSHA256: String(repeating: "d", count: 64)),
            ],
            disposition: .auditedDifference,
            note: nil)
        let audit = try XCTUnwrap(
            ProtectedPluginAuditValidator.decode(makeDocumentData()).audits.first)
        let document = ProtectedPluginAuditDocument(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            generatedAt: "2026-08-12T00:00:00Z",
            audits: [ProtectedPluginAudit(
                sourceTag: audit.sourceTag,
                sourceCommit: audit.sourceCommit,
                auditIssue: audit.auditIssue,
                archives: audit.archives,
                entries: [entry])])

        XCTAssertNoThrow(try ProtectedPluginAuditValidator.validate(document))

        let duplicateProvenanceEntry = ProtectedPluginAuditEntry(
            remotePath: entry.remotePath,
            targetPath: entry.targetPath,
            sourceMD5: entry.sourceMD5,
            targetMD5s: entry.targetMD5s,
            targetProvenance: [entry.targetProvenance[0], entry.targetProvenance[0]],
            disposition: entry.disposition,
            note: entry.note)
        let invalid = ProtectedPluginAuditDocument(
            schema: document.schema,
            sourceRepository: document.sourceRepository,
            generatedAt: document.generatedAt,
            audits: [ProtectedPluginAudit(
                sourceTag: audit.sourceTag,
                sourceCommit: audit.sourceCommit,
                auditIssue: audit.auditIssue,
                archives: audit.archives,
                entries: [duplicateProvenanceEntry])])
        XCTAssertThrowsError(try ProtectedPluginAuditValidator.validate(invalid))
    }

    func testTargetProvenanceRejectsUnattestedOrWildcardTargets() throws {
        let audit = try XCTUnwrap(
            ProtectedPluginAuditValidator.decode(makeDocumentData()).audits.first)
        let original = try XCTUnwrap(audit.entries.first)
        let unattested = ProtectedPluginAuditEntry(
            remotePath: original.remotePath,
            targetPath: original.targetPath,
            sourceMD5: original.sourceMD5,
            targetMD5s: original.targetMD5s + [String(repeating: "b", count: 32)],
            targetProvenance: original.targetProvenance,
            disposition: original.disposition,
            note: original.note)
        let wildcard = ProtectedPluginAuditEntry(
            remotePath: original.remotePath,
            targetPath: original.targetPath,
            sourceMD5: original.sourceMD5,
            targetMD5s: original.targetMD5s,
            targetProvenance: [ProtectedPluginTargetProvenance(
                targetMD5: original.targetMD5s[0], channel: .dev,
                releaseTag: "latest",
                manifestSHA256: String(repeating: "c", count: 64))],
            disposition: original.disposition,
            note: original.note)

        for entry in [unattested, wildcard] {
            let document = ProtectedPluginAuditDocument(
                schema: ProtectedPluginAuditDocument.supportedSchema,
                sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
                generatedAt: "2026-08-12T00:00:00Z",
                audits: [ProtectedPluginAudit(
                    sourceTag: audit.sourceTag,
                    sourceCommit: audit.sourceCommit,
                    auditIssue: audit.auditIssue,
                    archives: audit.archives,
                    entries: [entry])])
            XCTAssertThrowsError(try ProtectedPluginAuditValidator.validate(document))
        }
    }

    func testPolicyRequiresExactAuditedTargetsAndIntentionalMissingReplacement() throws {
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
                makeReview(deviceMD5: String(repeating: "b", count: 32)),
                compatibility: compatible,
                audit: audit),
            .needsReview,
            "Any present but unattested target hash must remain a DIFF")
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

        let sourceBytesWithoutAudit = makeReview(
            deviceMD5: String(repeating: "1", count: 32))
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                sourceBytesWithoutAudit, compatibility: compatible, audit: nil),
            .needsReview,
            "A new pack must complete its canonical audit even when installed bytes match upstream")

        let sourceEntry = ProtectedPluginAuditEntry(
            remotePath: sourceBytesWithoutAudit.remotePath,
            targetPath: sourceBytesWithoutAudit.targetPath,
            sourceMD5: sourceBytesWithoutAudit.newMD5,
            targetMD5s: [sourceBytesWithoutAudit.newMD5],
            targetProvenance: [ProtectedPluginTargetProvenance(
                targetMD5: sourceBytesWithoutAudit.newMD5,
                channel: .dev,
                releaseTag: "fw-packages-dev-004",
                manifestSHA256: String(repeating: "e", count: 64))],
            disposition: .sourceMatches,
            note: nil)
        let sourceAudit = ProtectedPluginAudit(
            sourceTag: audit.sourceTag,
            sourceCommit: audit.sourceCommit,
            auditIssue: audit.auditIssue,
            archives: audit.archives,
            entries: [sourceEntry])
        XCTAssertEqual(
            ProtectedPluginReviewPolicy.status(
                sourceBytesWithoutAudit, compatibility: compatible, audit: sourceAudit),
            .sourceMatches)
    }

    private func makeProvenance() -> ProtectedPluginPackProvenance? {
        ProtectedPluginPackProvenance(
            sourceTag: "9aug2026",
            archiveSHA256: ["base": baseSHA, "extra": extraSHA])
    }

    private func makeDocumentData(
        sourceTag: String = "9aug2026",
        baseArchiveSHA: String? = nil,
        extraArchiveSHA: String? = nil
    ) throws -> Data {
        let documentBaseSHA = baseArchiveSHA ?? baseSHA
        let documentExtraSHA = extraArchiveSHA ?? extraSHA
        let document = ProtectedPluginAuditDocument(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: "xMasterX/all-the-plugins",
            generatedAt: "2026-08-12T00:00:00Z",
            audits: [ProtectedPluginAudit(
                sourceTag: sourceTag,
                sourceCommit: String(repeating: "a", count: 40),
                auditIssue: "https://github.com/squazaryu/tumoflip/issues/302",
                archives: [
                    ProtectedPluginAuditArchive(
                        pack: "base", fileName: "all-the-apps-base.zip", sha256: documentBaseSHA),
                    ProtectedPluginAuditArchive(
                        pack: "extra", fileName: "all-the-apps-extra.zip", sha256: documentExtraSHA),
                ],
                entries: [
                    ProtectedPluginAuditEntry(
                        remotePath: "/ext/apps/GPIO/esp_flasher.fap",
                        targetPath: "/ext/apps/Module One/ESP32 Wi-Fi/esp_flasher.fap",
                        sourceMD5: String(repeating: "1", count: 32),
                        targetMD5s: [String(repeating: "a", count: 32)],
                        targetProvenance: [ProtectedPluginTargetProvenance(
                            targetMD5: String(repeating: "a", count: 32),
                            channel: .dev,
                            releaseTag: "fw-packages-dev-003",
                            manifestSHA256: String(repeating: "c", count: 64))],
                        disposition: .auditedDifference,
                        note: nil),
                    ProtectedPluginAuditEntry(
                        remotePath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                        targetPath: "/ext/apps/Bluetooth/claude_remote_ble.fap",
                        sourceMD5: String(repeating: "4", count: 32),
                        targetMD5s: [],
                        targetProvenance: [],
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
