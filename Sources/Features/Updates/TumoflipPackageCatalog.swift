import Foundation

struct TumoflipPackageCatalogRepository: Equatable, Hashable {
    enum Role: Equatable {
        case primary
        case legacy
    }

    let slug: String
    let role: Role

    static let primary = Self(
        slug: "squazaryu/tumoflip-fw-packages",
        role: .primary
    )
    static let legacy = Self(
        slug: "squazaryu/tumoflip",
        role: .legacy
    )
}

struct TumoflipPackageCatalogAsset: Equatable {
    let name: String
    let url: URL
    let updatedAt: Date?
}

struct TumoflipPackageCatalogRelease: Equatable {
    let githubID: Int64
    let repository: TumoflipPackageCatalogRepository
    let tag: String
    let assets: [TumoflipPackageCatalogAsset]

    func asset(_ name: String) -> TumoflipPackageCatalogAsset? {
        assets.first { $0.name == name }
    }
}

struct TumoflipPackageCatalogSelection: Equatable {
    struct Identity: Equatable {
        let repository: String
        let githubReleaseID: Int64
        let releaseTag: String
        let manifestReleaseID: String
        let packageReleaseID: String
        let manifestSHA256: String?
        let archiveSHA256: String?
        let catalogChannel: String?
        let catalogRevision: Int?
    }

    let release: TumoflipPackageCatalogRelease
    let manifest: TumoflipManifest
    let manifestUpdatedAt: Date?
    /// Digest evidence comes from the immutable FW Packages catalog index. Legacy
    /// releases may omit it during migration; primary releases must carry it.
    let expectedManifestSHA256: String?
    let expectedArchiveSHA256: String?

    init(
        release: TumoflipPackageCatalogRelease,
        manifest: TumoflipManifest,
        manifestUpdatedAt: Date?,
        expectedManifestSHA256: String? = nil,
        expectedArchiveSHA256: String? = nil
    ) {
        self.release = release
        self.manifest = manifest
        self.manifestUpdatedAt = manifestUpdatedAt
        self.expectedManifestSHA256 = expectedManifestSHA256
        self.expectedArchiveSHA256 = expectedArchiveSHA256
    }

    var identity: Identity {
        Identity(
            repository: release.repository.slug,
            githubReleaseID: release.githubID,
            releaseTag: release.tag,
            manifestReleaseID: manifest.releaseId,
            packageReleaseID: manifest.packageRelease?.id ?? manifest.releaseId,
            manifestSHA256: expectedManifestSHA256,
            archiveSHA256: expectedArchiveSHA256,
            catalogChannel: manifest.packageRelease?.catalogChannel,
            catalogRevision: manifest.packageRelease?.catalogRevision
        )
    }

    var revision: Int? {
        if let catalogRevision = identity.catalogRevision { return catalogRevision }
        let parts = release.tag.split(separator: "-")
        guard let suffix = parts.last, suffix.count == 3 else { return nil }
        return Int(suffix)
    }
}

struct TumoflipPackageCatalogOption: Identifiable, Equatable {
    let id: String
    let repository: TumoflipPackageCatalogRepository
    let tag: String
    let revision: Int?
    let updatedAt: Date?
    let isSelected: Bool
}

enum TumoflipPackageCatalogError: LocalizedError, Equatable {
    case noMatchingRelease(TumoflipFirmwareChannel, String?)
    case malformedPrimary(String)
    case malformedLegacy(String)
    case paginationLimit(String)

    var errorDescription: String? {
        switch self {
        case .noMatchingRelease(let channel, let version):
            if let version {
                return "No \(channel.packageLabel) release matching installed firmware \(version) was found."
            }
            return "No \(channel.packageLabel) release with tumoflip-packages.json was found."
        case .malformedPrimary(let reason):
            return "The authoritative FW Packages catalog is invalid: \(reason)"
        case .malformedLegacy(let reason):
            return "The legacy FW Packages catalog is invalid: \(reason)"
        case .paginationLimit(let repository):
            return "The GitHub release catalog for \(repository) is unexpectedly large."
        }
    }
}

/// Discovers FW Packages independently from firmware releases. A primary result and a
/// legacy result are never merged: once the new repository publishes a channel, it is
/// authoritative for that channel even if the old repository contains a numerically
/// higher or lower revision.
struct TumoflipPackageCatalogClient {
    typealias APIFetch = @Sendable (
        _ repository: TumoflipPackageCatalogRepository,
        _ page: Int,
        _ forceRemote: Bool
    ) async throws -> Data
    typealias AssetFetch = @Sendable (_ url: URL, _ forceRemote: Bool) async throws -> Data
    typealias IndexFetch = @Sendable (_ forceRemote: Bool) async throws -> Data

    private static let perPage = 100
    private static let maximumPages = 20

    let primary: TumoflipPackageCatalogRepository
    let legacy: TumoflipPackageCatalogRepository
    let apiFetch: APIFetch
    let assetFetch: AssetFetch
    let indexFetch: IndexFetch?

    init(
        primary: TumoflipPackageCatalogRepository = .primary,
        legacy: TumoflipPackageCatalogRepository = .legacy,
        apiFetch: @escaping APIFetch,
        assetFetch: @escaping AssetFetch,
        indexFetch: IndexFetch? = nil
    ) {
        self.primary = primary
        self.legacy = legacy
        self.apiFetch = apiFetch
        self.assetFetch = assetFetch
        self.indexFetch = indexFetch
    }

    static func live() -> Self {
        Self(
            apiFetch: { repository, page, forceRemote in
                var components = URLComponents(
                    string: "https://api.github.com/repos/\(repository.slug)/releases"
                )!
                components.queryItems = [
                    URLQueryItem(name: "per_page", value: String(perPage)),
                    URLQueryItem(name: "page", value: String(page)),
                ]
                return try await GitHubAPIClient.shared.data(
                    from: components.url!,
                    maxAge: forceRemote ? 0 : nil,
                    allowStaleOnError: !forceRemote
                ).data
            },
            assetFetch: { url, forceRemote in
                var request = URLRequest(
                    url: url,
                    cachePolicy: forceRemote
                        ? .reloadIgnoringLocalAndRemoteCacheData
                        : .reloadIgnoringLocalCacheData,
                    timeoutInterval: 30
                )
                if forceRemote {
                    request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
                    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            },
            indexFetch: { forceRemote in
                let url = URL(string: "https://raw.githubusercontent.com/squazaryu/tumoflip-fw-packages/main/catalog-index.json")!
                var request = URLRequest(
                    url: url,
                    cachePolicy: forceRemote
                        ? .reloadIgnoringLocalAndRemoteCacheData
                        : .reloadIgnoringLocalCacheData,
                    timeoutInterval: 30
                )
                if forceRemote {
                    request.setValue("no-cache, no-store, max-age=0", forHTTPHeaderField: "Cache-Control")
                    request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return data
            }
        )
    }

    /// Returns every compatible immutable catalog revision, newest first. Auto
    /// mode uses the first result; the UI can select any other result for a
    /// deterministic rollback without pretending that it is a firmware update.
    func available(
        for channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String? = nil,
        installedTarget: Int? = nil,
        installedCommit: String? = nil,
        installedCommitDirty: Bool? = nil,
        forceRemote: Bool = false,
        requiredRepository: TumoflipPackageCatalogRepository? = nil,
        requestedRevision: Int? = nil
    ) async throws -> [TumoflipPackageCatalogSelection] {
        if let requiredRepository {
            let releases = try await releases(in: requiredRepository, forceRemote: forceRemote)
            if requiredRepository.role == .legacy,
               let requestedRevision {
                return try await selectLegacyRevision(
                    releases,
                    channel: channel,
                    revision: requestedRevision,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    forceRemote: forceRemote
                )
            }
            if requiredRepository.role == .primary {
                // The initial selection is resolved through the immutable index,
                // which contributes manifest/archive digests to its identity. A
                // pre-install recheck must use the same evidence; otherwise the
                // identical release appears changed solely because the recheck
                // omitted those digests.
                let indexed = try await indexedAuthoritativeReleases(
                    authoritativeReleases(releases, channel: channel),
                    channel: channel,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    forceRemote: forceRemote
                )
                return try await selectAllAuthoritative(
                    indexed.releases,
                    in: requiredRepository,
                    channel: channel,
                    installedVersion: installedVersion,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    installedCommit: installedCommit,
                    installedCommitDirty: installedCommitDirty,
                    forceRemote: forceRemote,
                    indexEvidence: indexed.evidence
                )
            }
            return try await selectAll(
                releases,
                in: requiredRepository,
                channel: channel,
                installedVersion: installedVersion,
                installedAPI: installedAPI,
                installedTarget: installedTarget,
                installedCommit: installedCommit,
                installedCommitDirty: installedCommitDirty,
                forceRemote: forceRemote,
                allowLegacyFirmwareReleases: requiredRepository.role == .legacy
            )
        }

        do {
            let releases = try await releases(in: primary, forceRemote: forceRemote)
            let indexed = try await indexedAuthoritativeReleases(
                authoritativeReleases(releases, channel: channel),
                channel: channel,
                installedAPI: installedAPI,
                installedTarget: installedTarget,
                forceRemote: forceRemote
            )
            let channelReleases = indexed.releases
            if !channelReleases.isEmpty {
                let current = try await selectAllAuthoritative(
                    channelReleases,
                    in: primary,
                    channel: channel,
                    installedVersion: installedVersion,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    installedCommit: installedCommit,
                    installedCommitDirty: installedCommitDirty,
                    forceRemote: forceRemote,
                    indexEvidence: indexed.evidence
                )
                let history = await legacyHistorySelections(
                    for: channel,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    forceRemote: forceRemote
                )
                return (current + history).sorted {
                    ($0.revision ?? 0) > ($1.revision ?? 0)
                }
            }
        } catch {
            guard Self.primaryUnavailable(error) else { throw error }
        }

        let legacyReleases = try await releases(in: legacy, forceRemote: forceRemote)
        return try await selectAll(
            legacyReleases,
            in: legacy,
            channel: channel,
            installedVersion: installedVersion,
            installedAPI: installedAPI,
            installedTarget: installedTarget,
            installedCommit: installedCommit,
            installedCommitDirty: installedCommitDirty,
            forceRemote: forceRemote,
            allowLegacyFirmwareReleases: true
        )
    }

    func latest(
        for channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String? = nil,
        installedTarget: Int? = nil,
        installedCommit: String? = nil,
        installedCommitDirty: Bool? = nil,
        forceRemote: Bool = false,
        requiredRepository: TumoflipPackageCatalogRepository? = nil,
        requestedRevision: Int? = nil
    ) async throws -> TumoflipPackageCatalogSelection {
        let candidates = try await available(
            for: channel,
            installedVersion: installedVersion,
            installedAPI: installedAPI,
            installedTarget: installedTarget,
            installedCommit: installedCommit,
            installedCommitDirty: installedCommitDirty,
            forceRemote: forceRemote,
            requiredRepository: requiredRepository,
            requestedRevision: requestedRevision
        )
        guard let selection = requestedRevision.map({ revision in
            candidates.first(where: { $0.revision == revision })
        }) ?? candidates.first else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return selection
    }

    private func releases(
        in repository: TumoflipPackageCatalogRepository,
        forceRemote: Bool
    ) async throws -> [TumoflipPackageCatalogRelease] {
        var output: [TumoflipPackageCatalogRelease] = []
        for page in 1...Self.maximumPages {
            let data = try await apiFetch(repository, page, forceRemote)
            let records: [GitHubReleaseRecord]
            do {
                records = try Self.decoder.decode([GitHubReleaseRecord].self, from: data)
            } catch {
                throw repository.role == .primary
                    ? TumoflipPackageCatalogError.malformedPrimary("GitHub release list cannot be decoded")
                    : TumoflipPackageCatalogError.malformedLegacy("GitHub release list cannot be decoded")
            }
            output.append(contentsOf: records.compactMap { record in
                guard !record.draft,
                      TumoflipReleaseCatalogPolicy.isVisible(body: record.body) else { return nil }
                let assets = record.assets.map {
                    TumoflipPackageCatalogAsset(
                        name: $0.name,
                        url: $0.downloadURL,
                        updatedAt: $0.updatedAt
                    )
                }
                return TumoflipPackageCatalogRelease(
                    githubID: record.id,
                    repository: repository,
                    tag: record.tagName,
                    assets: assets
                )
            })
            if records.count < Self.perPage { return output }
        }
        throw TumoflipPackageCatalogError.paginationLimit(repository.slug)
    }

    private func select(
        _ releases: [TumoflipPackageCatalogRelease],
        in repository: TumoflipPackageCatalogRepository,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String?,
        installedTarget: Int?,
        installedCommit: String?,
        installedCommitDirty: Bool?,
        forceRemote: Bool,
        allowLegacyFirmwareReleases: Bool
    ) async throws -> TumoflipPackageCatalogSelection {
        guard let first = try await selectAll(
            releases,
            in: repository,
            channel: channel,
            installedVersion: installedVersion,
            installedAPI: installedAPI,
            installedTarget: installedTarget,
            installedCommit: installedCommit,
            installedCommitDirty: installedCommitDirty,
            forceRemote: forceRemote,
            allowLegacyFirmwareReleases: allowLegacyFirmwareReleases
        ).first else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return first
    }

    private func selectAll(
        _ releases: [TumoflipPackageCatalogRelease],
        in repository: TumoflipPackageCatalogRepository,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String?,
        installedTarget: Int?,
        installedCommit: String?,
        installedCommitDirty: Bool?,
        forceRemote: Bool,
        allowLegacyFirmwareReleases: Bool
    ) async throws -> [TumoflipPackageCatalogSelection] {
        let authoritative = authoritativeReleases(releases, channel: channel)
        if !authoritative.isEmpty {
            return try await selectAllAuthoritative(
                authoritative,
                in: repository,
                channel: channel,
                installedVersion: installedVersion,
                installedAPI: installedAPI,
                installedTarget: installedTarget,
                installedCommit: installedCommit,
                installedCommitDirty: installedCommitDirty,
                forceRemote: forceRemote
            )
        }

        guard allowLegacyFirmwareReleases else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        var selected: [TumoflipPackageCatalogSelection] = []
        for release in releases {
            guard let manifestAsset = release.asset("tumoflip-packages.json"),
                  let rawManifest = try? await loadManifest(
                      from: manifestAsset.url,
                      forceRemote: forceRemote,
                      expectedSHA256: nil
                  ),
                  rawManifest.packageRelease?.isIndependentCatalog != true,
                  TumoflipPackageReleaseMatcher.matches(
                    manifestVersion: rawManifest.firmware.version,
                    packageRelease: rawManifest.packageRelease,
                    channel: channel,
                    installedVersion: installedVersion
                  ),
                  installedAPI.map({ $0 == rawManifest.firmware.api }) ?? true,
                  installedTarget.map({ $0 == rawManifest.firmware.target }) ?? true else { continue }
            let manifest = normalizedLegacyManifest(
                rawManifest,
                channel: channel,
                revision: revision(from: release.tag, channel: channel) ?? 0,
                tag: release.tag
            )
            let candidate = TumoflipPackageCatalogSelection(
                release: release,
                manifest: manifest,
                manifestUpdatedAt: manifestAsset.updatedAt
            )
            selected.append(candidate)
        }
        guard !selected.isEmpty else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return selected
    }

    /// Transitional releases from the old firmware repository did not carry
    /// independent-catalog metadata. The index supplies their channel/revision;
    /// normalize that metadata in memory so they remain valid rollback snapshots
    /// without rewriting the immutable legacy assets.
    private func normalizedLegacyManifest(
        _ manifest: TumoflipManifest,
        channel: TumoflipFirmwareChannel,
        revision: Int,
        tag: String
    ) -> TumoflipManifest {
        guard revision > 0, manifest.packageRelease?.isIndependentCatalog != true else {
            return manifest
        }
        let previous = manifest.packageRelease
        let sourceCommit = previous?.sourceCommit.count == 40
            ? previous!.sourceCommit
            : String(manifest.releaseId.prefix(40))
        let packageRelease = TumoflipManifest.PackageRelease(
            id: previous?.id ?? "legacy-\(manifest.releaseId.prefix(16))",
            type: "package-only",
            sourceCommit: sourceCommit,
            sourceDirty: false,
            sourceFirmwareVersion: previous?.sourceFirmwareVersion ?? manifest.firmware.version,
            targetReleaseTag: previous?.targetReleaseTag ?? manifest.firmware.version,
            firmwareFlashUnchanged: true,
            catalogChannel: channel.rawValue,
            catalogRevision: revision,
            catalogReleaseTag: tag,
            catalogInstallScope: .delta,
            compatibleReleases: nil,
            catalogModifiedTargets: manifest.packages.values.flatMap { $0.map(\.source) },
            overlayTargets: nil,
            targetFirmwareCommit: nil,
            targetSourceCommit: nil,
            targetReleaseId: nil
        )
        return TumoflipManifest(
            schema: manifest.schema,
            releaseId: manifest.releaseId,
            firmware: manifest.firmware,
            artifacts: manifest.artifacts,
            packages: manifest.packages,
            cleanup: manifest.cleanup,
            safety: manifest.safety,
            packageRelease: packageRelease
        )
    }

    private func legacyHistorySelections(
        for channel: TumoflipFirmwareChannel,
        installedAPI: String?,
        installedTarget: Int?,
        forceRemote: Bool
    ) async -> [TumoflipPackageCatalogSelection] {
        guard let index = try? await loadCatalogIndex(forceRemote: forceRemote) else { return [] }
        let historicalTags = Set(index.releases(for: channel, api: installedAPI, target: installedTarget)
            .filter { $0.state == .legacy }
            .map(\.tag))
        guard !historicalTags.isEmpty,
              let releases = try? await releases(in: legacy, forceRemote: forceRemote) else {
            return []
        }
        var output: [TumoflipPackageCatalogSelection] = []
        for release in releases where historicalTags.contains(release.tag) {
            let evidence = index.channels[channel.rawValue]?.releases
                .first(where: { $0.tag == release.tag })
            guard let asset = release.asset("tumoflip-packages.json"),
                  let raw = try? await loadManifest(
                      from: asset.url,
                      forceRemote: forceRemote,
                      expectedSHA256: evidence?.manifestSHA256
                  ),
                  let revision = revision(from: release.tag, channel: channel) else { continue }
            let manifest = normalizedLegacyManifest(raw, channel: channel, revision: revision, tag: release.tag)
            guard installedTarget.map({ $0 == manifest.firmware.target }) ?? true,
                  installedAPI.map({ FirmwareAPICompatibility.hasSameMajor($0, manifest.firmware.api) }) ?? true else { continue }
            output.append(.init(
                release: release,
                manifest: manifest,
                manifestUpdatedAt: asset.updatedAt,
                expectedManifestSHA256: evidence?.manifestSHA256,
                expectedArchiveSHA256: evidence?.archiveSHA256
            ))
        }
        return output
    }

    private func loadCatalogIndex(forceRemote: Bool) async throws -> TumoflipCatalogIndex? {
        guard let indexFetch else { return nil }
        let data: Data
        do {
            data = try await indexFetch(forceRemote)
        } catch {
            // A transport failure is a migration/network condition. Keep the
            // established release API fallback; malformed index data is terminal.
            return nil
        }
        do {
            let index = try JSONDecoder().decode(TumoflipCatalogIndex.self, from: data)
            try index.validate()
            return index
        } catch {
            throw TumoflipPackageCatalogError.malformedPrimary("catalog index is invalid")
        }
    }

    private func selectLegacyRevision(
        _ releases: [TumoflipPackageCatalogRelease],
        channel: TumoflipFirmwareChannel,
        revision: Int,
        installedAPI: String?,
        installedTarget: Int?,
        forceRemote: Bool
    ) async throws -> [TumoflipPackageCatalogSelection] {
        let tag = String(format: "fw-packages-%@-%03d", channel.rawValue, revision)
        guard let release = releases.first(where: { $0.tag == tag }),
              let asset = release.asset("tumoflip-packages.json") else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, nil)
        }
        let raw: TumoflipManifest
        let evidence = try await loadCatalogIndex(forceRemote: forceRemote)?.channels[channel.rawValue]?.releases
            .first(where: { $0.revision == revision })
        do {
            raw = try await loadManifest(
                from: asset.url,
                forceRemote: forceRemote,
                expectedSHA256: evidence?.manifestSHA256
            )
        } catch {
            throw TumoflipPackageCatalogError.malformedLegacy("\(tag) manifest failed validation")
        }
        let manifest = normalizedLegacyManifest(raw, channel: channel, revision: revision, tag: tag)
        guard installedAPI.map({ FirmwareAPICompatibility.hasSameMajor($0, manifest.firmware.api) }) ?? true,
              installedTarget.map({ $0 == manifest.firmware.target }) ?? true else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, nil)
        }
        return [.init(
            release: release,
            manifest: manifest,
            manifestUpdatedAt: asset.updatedAt,
            expectedManifestSHA256: evidence?.manifestSHA256,
            expectedArchiveSHA256: evidence?.archiveSHA256
        )]
    }

    private func selectAuthoritative(
        _ releases: [TumoflipPackageCatalogRelease],
        in repository: TumoflipPackageCatalogRepository,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String?,
        installedTarget: Int?,
        installedCommit: String?,
        installedCommitDirty: Bool?,
        forceRemote: Bool
    ) async throws -> TumoflipPackageCatalogSelection {
        guard let first = try await selectAllAuthoritative(
            releases,
            in: repository,
            channel: channel,
            installedVersion: installedVersion,
            installedAPI: installedAPI,
            installedTarget: installedTarget,
            installedCommit: installedCommit,
            installedCommitDirty: installedCommitDirty,
            forceRemote: forceRemote
        ).first else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return first
    }

    private func selectAllAuthoritative(
        _ releases: [TumoflipPackageCatalogRelease],
        in repository: TumoflipPackageCatalogRepository,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String?,
        installedTarget: Int?,
        installedCommit: String?,
        installedCommitDirty: Bool?,
        forceRemote: Bool,
        indexEvidence: [String: TumoflipCatalogIndex.Release] = [:]
    ) async throws -> [TumoflipPackageCatalogSelection] {
        let ranked = releases.compactMap { release -> (Int, TumoflipPackageCatalogRelease)? in
            revision(from: release.tag, channel: channel).map { ($0, release) }
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.githubID > $1.1.githubID
        }
        guard !ranked.isEmpty else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        var selections: [TumoflipPackageCatalogSelection] = []
        for (revision, release) in ranked {
            guard let manifestAsset = release.asset("tumoflip-packages.json"),
                  release.asset("tumoflip-packages.zip") != nil else {
                throw malformed(repository, "\(release.tag) is missing manifest or package archive")
            }
            let evidence = indexEvidence[release.tag]
            let manifest: TumoflipManifest
            do {
                manifest = try await loadManifest(
                    from: manifestAsset.url,
                    forceRemote: forceRemote,
                    expectedSHA256: evidence?.manifestSHA256
                )
            } catch {
                throw malformed(repository, "\(release.tag) manifest failed validation")
            }
            guard let packageRelease = manifest.packageRelease,
                  packageRelease.isIndependentCatalog,
                  packageRelease.catalogChannel == channel.rawValue,
                  packageRelease.catalogRevision == revision,
                  packageRelease.catalogReleaseTag == release.tag,
                  evidence.map({ $0.releaseId == manifest.releaseId }) ?? true else {
                throw malformed(repository, "\(release.tag) provenance does not match its manifest")
            }
            let versionMatches = TumoflipPackageReleaseMatcher.matches(
                manifestVersion: manifest.firmware.version,
                packageRelease: packageRelease,
                channel: channel,
                installedVersion: installedVersion
            )
            if manifest.isFirmwareSnapshotCatalog {
                guard versionMatches,
                      installedAPI == manifest.firmware.api,
                      installedTarget == manifest.firmware.target,
                      installedCommitDirty == false,
                      TumoflipFirmwareCommitIdentity.matches(
                          reported: installedCommit,
                          expected: packageRelease.targetFirmwareCommit
                      ) else {
                    continue
                }
                selections.append(TumoflipPackageCatalogSelection(
                    release: release,
                    manifest: manifest,
                    manifestUpdatedAt: manifestAsset.updatedAt,
                    expectedManifestSHA256: evidence?.manifestSHA256,
                    expectedArchiveSHA256: evidence?.archiveSHA256
                ))
                continue
            }
            let apiMatches = installedAPI.map {
                FirmwareAPICompatibility.hasSameMajor($0, manifest.firmware.api)
            } ?? true
            let targetMatches = installedTarget.map { $0 == manifest.firmware.target } ?? true
            guard versionMatches, apiMatches, targetMatches else {
                // A newer immutable catalog can target a newer firmware API. That is
                // not malformed provenance; continue to an older compatible revision.
                continue
            }
            selections.append(TumoflipPackageCatalogSelection(
                release: release,
                manifest: manifest,
                manifestUpdatedAt: manifestAsset.updatedAt,
                expectedManifestSHA256: evidence?.manifestSHA256,
                expectedArchiveSHA256: evidence?.archiveSHA256
            ))
        }
        guard !selections.isEmpty else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return selections
    }

    private func loadManifest(
        from url: URL,
        forceRemote: Bool,
        expectedSHA256: String?
    ) async throws -> TumoflipManifest {
        let data = try await assetFetch(url, forceRemote)
        if let expectedSHA256, TumoflipHash.sha256(data) != expectedSHA256 {
            throw TumoflipPackageCatalogError.malformedPrimary("manifest digest mismatch")
        }
        let manifest = try TumoflipManifest.decode(data)
        try manifest.validate()
        return manifest
    }

    private func authoritativeReleases(
        _ releases: [TumoflipPackageCatalogRelease],
        channel: TumoflipFirmwareChannel
    ) -> [TumoflipPackageCatalogRelease] {
        releases.filter { revision(from: $0.tag, channel: channel) != nil }
    }

    /// The release API remains the asset transport, while the immutable index is
    /// the source of truth for withdrawn/history entries. During migration an
    /// unavailable index is tolerated so older clients can still consume v2
    /// releases; malformed manifests remain terminal failures.
    private func indexedAuthoritativeReleases(
        _ releases: [TumoflipPackageCatalogRelease],
        channel: TumoflipFirmwareChannel,
        installedAPI: String?,
        installedTarget: Int?,
        forceRemote: Bool
    ) async throws -> (releases: [TumoflipPackageCatalogRelease], evidence: [String: TumoflipCatalogIndex.Release]) {
        guard let index = try await loadCatalogIndex(forceRemote: forceRemote) else {
            return (releases, [:])
        }
        let indexed = index.releases(
            for: channel,
            api: installedAPI,
            target: installedTarget
        )
        let allowed = Set(indexed.map(\.tag))
        return (
            releases.filter { allowed.contains($0.tag) },
            Dictionary(uniqueKeysWithValues: indexed.map { ($0.tag, $0) })
        )
    }

    private func revision(from tag: String, channel: TumoflipFirmwareChannel) -> Int? {
        let prefix = "fw-packages-\(channel.rawValue)-"
        guard tag.hasPrefix(prefix) else { return nil }
        let suffix = tag.dropFirst(prefix.count)
        guard suffix.count == 3, suffix.allSatisfy(\.isNumber),
              let value = Int(suffix), value > 0 else { return nil }
        return value
    }

    private func malformed(
        _ repository: TumoflipPackageCatalogRepository,
        _ reason: String
    ) -> Error {
        repository.role == .primary
            ? TumoflipPackageCatalogError.malformedPrimary(reason)
            : TumoflipPackageCatalogError.malformedLegacy(reason)
    }

    private static func primaryUnavailable(_ error: Error) -> Bool {
        if let github = error as? GitHubAPIError {
            switch github {
            case .transportFailure, .httpStatus(404): return true
            default: return false
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return true
            default:
                return false
            }
        }
        return false
    }

    private struct GitHubReleaseRecord: Decodable {
        struct Asset: Decodable {
            let name: String
            let downloadURL: URL
            let updatedAt: Date?

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
                case updatedAt = "updated_at"
            }
        }

        let id: Int64
        let tagName: String
        let body: String?
        let draft: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case id, body, draft, assets
            case tagName = "tag_name"
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
