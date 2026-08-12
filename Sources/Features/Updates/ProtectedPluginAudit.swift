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
    /// This upstream app is intentionally absent because another Tumoflip app replaces it.
    case intentionallyReplaced
}

struct ProtectedPluginAuditEntry: Codable, Equatable {
    let remotePath: String
    let targetPath: String
    let sourceMD5: String
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
    static let supportedSchema = 1
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

        var tags = Set<String>()
        for audit in document.audits {
            guard !audit.sourceTag.isEmpty, tags.insert(audit.sourceTag).inserted else {
                throw ProtectedPluginAuditValidationError.malformedAudit("duplicate or empty source tag")
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
                      ProtectedPluginPackProvenance.isSHA256(archive.sha256) else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("invalid archive provenance")
                }
            }

            var identities = Set<String>()
            for entry in audit.entries {
                guard entry.remotePath.hasPrefix("/ext/"), entry.targetPath.hasPrefix("/ext/"),
                      entry.sourceMD5.count == 32,
                      entry.sourceMD5.allSatisfy(\.isHexDigit) else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("invalid protected entry")
                }
                let identity = [entry.remotePath, entry.targetPath, entry.sourceMD5.lowercased()]
                    .joined(separator: "\u{001F}")
                guard identities.insert(identity).inserted else {
                    throw ProtectedPluginAuditValidationError.malformedAudit("duplicate protected entry")
                }
            }
        }
    }
}

enum ProtectedPluginAuditOrigin: String, Equatable {
    case remote
    case cache
    case bundled
}

struct ProtectedPluginAuditResolution: Equatable {
    let audit: ProtectedPluginAudit?
    let origin: ProtectedPluginAuditOrigin?
    let failure: String?

    static func accepted(_ audit: ProtectedPluginAudit, origin: ProtectedPluginAuditOrigin) -> Self {
        Self(audit: audit, origin: origin, failure: nil)
    }

    static func rejected(_ failure: String) -> Self {
        Self(audit: nil, origin: nil, failure: failure)
    }
}

private struct ProtectedPluginAuditCacheEnvelope: Codable {
    let schema: Int
    let sourceRepository: String
    let audit: ProtectedPluginAudit
}

struct ProtectedPluginAuditCache {
    let directory: URL

    func load(for provenance: ProtectedPluginPackProvenance) -> ProtectedPluginAudit? {
        let url = directory.appendingPathComponent("\(provenance.cacheKey).json")
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

    func save(_ audit: ProtectedPluginAudit, for provenance: ProtectedPluginPackProvenance) throws {
        guard audit.matches(provenance) else { return }
        let envelope = ProtectedPluginAuditCacheEnvelope(
            schema: ProtectedPluginAuditDocument.supportedSchema,
            sourceRepository: ProtectedPluginAuditDocument.expectedRepository,
            audit: audit)
        let data = try JSONEncoder().encode(envelope)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent("\(provenance.cacheKey).json"),
            options: .atomic)
    }
}

struct ProtectedPluginAuditService {
    typealias Fetch = (URL) async throws -> Data
    typealias BundledData = () -> Data?

    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/squazaryu/tumoflip/protected-app-audit-ledger/latest.json")!

    let url: URL
    let cache: ProtectedPluginAuditCache
    let fetch: Fetch
    let bundledData: BundledData

    static func live(bundle: Bundle = .main) -> Self {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Self(
            url: remoteURL,
            cache: ProtectedPluginAuditCache(
                directory: base
                    .appendingPathComponent("TumoCompanion", isDirectory: true)
                    .appendingPathComponent("ProtectedPluginAudits", isDirectory: true)),
            fetch: { url in
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            },
            bundledData: {
                guard let url = bundle.url(
                    forResource: "ProtectedPluginAuditLedger", withExtension: "json") else {
                    return nil
                }
                return try? Data(contentsOf: url)
            })
    }

    func resolve(for provenance: ProtectedPluginPackProvenance) async -> ProtectedPluginAuditResolution {
        do {
            let data = try await fetch(url)
            let document: ProtectedPluginAuditDocument
            do {
                document = try ProtectedPluginAuditValidator.decode(data)
            } catch {
                // A reachable but malformed authoritative ledger must never be replaced by
                // stale cache: this is a trust failure, not an offline condition.
                return .rejected(error.localizedDescription)
            }
            guard let audit = document.audits.first(where: { $0.matches(provenance) }) else {
                return .rejected("This Community Pack revision has not completed protected-app audit.")
            }
            try? cache.save(audit, for: provenance)
            return .accepted(audit, origin: .remote)
        } catch {
            if let cached = cache.load(for: provenance) {
                return .accepted(cached, origin: .cache)
            }
            if let data = bundledData(),
               let document = try? ProtectedPluginAuditValidator.decode(data),
               let audit = document.audits.first(where: { $0.matches(provenance) }) {
                return .accepted(audit, origin: .bundled)
            }
            return .rejected("Protected-app audit ledger is unavailable for this exact Community Pack revision.")
        }
    }
}

enum ProtectedPluginReviewAuditStatus: Equatable {
    case sourceMatches
    case verified
    case intentionallyReplaced
    case needsReview

    var isAudited: Bool {
        self == .verified || self == .intentionallyReplaced
    }
}

enum ProtectedPluginReviewPolicy {
    static func status(
        _ review: ProtectedPluginReview,
        compatibility: FapCompatibilityState,
        audit: ProtectedPluginAudit?
    ) -> ProtectedPluginReviewAuditStatus {
        guard compatibility.isCompatible, review.deviceKnown else { return .needsReview }
        if let entry = audit?.entry(matching: review),
           entry.disposition == .intentionallyReplaced {
            // A replacement disposition proves that this exact upstream app should be
            // absent. If any binary exists at its old target, surface it for review —
            // even when it byte-matches upstream — rather than silently accepting a
            // duplicate alongside the Tumoflip replacement.
            return review.deviceMD5 == nil ? .intentionallyReplaced : .needsReview
        }
        if let deviceMD5 = review.deviceMD5,
           deviceMD5.caseInsensitiveCompare(review.newMD5) == .orderedSame {
            return .sourceMatches
        }
        guard let entry = audit?.entry(matching: review) else { return .needsReview }
        switch entry.disposition {
        case .auditedDifference:
            return review.deviceMD5 == nil ? .needsReview : .verified
        case .intentionallyReplaced:
            return .needsReview
        }
    }
}
