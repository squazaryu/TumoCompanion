import Foundation

/// Schema-v2 `tumoflip-packages.json` sidecar published with each tumoflip release
/// (see `docs/tumoflip-packages.md`). Records firmware identity, update artifact
/// hashes, SD files grouped as base/arf/module_one/protocol_packs, and a host-side
/// legacy-cleanup list. This is the input contract for atomic SD install + rollback
/// (issue #8). Firmware DFU flashing (the `artifacts`/`safety` fields) is a separate,
/// explicitly-confirmed phase and is intentionally out of scope for the SD installer.
struct TumoflipManifest: Codable, Equatable {
    let schema: Int
    let releaseId: String
    let firmware: Firmware
    let artifacts: [String: Artifact]
    let packages: [String: [PackageFile]]
    let cleanup: [CleanupEntry]
    let safety: Safety?
    let packageRelease: PackageRelease?

    struct Firmware: Codable, Equatable {
        let api: String
        let name: String
        let version: String
        let target: Int
        let radioAddress: String?
        enum CodingKeys: String, CodingKey {
            case api, name, version, target
            case radioAddress = "radio_address"
        }
    }
    struct Artifact: Codable, Equatable {
        let bytes: Int
        let sha256: String
    }
    /// One SD file: `source` is relative to the release resources tree; `target` is
    /// its absolute `/ext` path on the Flipper.
    struct PackageFile: Codable, Equatable {
        let bytes: Int
        let sha256: String
        /// Optional content hash of the installed target. New manifests publish it so
        /// firmware-bundled resources can be adopted without trusting file presence.
        let md5: String?
        let source: String
        let target: String

        init(bytes: Int, sha256: String, md5: String? = nil, source: String, target: String) {
            self.bytes = bytes
            self.sha256 = sha256
            self.md5 = md5
            self.source = source
            self.target = target
        }
    }
    struct CleanupEntry: Codable, Equatable {
        let canonical: String   // the new path that must exist before…
        let legacy: String      // …this old path may be removed
    }
    struct Safety: Codable, Equatable {
        let dfuGapBytes: Int?
        let minimumC2GapBytes: Int?
        let sectionGapBytes: Int?
        let updaterBytes: Int?
        let updaterLimitBytes: Int?
        enum CodingKeys: String, CodingKey {
            case dfuGapBytes = "dfu_gap_bytes"
            case minimumC2GapBytes = "minimum_c2_gap_bytes"
            case sectionGapBytes = "section_gap_bytes"
            case updaterBytes = "updater_bytes"
            case updaterLimitBytes = "updater_limit_bytes"
        }
    }

    struct PackageRelease: Codable, Equatable {
        let id: String
        let type: String
        let sourceCommit: String
        let sourceDirty: Bool
        let sourceFirmwareVersion: String
        let targetReleaseTag: String
        let firmwareFlashUnchanged: Bool
        /// Present only for the independent FW Packages catalog. Legacy package-only
        /// overlays were attached to (and named after) a firmware release; catalog
        /// releases have their own immutable tag and monotonically increasing revision.
        let catalogChannel: String?
        let catalogRevision: Int?
        let catalogReleaseTag: String?

        var isIndependentCatalog: Bool {
            catalogChannel != nil && catalogRevision != nil && catalogReleaseTag != nil
        }

        var independentCatalogMetadataIsPartial: Bool {
            let present = [
                catalogChannel != nil,
                catalogRevision != nil,
                catalogReleaseTag != nil,
            ].filter { $0 }.count
            return present != 0 && present != 3
        }

        init(
            id: String,
            type: String,
            sourceCommit: String,
            sourceDirty: Bool,
            sourceFirmwareVersion: String,
            targetReleaseTag: String,
            firmwareFlashUnchanged: Bool,
            catalogChannel: String? = nil,
            catalogRevision: Int? = nil,
            catalogReleaseTag: String? = nil
        ) {
            self.id = id
            self.type = type
            self.sourceCommit = sourceCommit
            self.sourceDirty = sourceDirty
            self.sourceFirmwareVersion = sourceFirmwareVersion
            self.targetReleaseTag = targetReleaseTag
            self.firmwareFlashUnchanged = firmwareFlashUnchanged
            self.catalogChannel = catalogChannel
            self.catalogRevision = catalogRevision
            self.catalogReleaseTag = catalogReleaseTag
        }

        enum CodingKeys: String, CodingKey {
            case id, type
            case sourceCommit = "source_commit"
            case sourceDirty = "source_dirty"
            case sourceFirmwareVersion = "source_firmware_version"
            case targetReleaseTag = "target_release_tag"
            case firmwareFlashUnchanged = "firmware_flash_unchanged"
            case catalogChannel = "catalog_channel"
            case catalogRevision = "catalog_revision"
            case catalogReleaseTag = "catalog_release_tag"
        }
    }

    init(
        schema: Int,
        releaseId: String,
        firmware: Firmware,
        artifacts: [String: Artifact],
        packages: [String: [PackageFile]],
        cleanup: [CleanupEntry],
        safety: Safety?,
        packageRelease: PackageRelease? = nil
    ) {
        self.schema = schema
        self.releaseId = releaseId
        self.firmware = firmware
        self.artifacts = artifacts
        self.packages = packages
        self.cleanup = cleanup
        self.safety = safety
        self.packageRelease = packageRelease
    }

    enum CodingKeys: String, CodingKey {
        case schema, firmware, artifacts, packages, cleanup, safety
        case releaseId = "release_id"
        case packageRelease = "package_release"
    }

    /// Canonical group order; also the complete set we require to be present.
    static let knownGroups = ["base", "arf", "module_one", "protocol_packs"]

    /// Decode without a global snake_case strategy — that would also rewrite the
    /// `packages` dictionary keys (`module_one` → `moduleOne`). Snake-case struct
    /// fields are mapped explicitly via CodingKeys instead.
    static func decode(_ data: Data) throws -> TumoflipManifest {
        try JSONDecoder().decode(TumoflipManifest.self, from: data)
    }
}

enum TumoflipManifestError: Error, Equatable {
    case unsupportedSchema(Int)
    case wrongTarget(expected: Int, got: Int)
    case emptyReleaseID
    case missingGroup(String)
    case invalidEntry(String)          // bad source / sha / size
    case unsafeTarget(String)          // traversal, non-/ext, malformed
    case duplicateTarget(String)
    case conflictingCleanup(String)
    case invalidPackageRelease(String)
}

extension TumoflipManifest {
    /// Validate the manifest's own integrity (schema, target, ids, group presence,
    /// per-entry fields). Does not yet sanitise paths — that happens when a concrete
    /// install plan is built from the user's group selection.
    func validate(expectedTarget: Int = 7) throws {
        guard schema == 2 else { throw TumoflipManifestError.unsupportedSchema(schema) }
        guard firmware.target == expectedTarget else {
            throw TumoflipManifestError.wrongTarget(expected: expectedTarget, got: firmware.target)
        }
        guard releaseId.count == 64, releaseId.allSatisfy(\.isHexDigit) else {
            throw TumoflipManifestError.emptyReleaseID
        }
        for g in Self.knownGroups where packages[g] == nil {
            throw TumoflipManifestError.missingGroup(g)
        }
        for (_, files) in packages {
            for f in files {
                guard f.bytes >= 0, !f.source.isEmpty,
                      f.sha256.count == 64, f.sha256.allSatisfy(\.isHexDigit),
                      f.md5.map({ $0.count == 32 && $0.allSatisfy {
                          "0123456789abcdef".contains($0)
                      } }) ?? true,
                      !f.target.isEmpty else {
                    throw TumoflipManifestError.invalidEntry(f.source.isEmpty ? f.target : f.source)
                }
            }
        }
        if let packageRelease {
            guard packageRelease.type == "package-only",
                  !packageRelease.id.isEmpty, packageRelease.id.utf8.count <= 160,
                  packageRelease.sourceCommit.count == 40,
                  packageRelease.sourceCommit.allSatisfy({
                      "0123456789abcdef".contains($0)
                  }),
                  packageRelease.sourceDirty == false,
                  !packageRelease.sourceFirmwareVersion.isEmpty,
                  packageRelease.sourceFirmwareVersion.utf8.count <= 80,
                  !packageRelease.targetReleaseTag.isEmpty,
                  packageRelease.targetReleaseTag.utf8.count <= 80,
                  packageRelease.firmwareFlashUnchanged else {
                throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
            }
            guard !packageRelease.independentCatalogMetadataIsPartial else {
                throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
            }
            if packageRelease.isIndependentCatalog {
                guard let channel = packageRelease.catalogChannel,
                      channel == TumoflipFirmwareChannel.stable.rawValue ||
                          channel == TumoflipFirmwareChannel.dev.rawValue,
                      let revision = packageRelease.catalogRevision,
                      (1...999).contains(revision),
                      packageRelease.catalogReleaseTag == String(
                          format: "fw-packages-%@-%03d", channel, revision
                      ) else {
                    throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                }
            }
        }
    }
}

/// A validated, path-sanitised set of files to install for a chosen group selection,
/// plus the cleanup entries that are safe to apply afterwards. Building one is the
/// only way targets get sanitised, so an install can never act on an unsafe path.
struct TumoflipInstallPlan: Equatable {
    let releaseId: String
    let groups: [String]                           // selected groups, canonical order
    let files: [TumoflipManifest.PackageFile]      // deduped, sanitised targets
    let cleanup: [TumoflipManifest.CleanupEntry]   // legacy paths safe to remove

    /// Deterministic identity of this exact plan: selected groups + every target and
    /// its content hash. Used for idempotency so installing Base then ARF for the same
    /// release are recognised as distinct transactions.
    var fingerprint: String {
        let g = groups.joined(separator: ",")
        let f = files.map { "\($0.target)=\($0.sha256)" }.sorted().joined(separator: ";")
        return TumoflipHash.sha256(Data("\(g)::\(f)".utf8))
    }

    /// Package installation and legacy cleanup are separate user transactions.
    /// Build the full validated plan first, then remove cleanup operations from the
    /// install transaction while keeping the same sanitised file selection.
    var installationOnly: TumoflipInstallPlan {
        TumoflipInstallPlan(
            releaseId: releaseId,
            groups: groups,
            files: files,
            cleanup: []
        )
    }

    /// Sanitise an `/ext` target path: must be absolute under `/ext/`, with no
    /// traversal (`..`), no `.` segments, and no empty components.
    static func sanitize(_ raw: String) throws -> String {
        let p = raw.trimmingCharacters(in: .whitespaces)
        guard p.hasPrefix("/ext/"), !p.contains("\0") else {
            throw TumoflipManifestError.unsafeTarget(raw)
        }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // comps[0] == "" (leading slash). Every later component must be non-empty,
        // not "." and not "..".
        for (i, c) in comps.enumerated() where i > 0 {
            guard !c.isEmpty, c != ".", c != ".." else { throw TumoflipManifestError.unsafeTarget(raw) }
        }
        return p
    }

    /// Build an install plan from the chosen groups. Throws on any unsafe target,
    /// duplicate target, or cleanup entry that conflicts with a file being installed.
    static func make(manifest: TumoflipManifest, groups: Set<String>,
                     excluding: Set<String> = []) throws -> TumoflipInstallPlan {
        var files: [TumoflipManifest.PackageFile] = []
        var seen = Set<String>()
        // Preserve a stable, canonical group order for deterministic install/journal.
        for g in TumoflipManifest.knownGroups where groups.contains(g) {
            for f in manifest.packages[g] ?? [] {
                // Per-file deselection (keyed on the raw manifest target, which is what
                // the UI toggles). Skipped files just aren't in this transaction; the plan
                // stays atomic over whatever remains.
                if excluding.contains(f.target) { continue }
                let safe = try sanitize(f.target)
                guard seen.insert(safe).inserted else {
                    throw TumoflipManifestError.duplicateTarget(safe)
                }
                files.append(TumoflipManifest.PackageFile(bytes: f.bytes, sha256: f.sha256, md5: f.md5,
                                                          source: f.source, target: safe))
            }
        }
        // Cleanup is only safe when its legacy path isn't itself something we're
        // installing, and the canonical replacement is part of this install.
        let targets = Set(files.map(\.target))
        var cleanup: [TumoflipManifest.CleanupEntry] = []
        var seenLegacy = Set<String>()
        for c in manifest.cleanup {
            let legacy = try sanitize(c.legacy)
            let canonical = try sanitize(c.canonical)
            guard !targets.contains(legacy) else { throw TumoflipManifestError.conflictingCleanup(legacy) }
            guard seenLegacy.insert(legacy).inserted else {
                throw TumoflipManifestError.conflictingCleanup(legacy)
            }
            // Only schedule cleanup whose replacement is actually being installed.
            if targets.contains(canonical) {
                cleanup.append(TumoflipManifest.CleanupEntry(canonical: canonical, legacy: legacy))
            }
        }
        let selected = TumoflipManifest.knownGroups.filter { groups.contains($0) }
        return TumoflipInstallPlan(releaseId: manifest.releaseId, groups: selected,
                                   files: files, cleanup: cleanup)
    }
}
