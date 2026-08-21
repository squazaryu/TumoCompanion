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
        /// Exact, content-addressed builds that are equivalent to the canonical ZIP
        /// payload. Independent catalogs use these when an accepted newer firmware
        /// release already contains the same package source built in a different
        /// linker invocation. Installation still always stages and verifies the
        /// canonical `sha256`/`md5` above.
        let compatibleBuilds: [CompatibleBuild]?
        let source: String
        let target: String

        struct CompatibleBuild: Codable, Equatable {
            let bytes: Int
            let sha256: String
            let md5: String
            let releaseId: String

            enum CodingKeys: String, CodingKey {
                case bytes, sha256, md5
                case releaseId = "release_id"
            }
        }

        struct BuildIdentity: Equatable {
            let bytes: Int
            let sha256: String
            let md5: String
        }

        init(
            bytes: Int,
            sha256: String,
            md5: String? = nil,
            compatibleBuilds: [CompatibleBuild]? = nil,
            source: String,
            target: String
        ) {
            self.bytes = bytes
            self.sha256 = sha256
            self.md5 = md5
            self.compatibleBuilds = compatibleBuilds
            self.source = source
            self.target = target
        }

        func acceptedBuild(matchingMD5 actual: String) -> BuildIdentity? {
            if md5 == actual {
                return BuildIdentity(bytes: bytes, sha256: sha256, md5: actual)
            }
            guard let build = compatibleBuilds?.first(where: { $0.md5 == actual }) else {
                return nil
            }
            return BuildIdentity(bytes: build.bytes, sha256: build.sha256, md5: build.md5)
        }

        func acceptsLedger(_ entry: TumoflipState.LedgerEntry) -> Bool {
            if md5 == nil {
                // Legacy manifests predate device-verifiable MD5 metadata. Preserve
                // their existing conservative ledger contract; compatible aliases
                // are intentionally unavailable for this less-trusted format.
                return entry.sha256 == sha256
            }
            return acceptedBuild(matchingMD5: entry.md5)?.sha256 == entry.sha256
        }

        enum CodingKeys: String, CodingKey {
            case bytes, sha256, md5, source, target
            case compatibleBuilds = "compatible_builds"
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
        enum CatalogInstallScope: String, Codable, Equatable {
            case delta
            case firmwareSnapshot
        }

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
        /// Producer-declared package surface. Delta releases manage only their
        /// cumulative source allowlist. Firmware snapshots manage every package in
        /// the manifest, but only on the exact firmware build they were copied from.
        let catalogInstallScope: CatalogInstallScope?
        let compatibleReleases: [CompatibleRelease]?
        /// Exact package archive sources changed by this independent catalog revision.
        /// Only these files are package-managed; every other entry is an immutable
        /// firmware baseline used to build and verify the release, not an install offer.
        let catalogModifiedTargets: [String]?
        /// Legacy name for the same package-owned source allowlist. Older immutable
        /// catalogs predate `catalog_modified_targets` but already carried this field.
        let overlayTargets: [String]?
        /// Exact firmware-release evidence emitted by the native publisher. Older
        /// snapshot releases predate `catalog_install_scope`; these fields let the
        /// client recognize that narrow legacy contract without treating an arbitrary
        /// empty overlay as a full install offer.
        let targetFirmwareCommit: String?
        let targetSourceCommit: String?
        let targetReleaseId: String?

        struct CompatibleRelease: Codable, Equatable {
            let releaseTag: String
            let releaseId: String
            let manifestSHA256: String
            let sourceCommit: String

            enum CodingKeys: String, CodingKey {
                case releaseTag = "release_tag"
                case releaseId = "release_id"
                case manifestSHA256 = "manifest_sha256"
                case sourceCommit = "source_commit"
            }
        }

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
            catalogReleaseTag: String? = nil,
            catalogInstallScope: CatalogInstallScope? = nil,
            compatibleReleases: [CompatibleRelease]? = nil,
            catalogModifiedTargets: [String]? = nil,
            overlayTargets: [String]? = nil,
            targetFirmwareCommit: String? = nil,
            targetSourceCommit: String? = nil,
            targetReleaseId: String? = nil
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
            self.catalogInstallScope = catalogInstallScope
            self.compatibleReleases = compatibleReleases
            self.catalogModifiedTargets = catalogModifiedTargets
            self.overlayTargets = overlayTargets
            self.targetFirmwareCommit = targetFirmwareCommit
            self.targetSourceCommit = targetSourceCommit
            self.targetReleaseId = targetReleaseId
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
            case catalogInstallScope = "catalog_install_scope"
            case compatibleReleases = "compatible_releases"
            case catalogModifiedTargets = "catalog_modified_targets"
            case overlayTargets = "overlay_targets"
            case targetFirmwareCommit = "target_firmware_commit"
            case targetSourceCommit = "target_source_commit"
            case targetReleaseId = "target_release_id"
        }

        func resolvedCatalogInstallScope(
            manifestFirmwareVersion: String
        ) -> CatalogInstallScope {
            if let catalogInstallScope { return catalogInstallScope }
            return hasLegacyFirmwareSnapshotIdentity(
                manifestFirmwareVersion: manifestFirmwareVersion
            ) ? .firmwareSnapshot : .delta
        }

        func hasFirmwareSnapshotIdentity(
            manifestFirmwareVersion: String
        ) -> Bool {
            guard catalogChannel == TumoflipFirmwareChannel.stable.rawValue,
                  sourceFirmwareVersion == manifestFirmwareVersion,
                  overlayTargets?.isEmpty == true,
                  catalogModifiedTargets == nil,
                  compatibleReleases?.isEmpty != false,
                  let targetFirmwareCommit,
                  let targetSourceCommit,
                  targetFirmwareCommit == sourceCommit,
                  targetSourceCommit == sourceCommit,
                  let targetReleaseId,
                  targetReleaseId.count == 64,
                  targetReleaseId.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return false
            }
            return true
        }

        private func hasLegacyFirmwareSnapshotIdentity(
            manifestFirmwareVersion: String
        ) -> Bool {
            catalogInstallScope == nil && hasFirmwareSnapshotIdentity(
                manifestFirmwareVersion: manifestFirmwareVersion
            )
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

    /// Return the files that this independent catalog is allowed to manage on the
    /// device. Delta catalogs expose only their automation-owned allowlist. An exact
    /// firmware snapshot intentionally exposes its complete package surface; catalog
    /// selection and install compatibility gate that surface to the source firmware.
    func packageManagedManifest() -> TumoflipManifest {
        guard let allowed = independentDeltaSources else {
            return self
        }
        let filteredPackages = packages.mapValues { files in
            files.filter { allowed.contains($0.source) }
        }
        let managedTargets = Set(filteredPackages.values.flatMap { $0.map(\.target) })
        return TumoflipManifest(
            schema: schema,
            releaseId: releaseId,
            firmware: firmware,
            artifacts: artifacts,
            packages: filteredPackages,
            cleanup: cleanup.filter { managedTargets.contains($0.canonical) },
            safety: safety,
            packageRelease: packageRelease
        )
    }

    /// The two distinct surfaces carried by an independent catalog delta.
    ///
    /// A catalog asset contains a complete source manifest so its immutable
    /// provenance can be verified. Only the producer-declared allowlist is an
    /// install offer. The complement is a firmware-owned reference surface: useful
    /// for explaining the package layout, but never eligible for an SD write from
    /// FW Packages. Keeping the distinction in the model prevents the UI from
    /// presenting a safe empty install surface as misleading `0/0` groups.
    struct PackageSurface: Equatable {
        let managed: TumoflipManifest
        let firmwareOwned: [String: [PackageFile]]

        var firmwareOwnedFileCount: Int {
            firmwareOwned.values.reduce(0) { $0 + $1.count }
        }

        func firmwareOwnedFiles(in group: String) -> [PackageFile] {
            firmwareOwned[group] ?? []
        }
    }

    /// Returns the separately-presented firmware-owned baseline for a delta. Exact
    /// firmware snapshots and old firmware-bound manifests intentionally have no
    /// split surface: their complete manifest is the install surface.
    func packageSurface() -> PackageSurface {
        let managed = packageManagedManifest()
        guard let allowed = independentDeltaSources else {
            return PackageSurface(managed: managed, firmwareOwned: [:])
        }
        return PackageSurface(
            managed: managed,
            firmwareOwned: packages.mapValues { files in
                files.filter { !allowed.contains($0.source) }
            }
        )
    }

    private var independentDeltaSources: Set<String>? {
        guard let release = packageRelease,
              release.isIndependentCatalog,
              release.resolvedCatalogInstallScope(
                  manifestFirmwareVersion: firmware.version
              ) == .delta else {
            return nil
        }
        return Set(release.catalogModifiedTargets ?? release.overlayTargets ?? [])
    }

    var isFirmwareSnapshotCatalog: Bool {
        guard let release = packageRelease, release.isIndependentCatalog else {
            return false
        }
        return release.resolvedCatalogInstallScope(
            manifestFirmwareVersion: firmware.version
        ) == .firmwareSnapshot
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
        var referencedCompatibleReleaseIDs = Set<String>()
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
                if let builds = f.compatibleBuilds {
                    guard !builds.isEmpty, builds.count <= 8, f.md5 != nil else {
                        throw TumoflipManifestError.invalidEntry(f.source)
                    }
                    var compatibleMD5s = Set<String>()
                    for build in builds {
                        guard build.bytes >= 0,
                              build.sha256.count == 64,
                              build.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                              build.md5.count == 32,
                              build.md5.allSatisfy({ "0123456789abcdef".contains($0) }),
                              build.releaseId.count == 64,
                              build.releaseId.allSatisfy({ "0123456789abcdef".contains($0) }),
                              build.sha256 != f.sha256,
                              build.md5 != f.md5,
                              compatibleMD5s.insert(build.md5).inserted else {
                            throw TumoflipManifestError.invalidEntry(f.source)
                        }
                        referencedCompatibleReleaseIDs.insert(build.releaseId)
                    }
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
                let releases = packageRelease.compatibleReleases ?? []
                guard releases.count <= 8 else {
                    throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                }
                var releaseIDs = Set<String>()
                var releaseTags = Set<String>()
                for release in releases {
                    let prefix = "fw-packages-\(channel)-"
                    let revisionText = String(release.releaseTag.dropFirst(prefix.count))
                    guard release.releaseTag.hasPrefix(prefix),
                          revisionText.count == 3,
                          let compatibleRevision = Int(revisionText),
                          compatibleRevision >= 1,
                          compatibleRevision < revision,
                          release.releaseTag == String(
                              format: "fw-packages-%@-%03d", channel, compatibleRevision
                          ),
                          release.releaseId.count == 64,
                          release.releaseId.allSatisfy({ "0123456789abcdef".contains($0) }),
                          release.releaseId != releaseId,
                          release.manifestSHA256.count == 64,
                          release.manifestSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
                          release.sourceCommit.count == 40,
                          release.sourceCommit.allSatisfy({ "0123456789abcdef".contains($0) }),
                          releaseIDs.insert(release.releaseId).inserted,
                          releaseTags.insert(release.releaseTag).inserted else {
                        throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                    }
                }
                guard referencedCompatibleReleaseIDs == releaseIDs else {
                    throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                }
                let resolvedScope = packageRelease.resolvedCatalogInstallScope(
                    manifestFirmwareVersion: firmware.version
                )
                if resolvedScope == .firmwareSnapshot {
                    guard packageRelease.hasFirmwareSnapshotIdentity(
                        manifestFirmwareVersion: firmware.version
                    ) else {
                        throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                    }
                } else if packageRelease.catalogInstallScope == .delta {
                    let delta = packageRelease.catalogModifiedTargets ??
                        packageRelease.overlayTargets ?? []
                    guard !delta.isEmpty else {
                        throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                    }
                }
                for modified in [
                    packageRelease.catalogModifiedTargets,
                    packageRelease.overlayTargets,
                ].compactMap({ $0 }) {
                    let allSources = packages.values.flatMap { $0.map(\.source) }
                    let knownSources = Set(allSources)
                    guard modified.count <= allSources.count,
                          modified.count == Set(modified).count,
                          modified.allSatisfy({ source in
                              !source.hasPrefix("/") &&
                                  !source.contains("\\") &&
                                  !source.split(
                                      separator: "/",
                                      omittingEmptySubsequences: false
                                  ).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) &&
                                  knownSources.contains(source)
                          }) else {
                        throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                    }
                }
                if let modified = packageRelease.catalogModifiedTargets,
                   let overlays = packageRelease.overlayTargets,
                   !Set(modified).isSubset(of: Set(overlays)) {
                    throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                }
            } else if !referencedCompatibleReleaseIDs.isEmpty ||
                        packageRelease.compatibleReleases?.isEmpty == false ||
                        packageRelease.catalogModifiedTargets != nil ||
                        packageRelease.overlayTargets != nil {
                throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
            }
        } else if !referencedCompatibleReleaseIDs.isEmpty {
            throw TumoflipManifestError.invalidEntry("compatible_builds")
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
                files.append(TumoflipManifest.PackageFile(
                    bytes: f.bytes,
                    sha256: f.sha256,
                    md5: f.md5,
                    compatibleBuilds: f.compatibleBuilds,
                    source: f.source,
                    target: safe
                ))
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
