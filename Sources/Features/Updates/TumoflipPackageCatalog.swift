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
        let catalogChannel: String?
        let catalogRevision: Int?
    }

    let release: TumoflipPackageCatalogRelease
    let manifest: TumoflipManifest
    let manifestUpdatedAt: Date?

    var identity: Identity {
        Identity(
            repository: release.repository.slug,
            githubReleaseID: release.githubID,
            releaseTag: release.tag,
            manifestReleaseID: manifest.releaseId,
            packageReleaseID: manifest.packageRelease?.id ?? manifest.releaseId,
            catalogChannel: manifest.packageRelease?.catalogChannel,
            catalogRevision: manifest.packageRelease?.catalogRevision
        )
    }
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

    private static let perPage = 100
    private static let maximumPages = 20

    let primary: TumoflipPackageCatalogRepository
    let legacy: TumoflipPackageCatalogRepository
    let apiFetch: APIFetch
    let assetFetch: AssetFetch

    init(
        primary: TumoflipPackageCatalogRepository = .primary,
        legacy: TumoflipPackageCatalogRepository = .legacy,
        apiFetch: @escaping APIFetch,
        assetFetch: @escaping AssetFetch
    ) {
        self.primary = primary
        self.legacy = legacy
        self.apiFetch = apiFetch
        self.assetFetch = assetFetch
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
            }
        )
    }

    func latest(
        for channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String? = nil,
        installedTarget: Int? = nil,
        forceRemote: Bool = false,
        requiredRepository: TumoflipPackageCatalogRepository? = nil
    ) async throws -> TumoflipPackageCatalogSelection {
        if let requiredRepository {
            let releases = try await releases(
                in: requiredRepository,
                forceRemote: forceRemote
            )
            return try await select(
                releases,
                in: requiredRepository,
                channel: channel,
                installedVersion: installedVersion,
                installedAPI: installedAPI,
                installedTarget: installedTarget,
                forceRemote: forceRemote,
                allowLegacyFirmwareReleases: requiredRepository.role == .legacy
            )
        }

        do {
            let releases = try await releases(in: primary, forceRemote: forceRemote)
            let channelReleases = authoritativeReleases(releases, channel: channel)
            if !channelReleases.isEmpty {
                return try await selectAuthoritative(
                    channelReleases,
                    in: primary,
                    channel: channel,
                    installedVersion: installedVersion,
                    installedAPI: installedAPI,
                    installedTarget: installedTarget,
                    forceRemote: forceRemote
                )
            }
            // Transitional state: the new repository exists but has not published this
            // channel yet. The immutable legacy repository remains the only source.
        } catch {
            guard Self.primaryUnavailable(error) else { throw error }
        }

        let legacyReleases = try await releases(in: legacy, forceRemote: forceRemote)
        return try await select(
            legacyReleases,
            in: legacy,
            channel: channel,
            installedVersion: installedVersion,
            installedAPI: installedAPI,
            installedTarget: installedTarget,
            forceRemote: forceRemote,
            allowLegacyFirmwareReleases: true
        )
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
        forceRemote: Bool,
        allowLegacyFirmwareReleases: Bool
    ) async throws -> TumoflipPackageCatalogSelection {
        let authoritative = authoritativeReleases(releases, channel: channel)
        if !authoritative.isEmpty {
            return try await selectAuthoritative(
                authoritative,
                in: repository,
                channel: channel,
                installedVersion: installedVersion,
                installedAPI: installedAPI,
                installedTarget: installedTarget,
                forceRemote: forceRemote
            )
        }

        guard allowLegacyFirmwareReleases else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        var selected: TumoflipPackageCatalogSelection?
        for release in releases {
            guard let manifestAsset = release.asset("tumoflip-packages.json"),
                  let manifest = try? await loadManifest(
                    from: manifestAsset.url,
                    forceRemote: forceRemote
                  ),
                  manifest.packageRelease?.isIndependentCatalog != true,
                  TumoflipPackageReleaseMatcher.matches(
                    manifestVersion: manifest.firmware.version,
                    packageRelease: manifest.packageRelease,
                    channel: channel,
                    installedVersion: installedVersion
                  ),
                  installedAPI.map({ $0 == manifest.firmware.api }) ?? true,
                  installedTarget.map({ $0 == manifest.firmware.target }) ?? true else { continue }
            let candidate = TumoflipPackageCatalogSelection(
                release: release,
                manifest: manifest,
                manifestUpdatedAt: manifestAsset.updatedAt
            )
            if selected == nil { selected = candidate }
        }
        guard let selected else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        return selected
    }

    private func selectAuthoritative(
        _ releases: [TumoflipPackageCatalogRelease],
        in repository: TumoflipPackageCatalogRepository,
        channel: TumoflipFirmwareChannel,
        installedVersion: String?,
        installedAPI: String?,
        installedTarget: Int?,
        forceRemote: Bool
    ) async throws -> TumoflipPackageCatalogSelection {
        let ranked = releases.compactMap { release -> (Int, TumoflipPackageCatalogRelease)? in
            revision(from: release.tag, channel: channel).map { ($0, release) }
        }.sorted {
            if $0.0 != $1.0 { return $0.0 > $1.0 }
            return $0.1.githubID > $1.1.githubID
        }
        guard !ranked.isEmpty else {
            throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
        }
        for (revision, release) in ranked {
            guard let manifestAsset = release.asset("tumoflip-packages.json"),
                  release.asset("tumoflip-packages.zip") != nil else {
                throw malformed(repository, "\(release.tag) is missing manifest or package archive")
            }
            let manifest: TumoflipManifest
            do {
                manifest = try await loadManifest(from: manifestAsset.url, forceRemote: forceRemote)
            } catch {
                throw malformed(repository, "\(release.tag) manifest failed validation")
            }
            guard let packageRelease = manifest.packageRelease,
                  packageRelease.isIndependentCatalog,
                  packageRelease.catalogChannel == channel.rawValue,
                  packageRelease.catalogRevision == revision,
                  packageRelease.catalogReleaseTag == release.tag else {
                throw malformed(repository, "\(release.tag) provenance does not match its manifest")
            }
            let versionMatches = TumoflipPackageReleaseMatcher.matches(
                manifestVersion: manifest.firmware.version,
                packageRelease: packageRelease,
                channel: channel,
                installedVersion: installedVersion
            )
            let apiMatches = installedAPI.map { $0 == manifest.firmware.api } ?? true
            let targetMatches = installedTarget.map { $0 == manifest.firmware.target } ?? true
            guard versionMatches, apiMatches, targetMatches else {
                // A newer immutable catalog can target a newer firmware API. That is
                // not malformed provenance; continue to an older compatible revision.
                continue
            }
            return TumoflipPackageCatalogSelection(
                release: release,
                manifest: manifest,
                manifestUpdatedAt: manifestAsset.updatedAt
            )
        }
        throw TumoflipPackageCatalogError.noMatchingRelease(channel, installedVersion)
    }

    private func loadManifest(from url: URL, forceRemote: Bool) async throws -> TumoflipManifest {
        let manifest = try TumoflipManifest.decode(await assetFetch(url, forceRemote))
        try manifest.validate()
        return manifest
    }

    private func authoritativeReleases(
        _ releases: [TumoflipPackageCatalogRelease],
        channel: TumoflipFirmwareChannel
    ) -> [TumoflipPackageCatalogRelease] {
        releases.filter { revision(from: $0.tag, channel: channel) != nil }
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
