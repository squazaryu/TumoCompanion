import CryptoKit
import Foundation

/// Exact identity of the two release archives whose protected binaries were audited.
/// A tag alone is not evidence: corrected releases can reuse a family name while their
/// payload changes, so both archive digests are part of the fail-closed key.
struct ProtectedPluginPackProvenance: Equatable {
    static let requiredPacks = Set(["base", "extra"])

    let sourceTag: String
    let archiveSHA256: [String: String]

    init?(sourceTag: String, archiveSHA256: [String: String]) {
        let normalized = archiveSHA256.reduce(into: [String: String]()) {
            $0[$1.key.lowercased()] = $1.value.lowercased()
        }
        guard !sourceTag.isEmpty,
              Set(normalized.keys) == Self.requiredPacks,
              normalized.values.allSatisfy(Self.isSHA256) else { return nil }
        self.sourceTag = sourceTag
        self.archiveSHA256 = normalized
    }

    fileprivate var cacheKey: String {
        let identity = [
            sourceTag,
            archiveSHA256["base"] ?? "",
            archiveSHA256["extra"] ?? "",
        ].joined(separator: "\u{001F}")
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

enum ProtectedPluginAuditDisposition: String, Codable, Equatable {
    /// The upstream source was audited and the different Tumoflip binary is expected.
    case auditedDifference
    /// The audited Tumoflip target intentionally uses the exact upstream bytes.
    /// This still requires an exact ledger record: local equality is not an audit.
    case sourceMatches
    /// This upstream app is intentionally absent because another Tumoflip app replaces it.
    case intentionallyReplaced
}

enum ProtectedPluginTargetChannel: String, Codable, Equatable {
    case stable
    case dev
}

struct ProtectedPluginTargetProvenance: Codable, Equatable {
    let targetMD5: String
    let channel: ProtectedPluginTargetChannel
    let releaseTag: String
    let manifestSHA256: String
}

struct ProtectedPluginAuditEntry: Codable, Equatable {
    let remotePath: String
    let targetPath: String
    let sourceMD5: String
    /// Exact hashes of reviewed Tumoflip binaries. A present target is accepted only
    /// when its on-device hash is a member of this set.
    let targetMD5s: [String]
    /// Immutable release evidence for every accepted target hash. The same bytes may
    /// be proven by multiple exact releases. Intentionally replaced targets use empty arrays.
    let targetProvenance: [ProtectedPluginTargetProvenance]
    let disposition: ProtectedPluginAuditDisposition
    let note: String?

    func matches(_ review: ProtectedPluginReview) -> Bool {
        remotePath == review.remotePath
            && targetPath == review.targetPath
            && sourceMD5.caseInsensitiveCompare(review.newMD5) == .orderedSame
    }
}

struct ProtectedPluginAuditArchive: Codable, Equatable {
    let pack: String
    let fileName: String
    let sha256: String
}

struct ProtectedPluginAudit: Codable, Equatable {
    let sourceTag: String
    let sourceCommit: String
    let auditIssue: String
    let archives: [ProtectedPluginAuditArchive]
    let entries: [ProtectedPluginAuditEntry]

    func entry(matching review: ProtectedPluginReview) -> ProtectedPluginAuditEntry? {
        entries.first { $0.matches(review) }
    }

    func matches(_ provenance: ProtectedPluginPackProvenance) -> Bool {
        guard sourceTag == provenance.sourceTag else { return false }
        let hashes = Dictionary(uniqueKeysWithValues: archives.map {
            ($0.pack.lowercased(), $0.sha256.lowercased())
        })
        return hashes == provenance.archiveSHA256
    }
}

struct ProtectedPluginAuditDocument: Codable, Equatable {
    static let supportedSchema = 2
    static let expectedRepository = "xMasterX/all-the-plugins"

    let schema: Int
    let sourceRepository: String
    let generatedAt: String
    let audits: [ProtectedPluginAudit]
}

enum ProtectedPluginAuditValidationError: LocalizedError, Equatable {
    case unsupportedSchema
    case wrongRepository
    case malformedAudit(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "Protected-app audit ledger uses an unsupported schema."
        case .wrongRepository: return "Protected-app audit ledger names an unexpected source repository."
        case .malformedAudit(let reason): return "Protected-app audit ledger is invalid: \(reason)"
        }
    }
}

enum ProtectedPluginAuditValidator {
    static func decode(_ data: Data) throws -> ProtectedPluginAuditDocument {
        let document = try JSONDecoder().decode(ProtectedPluginAuditDocument.self, from: data)
        try validate(document)
        return document
    }

    static func validate(_ document: ProtectedPluginAuditDocument) throws {
        guard document.schema == ProtectedPluginAuditDocument.supportedSchema else {
            throw ProtectedPluginAuditValidationError.unsupportedSchema
        }
        guard document.sourceRepository == ProtectedPluginAuditDocument.expectedRepository else {
            throw ProtectedPluginAuditValidationError.wrongRepository
        }

        var auditIdentities = Set<String>()
        for audit in document.audits {
            guard !audit.sourceTag.isEmpty else {
                throw ProtectedPluginAuditValidationError.malformedAudit("empty source tag")
            }
            guard audit.sourceCommit.count == 40,
                  audit.sourceCommit.allSatisfy(\.isHexDigit) else {
                throw ProtectedPluginAuditValidationError.malformedAudit("invalid source commit")
            }
            guard let issue = URL(string: audit.auditIssue),
                  issue.scheme == "https", issue.host == "github.com" else {
                throw ProtectedPluginAuditValidationError.malformedAudit("invalid audit issue")
            }

            let archivePacks = audit.archives.map { $0.pack.lowercased() }
            guard Set(archivePacks) == ProtectedPluginPackProvenance.requiredPacks,
                  archivePacks.count == ProtectedPluginPackProvenance.requiredPacks.count else {
                throw ProtectedPluginAuditValidationError.malformedAudit("base/extra archive set is incomplete")
            }
            for archive in audit.archives {
                guard archive.fileName == "all-the-apps-\(archive.pack.lowercased()).zip",
                      isLowercaseSHA256(archive.sha256) else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("invalid archive provenance")
                }
            }
            let archiveHashes = Dictionary(uniqueKeysWithValues: audit.archives.map {
                ($0.pack.lowercased(), $0.sha256)
            })
            let auditIdentity = [
                audit.sourceTag,
                archiveHashes["base"] ?? "",
                archiveHashes["extra"] ?? "",
            ].joined(separator: "\u{001F}")
            guard auditIdentities.insert(auditIdentity).inserted else {
                throw ProtectedPluginAuditValidationError.malformedAudit(
                    "duplicate exact pack audit")
            }

            var identities = Set<String>()
            for entry in audit.entries {
                guard entry.remotePath.hasPrefix("/ext/"), entry.targetPath.hasPrefix("/ext/"),
                      isLowercaseMD5(entry.sourceMD5) else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("invalid protected entry")
                }
                let identity = [entry.remotePath, entry.targetPath, entry.sourceMD5.lowercased()]
                    .joined(separator: "\u{001F}")
                guard identities.insert(identity).inserted else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("duplicate protected entry")
                }

                let targetSet = Set(entry.targetMD5s)
                let provenanceSet = Set(entry.targetProvenance.map(\.targetMD5))
                let provenanceIdentities = Set(entry.targetProvenance.map {
                    [
                        $0.targetMD5,
                        $0.channel.rawValue,
                        $0.releaseTag,
                        $0.manifestSHA256,
                    ].joined(separator: "\u{001F}")
                })
                guard targetSet.count == entry.targetMD5s.count,
                      entry.targetMD5s.allSatisfy(isLowercaseMD5),
                      provenanceIdentities.count == entry.targetProvenance.count,
                      targetSet == provenanceSet else {
                    throw ProtectedPluginAuditValidationError.malformedAudit(
                        "invalid target hash provenance")
                }
                for provenance in entry.targetProvenance {
                    guard isLowercaseMD5(provenance.targetMD5),
                          isReleaseTag(provenance.releaseTag),
                          isLowercaseSHA256(provenance.manifestSHA256) else {
                        throw ProtectedPluginAuditValidationError.malformedAudit(
                            "invalid target release provenance")
                    }
                }
                switch entry.disposition {
                case .auditedDifference:
                    guard !targetSet.isEmpty else {
                        throw ProtectedPluginAuditValidationError.malformedAudit(
                            "audited difference has no accepted target")
                    }
                case .sourceMatches:
                    guard !targetSet.isEmpty, targetSet.contains(entry.sourceMD5) else {
                        throw ProtectedPluginAuditValidationError.malformedAudit(
                            "source match does not accept the audited source hash")
                    }
                case .intentionallyReplaced:
                    guard targetSet.isEmpty, entry.targetProvenance.isEmpty else {
                        throw ProtectedPluginAuditValidationError.malformedAudit(
                            "intentionally replaced target must remain absent")
                    }
                }
            }
        }
    }

    private static func isLowercaseMD5(_ value: String) -> Bool {
        value == value.lowercased()
            && value.count == 32
            && value.allSatisfy(\.isHexDigit)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value == value.lowercased() && ProtectedPluginPackProvenance.isSHA256(value)
    }

    private static func isReleaseTag(_ value: String) -> Bool {
        !value.isEmpty
            && value.lowercased() != "latest"
            && !value.contains("*")
            && !value.contains(where: \.isWhitespace)
    }
}

enum ProtectedPluginAuditOrigin: String, Equatable {
    case remote
    case legacy
    case cache
    case bundled
}

enum ProtectedPluginAuditFailureKind: Equatable {
    case unavailable
    case invalid

    var label: String {
        switch self {
        case .unavailable: return "AUDIT UNAVAILABLE"
        case .invalid: return "AUDIT INVALID"
        }
    }
}

struct ProtectedPluginAuditResolution: Equatable {
    let audit: ProtectedPluginAudit?
    let origin: ProtectedPluginAuditOrigin?
    let failure: String?
    let failureKind: ProtectedPluginAuditFailureKind?

    static func accepted(_ audit: ProtectedPluginAudit, origin: ProtectedPluginAuditOrigin) -> Self {
        Self(audit: audit, origin: origin, failure: nil, failureKind: nil)
    }

    static func rejected(
        _ failure: String,
        kind: ProtectedPluginAuditFailureKind = .unavailable
    ) -> Self {
        Self(audit: nil, origin: nil, failure: failure, failureKind: kind)
    }
}

private struct ProtectedPluginAuditCacheEnvelope: Codable {
    let schema: Int
    let sourceRepository: String
    let audit: ProtectedPluginAudit
}

/// Identifies which network authority made a persisted negative decision.
/// A legacy fallback may bootstrap a device before the primary endpoint exists,
/// but it must never overturn a revocation already observed from the primary.
enum ProtectedPluginAuditAuthority: String, Codable, Hashable {
    case primary
    case legacy
}

private struct ProtectedPluginAuditRevocationEnvelope: Codable {
    static let supportedSchema = 1

    let schema: Int
    let authorities: [ProtectedPluginAuditAuthority]
}

struct ProtectedPluginAuditCache {
    let directory: URL

    private func auditURL(for provenance: ProtectedPluginPackProvenance) -> URL {
        directory.appendingPathComponent("\(provenance.cacheKey).json")
    }

    private func revocationURL(for provenance: ProtectedPluginPackProvenance) -> URL {
        directory.appendingPathComponent("\(provenance.cacheKey).revoked")
    }

    func isRevoked(for provenance: ProtectedPluginPackProvenance) -> Bool {
        !revocations(for: provenance).isEmpty
    }

    func isRevoked(
        for provenance: ProtectedPluginPackProvenance,
        by authority: ProtectedPluginAuditAuthority
    ) -> Bool {
        revocations(for: provenance).contains(authority)
    }

    func load(for provenance: ProtectedPluginPackProvenance) -> ProtectedPluginAudit? {
        // A valid authoritative ledger can revoke an earlier positive exact-pack
        // decision. Its tombstone takes precedence over both cache and bundle.
        guard !isRevoked(for: provenance) else { return nil }
        let url = auditURL(for: provenance)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(ProtectedPluginAuditCacheEnvelope.self, from: data) else {
            return nil
        }
        let document = ProtectedPluginAuditDocument(
            schema: envelope.schema,
            sourceRepository: envelope.sourceRepository,
            generatedAt: "cached",
            audits: [envelope.audit])
        guard (try? ProtectedPluginAuditValidator.validate(document)) != nil,
              envelope.audit.matches(provenance) else { return nil }
        return envelope.audit
    }

    func save(
        _ audit: ProtectedPluginAudit,
        for provenance: ProtectedPluginPackProvenance,
        authority: ProtectedPluginAuditAuthority = .primary
    ) throws {
        guard audit.matches(provenance) else { return }
        let envelope = ProtectedPluginAuditCacheEnvelope(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            audit: audit)
        let data = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try data.write(to: auditURL(for: provenance), options: .atomic)
        try clearRevocation(for: provenance, by: authority)
    }

    func revoke(
        _ provenance: ProtectedPluginPackProvenance,
        authority: ProtectedPluginAuditAuthority = .primary
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var authorities = revocations(for: provenance)
        authorities.insert(authority)
        // Write the negative decision first. If cleanup fails, the tombstone still
        // wins and stale positive bytes cannot be resurrected offline.
        try writeRevocations(authorities, for: provenance)
        try? FileManager.default.removeItem(at: auditURL(for: provenance))
    }

    private func revocations(
        for provenance: ProtectedPluginPackProvenance
    ) -> Set<ProtectedPluginAuditAuthority> {
        let url = revocationURL(for: provenance)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let envelope = try? JSONDecoder().decode(
            ProtectedPluginAuditRevocationEnvelope.self,
            from: data),
              envelope.schema == ProtectedPluginAuditRevocationEnvelope.supportedSchema,
              !envelope.authorities.isEmpty else {
            // Earlier migration builds wrote the literal "revoked". Treat any
            // unrecognised existing marker as a primary decision so an upgrade
            // remains fail closed instead of letting legacy data resurrect it.
            return [.primary]
        }
        return Set(envelope.authorities)
    }

    private func clearRevocation(
        for provenance: ProtectedPluginPackProvenance,
        by authority: ProtectedPluginAuditAuthority
    ) throws {
        var authorities = revocations(for: provenance)
        switch authority {
        case .primary:
            // Only a reachable, valid exact primary audit can clear a primary
            // tombstone. It also supersedes any older legacy decision.
            authorities.removeAll()
        case .legacy:
            // A valid fallback may supersede only an earlier legacy decision.
            authorities.remove(.legacy)
        }
        try writeRevocations(authorities, for: provenance)
    }

    private func writeRevocations(
        _ authorities: Set<ProtectedPluginAuditAuthority>,
        for provenance: ProtectedPluginPackProvenance
    ) throws {
        let url = revocationURL(for: provenance)
        guard !authorities.isEmpty else {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
            return
        }
        let envelope = ProtectedPluginAuditRevocationEnvelope(
            schema: ProtectedPluginAuditRevocationEnvelope.supportedSchema,
            authorities: authorities.sorted { $0.rawValue < $1.rawValue })
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
    }
}

struct ProtectedPluginAuditService {
    typealias Fetch = (URL) async throws -> Data
    typealias BundledData = () -> Data?

    static let primaryURL = URL(string:
        "https://raw.githubusercontent.com/squazaryu/tumoflip-fw-packages/protected-app-audit-ledger/latest.json")!
    static let legacyURL = URL(string:
        "https://raw.githubusercontent.com/squazaryu/tumoflip/protected-app-audit-ledger/latest.json")!
    /// Compatibility alias for callers that only need the authoritative endpoint.
    static let remoteURL = primaryURL

    let primaryURL: URL
    let legacyURL: URL?
    var url: URL { primaryURL }
    let cache: ProtectedPluginAuditCache
    let fetch: Fetch
    /// Bypasses both URLSession's local cache and intermediary caches. Used only for
    /// an explicit Verify on device pass, where the audit may have been published
    /// moments after the same pack was first checked.
    let fetchFresh: Fetch
    let bundledData: BundledData

    init(
        url: URL,
        cache: ProtectedPluginAuditCache,
        fetch: @escaping Fetch,
        fetchFresh: Fetch? = nil,
        bundledData: @escaping BundledData
    ) {
        self.init(
            primaryURL: url,
            legacyURL: nil,
            cache: cache,
            fetch: fetch,
            fetchFresh: fetchFresh,
            bundledData: bundledData)
    }

    init(
        primaryURL: URL,
        legacyURL: URL?,
        cache: ProtectedPluginAuditCache,
        fetch: @escaping Fetch,
        fetchFresh: Fetch? = nil,
        bundledData: @escaping BundledData
    ) {
        self.primaryURL = primaryURL
        self.legacyURL = legacyURL
        self.cache = cache
        self.fetch = fetch
        self.fetchFresh = fetchFresh ?? fetch
        self.bundledData = bundledData
    }

    static func live(bundle: Bundle = .main) -> Self {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Self(
            primaryURL: primaryURL,
            legacyURL: legacyURL,
            cache: ProtectedPluginAuditCache(
                directory: base
                    .appendingPathComponent("TumoCompanion", isDirectory: true)
                    .appendingPathComponent("ProtectedPluginAudits", isDirectory: true)),
            fetch: { url in
                try await fetchData(from: url, forceRemote: false)
            },
            fetchFresh: { url in
                try await fetchData(from: url, forceRemote: true)
            },
            bundledData: {
                guard let url = bundle.url(
                    forResource: "ProtectedPluginAuditLedger", withExtension: "json") else {
                    return nil
                }
                return try? Data(contentsOf: url)
            })
    }

    private static func fetchData(from url: URL, forceRemote: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = forceRemote
            ? .reloadIgnoringLocalAndRemoteCacheData
            : .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if forceRemote {
            request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProtectedPluginAuditFetchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProtectedPluginAuditFetchError.httpStatus(http.statusCode)
        }
        return data
    }

    func resolve(
        for provenance: ProtectedPluginPackProvenance,
        forceRemote: Bool = false
    ) async -> ProtectedPluginAuditResolution {
        let loader = forceRemote ? fetchFresh : fetch
        do {
            let data = try await loader(primaryURL)
            return resolveAuthoritative(
                data,
                for: provenance,
                origin: .remote)
        } catch {
            guard !Task.isCancelled else {
                return .rejected("Protected-app audit refresh was cancelled.")
            }
            if Self.primaryAllowsLegacyFallback(error), let legacyURL {
                // Once this phone has observed an authoritative primary rejection,
                // an outage or 404 cannot delegate authority back to legacy bytes.
                guard !cache.isRevoked(for: provenance, by: .primary) else {
                    return offlineResolution(for: provenance)
                }
                do {
                    let data = try await loader(legacyURL)
                    return resolveAuthoritative(
                        data,
                        for: provenance,
                        origin: .legacy)
                } catch {
                    guard !Task.isCancelled else {
                        return .rejected("Protected-app audit refresh was cancelled.")
                    }
                    return offlineResolution(for: provenance)
                }
            }
            return offlineResolution(for: provenance)
        }
    }

    private func resolveAuthoritative(
        _ data: Data,
        for provenance: ProtectedPluginPackProvenance,
        origin: ProtectedPluginAuditOrigin
    ) -> ProtectedPluginAuditResolution {
        guard !Task.isCancelled else {
            return .rejected("Protected-app audit refresh was cancelled.")
        }
        let document: ProtectedPluginAuditDocument
        do {
            document = try ProtectedPluginAuditValidator.decode(data)
        } catch {
            // Malformed authoritative bytes are a negative trust decision. Persist the
            // tombstone so a later offline run cannot resurrect an older acceptance.
            try? cache.revoke(provenance, authority: authority(for: origin))
            return .rejected(error.localizedDescription, kind: .invalid)
        }
        guard let audit = document.audits.first(where: { $0.matches(provenance) }) else {
            guard !Task.isCancelled else {
                return .rejected("Protected-app audit refresh was cancelled.")
            }
            try? cache.revoke(provenance, authority: authority(for: origin))
            return .rejected(
                "This Community Pack revision has not completed protected-app audit.")
        }
        guard !Task.isCancelled else {
            return .rejected("Protected-app audit refresh was cancelled.")
        }
        let authority = authority(for: origin)
        if authority == .legacy,
           cache.isRevoked(for: provenance, by: .primary) {
            return offlineResolution(for: provenance)
        }
        try? cache.save(audit, for: provenance, authority: authority)
        return .accepted(audit, origin: origin)
    }

    private func authority(
        for origin: ProtectedPluginAuditOrigin
    ) -> ProtectedPluginAuditAuthority {
        origin == .legacy ? .legacy : .primary
    }

    private func offlineResolution(
        for provenance: ProtectedPluginPackProvenance
    ) -> ProtectedPluginAuditResolution {
        guard !cache.isRevoked(for: provenance) else {
            return .rejected(
                "This Community Pack revision was revoked by the protected-app audit ledger.")
        }
        if let cached = cache.load(for: provenance) {
            return .accepted(cached, origin: .cache)
        }
        if let data = bundledData(),
           let document = try? ProtectedPluginAuditValidator.decode(data),
           let audit = document.audits.first(where: { $0.matches(provenance) }) {
            return .accepted(audit, origin: .bundled)
        }
        return .rejected(
            "Protected-app audit ledger is unavailable for this exact Community Pack revision.")
    }

    private static func primaryAllowsLegacyFallback(_ error: Error) -> Bool {
        if let fetchError = error as? ProtectedPluginAuditFetchError {
            return fetchError == .httpStatus(404)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }
}

enum ProtectedPluginAuditFetchError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Protected-app audit server returned an invalid response."
        case .httpStatus(let status):
            return "Protected-app audit server returned HTTP \(status)."
        }
    }
}

enum ProtectedPluginReviewAuditStatus: Equatable {
    case sourceMatches
    case verified
    case intentionallyReplaced
    case needsReview
    case unverified

    var isAudited: Bool {
        self == .sourceMatches || self == .verified || self == .intentionallyReplaced
    }
}

enum ProtectedPluginReviewPolicy {
    static func status(
        _ review: ProtectedPluginReview,
        compatibility: FapCompatibilityState,
        audit: ProtectedPluginAudit?
    ) -> ProtectedPluginReviewAuditStatus {
        guard let audit else { return .unverified }
        guard compatibility.isCompatible, review.deviceKnown else { return .needsReview }
        guard let entry = audit.entry(matching: review) else {
            // Even a byte-for-byte source match is not accepted until the automation
            // has completed an exact audit for this pack, route, and source hash.
            return .needsReview
        }
        if entry.disposition == .intentionallyReplaced {
            // A replacement disposition proves that this exact upstream app should be
            // absent. If any binary exists at its old target, surface it for review —
            // even when it byte-matches upstream — rather than silently accepting a
            // duplicate alongside the Tumoflip replacement.
            return review.deviceMD5 == nil ? .intentionallyReplaced : .needsReview
        }
        guard let deviceMD5 = review.deviceMD5?.lowercased(),
              entry.targetMD5s.contains(deviceMD5) else {
            return .needsReview
        }
        switch entry.disposition {
        case .auditedDifference:
            return .verified
        case .sourceMatches:
            return .sourceMatches
        case .intentionallyReplaced:
            return .needsReview
        }
    }
}
