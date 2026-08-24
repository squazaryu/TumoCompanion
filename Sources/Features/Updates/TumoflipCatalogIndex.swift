import Foundation

/// Immutable server-side history for FW Packages. Firmware versions are not part
/// of catalog identity; they are only used by the compatibility arrays below.
struct TumoflipCatalogIndex: Codable, Equatable {
    struct Release: Codable, Equatable, Identifiable {
        enum State: String, Codable { case active, legacy, withdrawn }

        struct Compatibility: Codable, Equatable {
            let targets: [Int]
            let apiMajors: [Int]

            enum CodingKeys: String, CodingKey {
                case targets
                case apiMajors = "api_majors"
            }
        }

        let revision: Int
        let tag: String
        let repository: String
        let releaseId: String
        let manifestSHA256: String
        let archiveSHA256: String
        let state: State
        let compatibility: Compatibility

        var id: String { "\(repository):\(tag):\(releaseId)" }
        var isInstallable: Bool { state == .active || state == .legacy }
    }

    struct Channel: Codable, Equatable {
        let currentRevision: Int
        let releases: [Release]

        enum CodingKeys: String, CodingKey {
            case currentRevision = "current_revision"
            case releases
        }
    }

    let schema: Int
    let repository: String
    let generatedAt: String
    let selectionPolicy: SelectionPolicy
    let channels: [String: Channel]

    struct SelectionPolicy: Codable, Equatable {
        let auto: String
        let manual: String
        let withdrawal: String
    }

    enum CodingKeys: String, CodingKey {
        case schema, repository, channels
        case generatedAt = "generated_at"
        case selectionPolicy = "selection_policy"
    }

    func validate() throws {
        guard schema == 1, repository == "squazaryu/tumoflip-fw-packages",
              Set(channels.keys) == Set(["stable", "dev"]),
              selectionPolicy.auto == "highest compatible active revision",
              selectionPolicy.manual == "any compatible active or legacy revision",
              selectionPolicy.withdrawal == "immutable release retained; index state becomes withdrawn" else {
            throw TumoflipCatalogIndexError.invalid
        }
        for channelName in ["stable", "dev"] {
            guard let channel = channels[channelName], channel.currentRevision > 0 else {
                throw TumoflipCatalogIndexError.invalid
            }
            var revisions = Set<Int>()
            for release in channel.releases {
                guard revisions.insert(release.revision).inserted,
                      release.revision > 0,
                      release.tag == String(format: "fw-packages-%@-%03d", channelName, release.revision),
                      release.releaseId.count == 64,
                      release.releaseId.allSatisfy({ "0123456789abcdef".contains($0) }),
                      release.manifestSHA256.count == 64,
                      release.manifestSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                      release.archiveSHA256.count == 64,
                      release.archiveSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                      release.compatibility.targets.allSatisfy({ $0 > 0 }),
                      release.compatibility.apiMajors.allSatisfy({ $0 > 0 }) else {
                    throw TumoflipCatalogIndexError.invalid
                }
            }
            guard channel.releases.contains(where: {
                $0.revision == channel.currentRevision && $0.state != .withdrawn
            }) else {
                throw TumoflipCatalogIndexError.invalid
            }
        }
    }

    func releases(for channel: TumoflipFirmwareChannel, api: String?, target: Int?) -> [Release] {
        guard let values = channels[channel.rawValue]?.releases else { return [] }
        let apiMajor = api.flatMap { Int($0.split(separator: ".").first ?? "") }
        return values.filter { release in
            release.isInstallable &&
                target.map { release.compatibility.targets.contains($0) } ?? true &&
                apiMajor.map { release.compatibility.apiMajors.contains($0) } ?? true
        }.sorted {
            if $0.revision != $1.revision { return $0.revision > $1.revision }
            return $0.tag > $1.tag
        }
    }
}

enum TumoflipCatalogIndexError: LocalizedError, Equatable {
    case invalid

    var errorDescription: String? {
        "The FW Packages catalog index is invalid."
    }
}
