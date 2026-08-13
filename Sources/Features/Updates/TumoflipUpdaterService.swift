import Foundation
import ZIPFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Real device FS adapter (FlipperStorage)

/// Bridges `TumoflipDeviceFS` to the live Flipper over RPC.
struct FlipperDeviceFS: TumoflipDeviceFS {
    let storage = FlipperStorage()

    func write(_ data: Data, to path: String) async throws { try await storage.write(path, data: data) }
    func write(
        _ data: Data,
        to path: String,
        progress: (@Sendable (Int) -> Void)?,
        isStopRequested: @escaping @Sendable () -> Bool
    ) async throws {
        try await storage.write(
            path,
            data: data,
            progress: progress,
            isStopRequested: isStopRequested
        )
    }
    func read(_ path: String) async -> Data? { try? await storage.read(path) }
    func deviceMD5(_ path: String) async -> String? { await storage.md5(path) }
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        // A large FAP can keep the Flipper busy hashing SD data for longer than the
        // ordinary 20-second metadata timeout. This is only a ceiling; fast hashes
        // still return immediately.
        try await storage.checkedMD5(path, timeout: 60)
    }
    func fileSize(_ path: String) async -> Int? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let files = try? await storage.list(directory),
              let file = files.first(where: { $0.name == name }) else { return nil }
        return Int(file.size)
    }
    func move(_ from: String, to: String) async throws { try await storage.move(from, to: to) }
    func delete(_ path: String) async throws { try await storage.delete(path, recursive: false) }
    func deleteTree(_ path: String) async throws { try await storage.delete(path, recursive: true) }
    func exists(_ path: String) async -> Bool { await storage.exists(path) }

    /// Recursive: create every missing ancestor (FlipperStorage.makeDirectory tolerates
    /// an existing directory), so nested staging/rollback paths come into being.
    func makeDirectory(_ path: String) async throws {
        var cur = ""
        for c in path.split(separator: "/") {
            cur += "/\(c)"
            try await storage.makeDirectory(cur)
        }
    }

}

/// USB-backed filesystem adapter. The user first selects the Flipper SD card in
/// Files, then package files are written directly into that mounted SD folder.
struct USBTumoflipDeviceFS: TumoflipDeviceFS {
    let storage: USBSDStorage

    func write(_ data: Data, to path: String) async throws { try await storage.write(path, data: data) }
    func write(
        _ data: Data,
        to path: String,
        progress: (@Sendable (Int) -> Void)?,
        isStopRequested: @escaping @Sendable () -> Bool
    ) async throws {
        try await storage.write(
            path,
            data: data,
            progress: progress,
            isStopRequested: isStopRequested
        )
    }
    func read(_ path: String) async -> Data? { try? await storage.read(path) }
    func deviceMD5(_ path: String) async -> String? { await storage.md5(path) }
    func checkedDeviceMD5(_ path: String) async throws -> String? {
        guard await storage.exists(path) else { return nil }
        let data = try await storage.read(path)
        return TumoflipHash.md5(data)
    }
    func fileSize(_ path: String) async -> Int? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let files = try? await storage.list(directory),
              let file = files.first(where: { $0.name == name }) else { return nil }
        return Int(file.size)
    }
    func move(_ from: String, to: String) async throws { try await storage.move(from, to: to) }
    func delete(_ path: String) async throws { try await storage.delete(path, recursive: false) }
    func deleteTree(_ path: String) async throws { try await storage.delete(path, recursive: true) }
    func exists(_ path: String) async -> Bool { await storage.exists(path) }

    func makeDirectory(_ path: String) async throws {
        var cur = ""
        for c in path.split(separator: "/") {
            cur += "/\(c)"
            try await storage.makeDirectory(cur)
        }
    }
}

// MARK: - Zip-backed package source

/// Package bytes pre-extracted from the release `tumoflip-packages.zip`, keyed by the
/// manifest `source` path (the zip entry paths match the manifest exactly).
struct ZipPackageSource: TumoflipPackageSource {
    let entries: [String: Data]
    func bytes(for source: String) async throws -> Data {
        guard let d = entries[source] else { throw TumoflipInstallError.sourceMissing(source) }
        return d
    }

    /// Read every entry of a downloaded package zip into memory.
    static func load(zipAt url: URL) throws -> ZipPackageSource {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw TumoflipInstallError.sourceMissing("zip")
        }
        var out: [String: Data] = [:]
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            out[entry.path] = data
        }
        return ZipPackageSource(entries: out)
    }
}

// MARK: - Service / view-model

/// One service owns both FW Packages mutations. The SwiftUI button becoming disabled is
/// not a synchronization primitive: `install()` performs several awaited compatibility
/// checks before staging, so a second task can otherwise enter and queue another write of
/// the same `.ucnew` file. Keep the gate on the main actor and acquire it before the first
/// suspension point.
@MainActor
final class TumoflipTransactionGate {
    private(set) var isActive = false

    func begin() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    func end() {
        isActive = false
    }
}

@MainActor
final class TumoflipUpdater: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, ready, downloading
        case installing(done: Int, total: Int, file: String)
        case cleaning(done: Int, total: Int, file: String)
        case done(String), failed(String)
    }

    struct CleanupSelection: Equatable {
        let groups: Set<String>
        let entries: [TumoflipManifest.CleanupEntry]
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var manifest: TumoflipManifest?
    @Published private(set) var releaseTag = ""
    @Published private(set) var packageRevisionDate: Date?
    @Published private(set) var hasPackageZip = false
    @Published private(set) var groupStatus: [String: TumoflipInstaller.GroupStatus] = [:]
    @Published private(set) var fileStatus: [String: TumoflipInstaller.FileStatus] = [:]
    @Published private(set) var pendingCleanup: [String: [TumoflipManifest.CleanupEntry]] = [:]
    @Published private(set) var transferChannel: TransferChannel = .ble
    @Published private(set) var deviceIdentity: TumoflipDeviceIdentity?
    @Published private(set) var firmwareRoute = TumoflipFirmwareRouter.route(identity: nil, manualOverride: nil)
    @Published private(set) var manualChannelOverride: TumoflipFirmwareChannel?
    /// Per-file deselection (raw manifest targets). Empty = install everything; a
    /// target here is skipped. Exclusion-based so the default (all selected) needs no
    /// manifest at init.
    @Published var excludedFiles: Set<String> = []

    /// FAP/FAL files whose embedded `.fapmeta` is incompatible with the connected
    /// firmware (target → concise reason). Populated by `validateCompatibility()` and
    /// re-checked fail-closed at install; the install action is disabled while any
    /// selected file appears here (issue #19).
    @Published private(set) var blocked: [String: String] = [:]
    @Published private(set) var validating = false
    @Published private(set) var compatibilityApiMajor: Int?
    @Published private(set) var compatibilityTarget: Int?
    @Published private(set) var compatibilityChecked = false
    @Published private(set) var compatibilityIdentityFailure: String?

    /// The last downloaded package zip, cached by content-addressed release id so a
    /// package-only asset replacement under the same firmware tag cannot reuse stale bytes.
    private var cachedSource: (releaseId: String, source: ZipPackageSource)?
    private let transactionGate = TumoflipTransactionGate()

    private var packageZipURL: URL?
    private var selectedCatalogIdentity: TumoflipPackageCatalogSelection.Identity?
    private var selectedCatalogRepository: TumoflipPackageCatalogRepository?
    private let packageCatalogClient: TumoflipPackageCatalogClient

    init(packageCatalogClient: TumoflipPackageCatalogClient = .live()) {
        self.packageCatalogClient = packageCatalogClient
    }

    // Keep the screen awake and hold a background-task assertion for the duration of a
    // BLE install/recovery. The transaction can run for minutes; if the phone auto-locks
    // or the app is briefly backgrounded mid-flight, iOS tears down BLE and the half-applied
    // transaction can't be verified/rolled back over the dead link. These guards prevent that.
    #if canImport(UIKit)
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    private func beginTransactionGuards() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "tumoflip-transaction") { [weak self] in
            self?.endTransactionGuards()
        }
        #endif
    }

    private func endTransactionGuards() {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        #endif
    }

    var busy: Bool {
        if transactionGate.isActive { return true }
        if validating { return true }
        switch phase {
        case .checking, .downloading, .installing, .cleaning:
            return true
        default:
            return false
        }
    }

    var packageRevision: String {
        guard let manifest else { return "Unknown" }
        if let release = manifest.packageRelease,
           let channel = release.catalogChannel,
           let revision = release.catalogRevision {
            return String(
                format: "%@ %03d · %@",
                channel.capitalized,
                revision,
                String(release.sourceCommit.prefix(10))
            )
        }
        let identity = manifest.packageRelease?.sourceCommit ?? manifest.releaseId
        return String(identity.prefix(10))
    }

    var firmwareFlashUnchanged: Bool {
        manifest?.packageRelease?.firmwareFlashUnchanged == true
    }

    var shouldLoadManifest: Bool {
        if case .idle = phase { return manifest == nil }
        return false
    }

    func status(_ group: String) -> TumoflipInstaller.GroupStatus { groupStatus[group] ?? .empty }
    func status(file target: String) -> TumoflipInstaller.FileStatus {
        fileStatus[target] ?? .unknown
    }
    func cleanupEntries(_ group: String) -> [TumoflipManifest.CleanupEntry] {
        pendingCleanup[group] ?? []
    }

    nonisolated static func cleanupSelection(
        from pending: [String: [TumoflipManifest.CleanupEntry]]
    ) -> CleanupSelection {
        let groups = Set(TumoflipManifest.knownGroups.filter {
            pending[$0]?.isEmpty == false
        })
        let entries = TumoflipManifest.knownGroups.flatMap { pending[$0] ?? [] }
        return CleanupSelection(groups: groups, entries: entries)
    }

    var cleanupFileCount: Int {
        Self.cleanupSelection(from: pendingCleanup).entries.count
    }

    func setManualChannelOverride(_ channel: TumoflipFirmwareChannel) {
        manualChannelOverride = channel
        firmwareRoute = TumoflipFirmwareRouter.route(identity: deviceIdentity, manualOverride: manualChannelOverride)
    }

    func clearManualChannelOverride() {
        manualChannelOverride = nil
        firmwareRoute = TumoflipFirmwareRouter.route(identity: deviceIdentity, manualOverride: nil)
    }

    /// Overall badge: any installed group out of date → Update; else any up to date → Up
    /// to date; else nothing installed.
    var overallStatus: TumoflipInstaller.GroupStatus {
        let values = groupStatus.values
        if values.contains(.updateAvailable) { return .updateAvailable }
        if values.contains(.upToDate) { return .upToDate }
        return .notInstalled
    }

    /// Compare the durable ledger to the latest manifest and, when the manifest has
    /// expected MD5s, safely adopt complete firmware-bundled groups from the device.
    func refreshStatus() async {
        guard let manifest else { return }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do {
            let snapshot = try await inst.reconcilePackageStatus(manifest: manifest)
            groupStatus = snapshot.groups
            fileStatus = snapshot.files
            pendingCleanup = snapshot.pendingCleanup
        } catch {
            // Preserve the conservative ledger snapshot if device verification or
            // reconciliation persistence is unavailable.
            let ledger = (try? await inst.currentLedger()) ?? [:]
            groupStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups.map {
                ($0, TumoflipInstaller.groupStatus(for: $0, manifest: manifest, ledger: ledger))
            })
            fileStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups
                .flatMap { files($0) }
                .map { ($0.target, TumoflipInstaller.FileStatus.validationError) })
            pendingCleanup = [:]
        }
        lastVerifiedOnDevice = false
    }

    @Published private(set) var verifying = false
    /// True when `groupStatus` was last computed by hashing the actual files on the
    /// Flipper (deviceMD5), not just from the ledger snapshot.
    @Published private(set) var lastVerifiedOnDevice = false

    /// On-demand deep check: hash every recorded target on the Flipper and compare to
    /// the ledger, so the badges reflect the ACTUAL SD contents (catches files deleted
    /// or changed outside the app). Needs a connected Flipper; slower than `refreshStatus`.
    func verifyOnDevice() async {
        guard let manifest else { return }
        verifying = true
        defer { verifying = false }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do {
            let snapshot = try await inst.reconcilePackageStatus(manifest: manifest)
            groupStatus = snapshot.groups
            fileStatus = snapshot.files
            pendingCleanup = snapshot.pendingCleanup
            lastVerifiedOnDevice = !snapshot.files.values.contains(.validationError)
        } catch {
            fileStatus = Dictionary(uniqueKeysWithValues: TumoflipManifest.knownGroups
                .flatMap { files($0) }
                .map { ($0.target, TumoflipInstaller.FileStatus.validationError) })
            pendingCleanup = [:]
            lastVerifiedOnDevice = false
        }
    }

    func count(_ group: String) -> Int { manifest?.packages[group]?.count ?? 0 }
    func bytes(_ group: String) -> Int { (manifest?.packages[group] ?? []).reduce(0) { $0 + $1.bytes } }
    func files(_ group: String) -> [TumoflipManifest.PackageFile] { manifest?.packages[group] ?? [] }

    // MARK: - Per-file selection

    func isFileSelected(_ target: String) -> Bool {
        !excludedFiles.contains(target) && blocked[target] == nil
    }

    func isFileBlocked(_ target: String) -> Bool { blocked[target] != nil }

    func setFile(_ target: String, selected: Bool) {
        if selected {
            guard blocked[target] == nil else { return }
            excludedFiles.remove(target)
        } else {
            excludedFiles.insert(target)
        }
    }

    /// How many files in a group are currently selected (not excluded).
    func selectedCount(_ group: String) -> Int {
        files(group).lazy.filter { self.isFileSelected($0.target) }.count
    }

    func selectableCount(_ group: String) -> Int {
        files(group).lazy.filter { self.blocked[$0.target] == nil }.count
    }

    /// Select/deselect every file in a group at once (the group header checkbox).
    func setGroup(_ group: String, selected: Bool) {
        let targets = files(group).map(\.target)
        if selected {
            excludedFiles.subtract(targets.filter { blocked[$0] == nil })
        } else {
            excludedFiles.formUnion(targets)
        }
    }

    /// Total selected files across all groups. This is selection state only; install
    /// actions use `selectedPendingFileCount` so current files are never staged again.
    var selectedFileCount: Int {
        TumoflipManifest.knownGroups.reduce(0) { $0 + selectedCount($1) }
    }

    private var selectedTargets: Set<String> {
        Set(TumoflipManifest.knownGroups.flatMap { group in
            self.files(group).lazy.filter { self.isFileSelected($0.target) }.map(\.target)
        })
    }

    nonisolated static func pendingInstallTargets(
        selected: Set<String>,
        statuses: [String: TumoflipInstaller.FileStatus]
    ) -> Set<String> {
        selected.filter { statuses[$0] != .upToDate }
    }

    /// Selected files that still require an action according to the latest device
    /// reconciliation. Up-to-date files remain selected in the UI but are never
    /// counted or staged again.
    var selectedPendingFileCount: Int {
        Self.pendingInstallTargets(selected: selectedTargets, statuses: fileStatus).count
    }

    var selectedRequiresCompatibilityIdentity: Bool {
        let pending = Self.pendingInstallTargets(
            selected: selectedTargets,
            statuses: fileStatus
        )
        return TumoflipManifest.knownGroups.contains { group in
            self.files(group).contains {
                pending.contains($0.target) && FapCompatibility.isBinary($0.target)
            }
        }
    }

    var hasFreshCompatibilityIdentity: Bool {
        compatibilityApiMajor != nil && compatibilityTarget != nil
    }

    var hasUnvalidatedBinaries: Bool {
        blocked.values.contains(FapCompatibility.unknownDeviceReason)
    }

    /// Combined entry/refresh used by the view. Sets `.checking` up front so the spinner
    /// shows instantly — even while the slower device-recover step runs (which otherwise
    /// left the phase untouched, so the screen looked frozen) — then fetches the release.
    func reload(recover: Bool) async {
        phase = .checking
        if recover { await recoverIfNeeded() }
        if case .failed = phase { return }   // recover surfaced a real install error → stop here
        await check()
    }

    /// Discover the latest tumoflip release, decode + validate its manifest, and note
    /// whether the install archive is published.
    func check() async {
        phase = .checking
        do {
            await refreshRoutingIdentity()
            let selection = try await packageCatalogClient.latest(
                for: firmwareRoute.channel,
                installedVersion: packageIdentityVersion
            )
            let m = selection.manifest
            try m.validate()
            if let packageRelease = m.packageRelease {
                let declaredReleaseTag = packageRelease.isIndependentCatalog
                    ? packageRelease.catalogReleaseTag
                    : packageRelease.targetReleaseTag
                guard declaredReleaseTag == selection.release.tag else {
                    throw TumoflipManifestError.invalidPackageRelease(packageRelease.id)
                }
            }
            releaseTag = selection.release.tag
            selectedCatalogIdentity = selection.identity
            selectedCatalogRepository = selection.release.repository
            packageRevisionDate = selection.manifestUpdatedAt
            manifest = m
            packageZipURL = selection.release.asset("tumoflip-packages.zip")?.url
            hasPackageZip = packageZipURL != nil
            await refreshStatus()
            phase = .ready
            // FAP/FAL API validation needs the package zip; it's triggered from the FW
            // Packages detail screen (where the user installs) rather than here, so just
            // opening the Updates overview doesn't force a package download.
        } catch {
            if UpdateTaskCancellation.isCancellation(error) {
                phase = manifest == nil ? .idle : .ready
                return
            }
            phase = .failed(friendly(error))
        }
    }

    /// Download the package zip, check device compatibility, stage + verify + atomically
    /// activate the selected groups onto the Flipper, rolling back on any failure.
    /// Set by the Stop button. Install and cleanup poll this only at safe operation
    /// boundaries; either transaction rolls back to the prior working state.
    @Published private(set) var stopRequested = false
    private let stopToken = StopToken()
    func requestStop() { stopRequested = true; stopToken.stop() }

    func install() async {
        guard let manifest, packageZipURL != nil else { return }
        // Disable the action and reject any overlapping invocation synchronously,
        // before compatibility/network awaits can yield back to a still-enabled UI.
        guard transactionGate.begin() else { return }
        defer { transactionGate.end() }
        stopRequested = false; stopToken.reset()
        var activityTotal = max(1, selectedPendingFileCount * 200)
        phase = .installing(done: 0, total: activityTotal, file: "Preparing…")
        beginTransactionGuards()
        defer { endTransactionGuards() }
        let live = InstallActivityController()
        do {
            let selectedTargets = self.selectedTargets
            guard !selectedTargets.isEmpty else {
                phase = .failed("No files selected.")
                return
            }

            // Compare the connected Flipper with the manifest before touching the SD.
            let channel = activeChannel
            let fs = activeFS()
            transferChannel = channel
            // USB only changes the file-transfer path. A fresh BLE identity remains
            // mandatory so a stale manifest can never be installed after a firmware
            // update merely because its FAP API still matches.
            guard await FlipperBLE.shared.waitUntilReady(timeout: 8) else {
                phase = .failed("Connect this Flipper over BLE to validate its current firmware before installing packages via \(channel.label).")
                return
            }
            if FlipperBLE.shared.buddyMode {
                phase = .failed("Claude Buddy passthrough is holding the serial link. Turn Claude Buddy off in Settings (or exit the Buddy app on the Flipper), then retry.")
                return
            }
            try await checkCompatibility(manifest)

            guard let selectedCatalogIdentity, let selectedCatalogRepository else {
                phase = .failed("Refresh Firmware packages before installing; catalog identity is unavailable.")
                return
            }
            let liveSelection = try await packageCatalogClient.latest(
                for: firmwareRoute.channel,
                installedVersion: packageIdentityVersion,
                forceRemote: true,
                requiredRepository: selectedCatalogRepository
            )
            guard liveSelection.identity == selectedCatalogIdentity,
                  liveSelection.manifest == manifest else {
                phase = .failed("The package release changed after this screen loaded. Refresh Firmware packages before installing; nothing was changed.")
                return
            }

            // Re-check only files currently known to need an install. The screen's full
            // reconciliation already verified the other selected files; hashing all 94
            // again would turn a one-FAP update into another long package scan. Any
            // transport error still fails before download or SD writes.
            let pendingTargets = Self.pendingInstallTargets(
                selected: selectedTargets,
                statuses: fileStatus
            )
            guard !pendingTargets.isEmpty else {
                phase = .done("Already installed — nothing to do.")
                return
            }
            let statusInstaller = TumoflipInstaller(
                fs: fs,
                source: ZipPackageSource(entries: [:])
            )
            let refreshedStatuses = try await statusInstaller.verifyPackageTargets(
                pendingTargets,
                manifest: manifest
            )
            fileStatus.merge(refreshedStatuses) { _, refreshed in refreshed }
            lastVerifiedOnDevice = true
            let requestedTargets = Self.pendingInstallTargets(
                selected: pendingTargets,
                statuses: refreshedStatuses
            )
            guard !requestedTargets.isEmpty else {
                phase = .done("Already installed — nothing to do.")
                return
            }

            phase = .downloading
            let source = try await packageSource()
            if stopToken.isStopped { throw TumoflipInstallError.cancelled }

            // Issue #19: reject any selected FAP/FAL whose embedded `.fapmeta` is
            // incompatible with the CONNECTED firmware. Read fresh device_info now and
            // gate BEFORE ensureLoaderIdle / staging / backup / cleanup, so nothing is
            // written for a rejected binary. Non-FAP data files keep their SHA/size checks.
            let (devApi, devTarget) = try await deviceApiTarget()
            compatibilityApiMajor = devApi
            compatibilityTarget = devTarget
            compatibilityChecked = true
            blocked = PackageCompatibilityGate.blocked(
                fapCandidates(source, groups: Set(TumoflipManifest.knownGroups)),
                deviceApiMajor: devApi, deviceTarget: devTarget)
            let hits = blocked.filter { requestedTargets.contains($0.key) }
            if !hits.isEmpty {
                phase = .failed(PackageCompatibilityGate.summary(hits))
                return
            }

            let allTargets = Set(TumoflipManifest.knownGroups.flatMap { group in
                self.files(group).map(\.target)
            })
            let effectiveExclusions = allTargets
                .subtracting(requestedTargets)
                .union(blocked.keys)
            let groups = Set(TumoflipManifest.knownGroups.filter { group in
                self.files(group).contains { requestedTargets.contains($0.target) }
            })
            let plan = try TumoflipInstallPlan.make(
                manifest: manifest,
                groups: groups,
                excluding: effectiveExclusions
            ).installationOnly
            guard !plan.files.isEmpty else { phase = .failed("No compatible files selected."); return }
            activityTotal = 200 * plan.files.count

            // A running external app may keep its own FAP open. Stop it before any
            // live path is backed up or replaced, and fail closed if Loader remains
            // locked. Core BLE/RPC stays available after the external app exits.
            if channel == .ble {
                try await ensureLoaderIdle()
            }

            phase = .installing(done: 0, total: activityTotal, file: "Starting…")
            live.start(total: activityTotal, title: "Installing firmware packages")
            let transferReporter = TransferActivityReporter(channel: channel)
            _ = await transferReporter.prepare()
            transferReporter.begin("firmware packages")
            defer { transferReporter.end() }
            let installer = TumoflipInstaller(fs: fs, source: source)
            let outcome = try await installer.install(
                plan, isStopRequested: { [stopToken] in stopToken.isStopped }
            ) { [weak self] done, total, file in
                Task { @MainActor in
                    self?.phase = .installing(done: done, total: total, file: file)
                    live.update(current: done, total: total, detail: file)
                    transferReporter.progress(file)
                }
            }
            try await installer.refreshCompatibilityState(manifest: manifest, plan: plan)
            switch outcome {
            case .alreadyInstalled:
                phase = .done("Already installed — nothing to do.")
                live.succeed(
                    completed: activityTotal,
                    total: activityTotal,
                    detail: "Already installed"
                )
            case let .installed(files, _):
                phase = .done("Installed \(files) file\(files == 1 ? "" : "s").")
                live.succeed(
                    completed: activityTotal,
                    total: activityTotal,
                    detail: "Firmware packages installed"
                )
            }
            await refreshStatus()
        } catch TumoflipInstallError.cancelled {
            // Stop requested: the transaction rolled back, so the device is exactly as
            // before — every prior version intact and fully functional.
            phase = .done("Stopped — rolled back to the previous version, nothing changed.")
            live.stop(
                completed: 0,
                total: activityTotal,
                detail: "Rolled back"
            )
            await refreshStatus()
        } catch let e as TumoflipInstallError {
            phase = .failed(installErrorText(e))
            live.fail(
                completed: 0,
                total: activityTotal,
                detail: installErrorText(e)
            )
            await refreshStatus()
        } catch {
            phase = .failed(friendly(error))
            live.fail(
                completed: 0,
                total: activityTotal,
                detail: friendly(error)
            )
            await refreshStatus()
        }
    }

    /// Remove every currently pending legacy duplicate in one standalone transaction,
    /// without downloading the package archive or reinstalling a canonical FAP.
    func cleanUpPending() async {
        guard let manifest else { return }
        let selection = Self.cleanupSelection(from: pendingCleanup)
        guard !selection.entries.isEmpty else {
            phase = .done("No legacy files remain.")
            return
        }

        // Installation and cleanup mutate the same package paths and journal. They
        // share one gate so neither transaction can begin while the other is awaiting
        // a BLE/RPC response.
        guard transactionGate.begin() else { return }
        defer { transactionGate.end() }
        stopRequested = false
        stopToken.reset()
        phase = .cleaning(
            done: 0,
            total: max(1, selection.entries.count),
            file: "Preparing…"
        )
        beginTransactionGuards()
        defer { endTransactionGuards() }
        let live = InstallActivityController()
        let channel = activeChannel
        let fs = activeFS()
        transferChannel = channel

        do {
            guard await FlipperBLE.shared.waitUntilReady(timeout: 8) else {
                phase = .failed(
                    "Connect this Flipper over BLE to validate its firmware before cleanup.")
                return
            }
            if FlipperBLE.shared.buddyMode {
                phase = .failed(
                    "Claude Buddy passthrough is holding the serial link. Turn Claude Buddy off, then retry.")
                return
            }
            try await checkCompatibility(manifest)

            let fullPlan = try TumoflipInstallPlan.make(
                manifest: manifest,
                groups: selection.groups
            )
            let pendingLegacyPaths = Set(selection.entries.map(\.legacy))
            let plan = TumoflipInstallPlan(
                releaseId: fullPlan.releaseId,
                groups: fullPlan.groups,
                files: fullPlan.files,
                cleanup: fullPlan.cleanup.filter {
                    pendingLegacyPaths.contains($0.legacy)
                }
            )
            guard !plan.cleanup.isEmpty else {
                phase = .done("No legacy files remain.")
                await refreshStatus()
                return
            }
            if channel == .ble {
                try await ensureLoaderIdle()
            }

            phase = .cleaning(done: 0, total: selection.entries.count, file: "Starting…")
            live.start(total: selection.entries.count, title: "Cleaning firmware packages")
            let transferReporter = TransferActivityReporter(channel: channel)
            _ = await transferReporter.prepare()
            transferReporter.begin("firmware package cleanup")
            defer { transferReporter.end() }

            let installer = TumoflipInstaller(
                fs: fs,
                source: ZipPackageSource(entries: [:])
            )
            let removed = try await installer.cleanupLegacy(
                plan,
                isStopRequested: { [stopToken] in stopToken.isStopped }
            ) {
                [weak self] done, total, file in
                Task { @MainActor in
                    self?.phase = .cleaning(done: done, total: total, file: file)
                    live.update(current: done, total: total, detail: file)
                    transferReporter.progress(file, force: true)
                }
            }
            live.succeed(
                completed: removed,
                total: selection.entries.count,
                detail: removed == 0 ? "Nothing to clean" : "Cleanup completed"
            )
            phase = .done(
                removed == 0
                    ? "No legacy files remain."
                    : "Removed \(removed) legacy file\(removed == 1 ? "" : "s").")
            await refreshStatus()
        } catch TumoflipInstallError.cancelled {
            phase = .done("Stopped — cleanup rolled back, nothing changed.")
            live.stop(
                completed: 0,
                total: selection.entries.count,
                detail: "Cleanup rolled back"
            )
            await refreshStatus()
        } catch let error as TumoflipInstallError {
            phase = .failed(installErrorText(error))
            live.fail(
                completed: 0,
                total: selection.entries.count,
                detail: installErrorText(error)
            )
            await refreshStatus()
        } catch {
            phase = .failed(friendly(error))
            live.fail(
                completed: 0,
                total: selection.entries.count,
                detail: friendly(error)
            )
            await refreshStatus()
        }
    }

    /// Roll back any transaction left half-applied by a previous crash/disconnect.
    /// Safe to call on appear; needs a connected Flipper to read its state.
    func recoverIfNeeded() async {
        beginTransactionGuards()
        defer { endTransactionGuards() }
        transferChannel = activeChannel
        let inst = TumoflipInstaller(fs: activeFS(), source: ZipPackageSource(entries: [:]))
        do { try await inst.recover() }
        catch let e as TumoflipInstallError { phase = .failed(installErrorText(e)) }
        catch { /* not connected / nothing to recover */ }
    }

    private var activeChannel: TransferChannel { TransferChannelStore.shared.activeChannel }

    private func activeFS() -> any TumoflipDeviceFS {
        if let usb = TransferChannelStore.shared.activeStore as? USBSDStorage {
            return USBTumoflipDeviceFS(storage: usb)
        }
        return FlipperDeviceFS()
    }

    private struct FreshDeviceIdentity {
        let identity: TumoflipDeviceIdentity
        let compatibility: TumoflipCompatibilityIdentity?
    }

    private enum DeviceIdentityReadError: LocalizedError {
        case incomplete

        var errorDescription: String? {
            "The Flipper returned an incomplete firmware identity."
        }
    }

    private func adopt(_ fresh: FreshDeviceIdentity) {
        deviceIdentity = fresh.identity
        if let compatibility = fresh.compatibility {
            compatibilityApiMajor = compatibility.apiMajor
            compatibilityTarget = compatibility.hardwareTarget
        }
        compatibilityIdentityFailure = nil
        firmwareRoute = TumoflipFirmwareRouter.route(
            identity: fresh.identity,
            manualOverride: manualChannelOverride
        )
    }

    /// Read a complete identity over the live RPC link. A ready BLE characteristic set
    /// and an RPC response are separate states, so retry short reconnect/command races.
    /// The install path still calls this immediately before touching the SD card.
    private func freshDeviceIdentity(
        attempts: Int = 3,
        requireCompatibility: Bool = true
    ) async throws -> FreshDeviceIdentity {
        precondition(attempts > 0)
        var lastError: Error = FlipperRPCError.notReady

        for attempt in 0..<attempts {
            if await FlipperBLE.shared.waitUntilReady(timeout: attempt == 0 ? 2 : 4) {
                if FlipperBLE.shared.serialOwner == .rpc {
                    do {
                        let info = try await FlipperSystem().deviceInfo(timeout: 8)
                        let identity = TumoflipDeviceIdentity(deviceInfo: info)
                        let compatibility = identity.compatibilityIdentity
                        if requireCompatibility && compatibility == nil {
                            throw DeviceIdentityReadError.incomplete
                        }
                        return FreshDeviceIdentity(
                            identity: identity,
                            compatibility: compatibility
                        )
                    } catch {
                        lastError = error
                    }
                } else {
                    lastError = FlipperBLE.shared.serialOwner == .claudeBuddy
                        ? FlipperRPCError.serialOwnedByClaudeBuddy
                        : FlipperRPCError.notReady
                }
            } else {
                lastError = FlipperRPCError.notReady
            }

            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        throw lastError
    }

    private func refreshRoutingIdentity() async {
        let identity: TumoflipDeviceIdentity?
        if FlipperBLE.shared.state == .ready {
            do {
                let fresh = try await freshDeviceIdentity(
                    attempts: 2,
                    requireCompatibility: false
                )
                adopt(fresh)
                identity = fresh.identity
            } catch {
                compatibilityIdentityFailure = error.localizedDescription
                identity = nil
            }
        } else {
            identity = nil
        }
        deviceIdentity = identity
        firmwareRoute = TumoflipFirmwareRouter.route(identity: identity, manualOverride: manualChannelOverride)
    }

    private var packageIdentityVersion: String? {
        deviceIdentity?.isTumoflip == true ? deviceIdentity?.firmwareVersion : nil
    }

    /// Read the connected Flipper's identity and reject incompatible packages.
    private func checkCompatibility(_ manifest: TumoflipManifest) async throws {
        let fresh = try await freshDeviceIdentity()
        adopt(fresh)
        try TumoflipCompat.check(deviceTarget: fresh.identity.hardwareTarget,
                                 deviceAPI: fresh.identity.firmwareAPI,
                                 deviceVersion: fresh.identity.firmwareVersion,
                                 deviceOriginFork: fresh.identity.originFork,
                                 manifest: manifest)
    }

    // MARK: - FAP/FAL API compatibility (issue #19)

    /// Fresh device firmware API major + hardware target, read immediately before use.
    /// Both nil when the Flipper is unreachable (fail-closed at the call sites).
    private func deviceApiTarget() async throws -> (api: Int?, target: Int?) {
        let fresh = try await freshDeviceIdentity()
        adopt(fresh)
        guard let compatibility = fresh.compatibility else {
            throw DeviceIdentityReadError.incomplete
        }
        return (
            compatibility.apiMajor,
            compatibility.hardwareTarget
        )
    }

    /// Download (or reuse) the release package zip. Cached by tag so validation and the
    /// install that follows don't fetch it twice.
    private func packageSource() async throws -> ZipPackageSource {
        guard let manifest else { throw TumoflipInstallError.sourceMissing("manifest") }
        if let cached = cachedSource, cached.releaseId == manifest.releaseId {
            return cached.source
        }
        guard let zipURL = packageZipURL else { throw TumoflipInstallError.sourceMissing("zip") }
        var request = URLRequest(
            url: zipURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 120
        )
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (tmp, _) = try await URLSession.shared.download(for: request)
        let source = try ZipPackageSource.load(zipAt: tmp)
        cachedSource = (manifest.releaseId, source)
        return source
    }

    /// Candidate FAP/FAL entries for `groups`, keyed by the RAW manifest target (so keys
    /// line up with `excludedFiles` and the file rows) and paired with a lazy byte
    /// accessor into the package zip. Data files are left for the gate to skip.
    private func fapCandidates(_ source: ZipPackageSource,
                               groups: Set<String>) -> [PackageCompatibilityGate.Candidate] {
        var out: [PackageCompatibilityGate.Candidate] = []
        for g in TumoflipManifest.knownGroups where groups.contains(g) {
            for f in files(g) {
                out.append(PackageCompatibilityGate.Candidate(
                    id: f.target, target: f.target, data: { source.entries[f.source] }))
            }
        }
        return out
    }

    /// Proactively check every FAP/FAL in the release against the connected firmware so
    /// the UI can flag incompatible files and disable install. Best-effort: no device or
    /// no zip leaves `blocked` empty (the install path still enforces fail-closed).
    func validateCompatibility() async {
        if validating { return }
        switch phase {
        case .checking, .downloading, .installing, .cleaning:
            return
        default:
            break
        }
        guard manifest != nil, hasPackageZip else {
            blocked = [:]
            compatibilityChecked = false
            compatibilityApiMajor = nil
            compatibilityTarget = nil
            return
        }
        validating = true
        defer { validating = false }
        let api: Int?
        let target: Int?
        do {
            (api, target) = try await deviceApiTarget()
        } catch {
            // Preserve the last valid result during a reconnect instead of showing
            // every FAP as unknown or claiming the Flipper is disconnected.
            compatibilityIdentityFailure = error.localizedDescription
            return
        }
        compatibilityApiMajor = api
        compatibilityTarget = target
        guard let source = try? await packageSource() else {
            blocked = [:]
            compatibilityChecked = false
            return
        }
        let candidates = fapCandidates(source, groups: Set(TumoflipManifest.knownGroups))
        blocked = PackageCompatibilityGate.blocked(candidates, deviceApiMajor: api, deviceTarget: target)
        compatibilityChecked = true
    }

    private func loaderLocked() async throws -> Bool {
        let responses = try await FlipperRPC.shared.command(timeout: 5) { main in
            main.content = .appLockStatusRequest(PBApp_LockStatusRequest())
        }
        for response in responses {
            if case .appLockStatusResponse(let status) = response.content {
                return status.locked
            }
        }
        throw TumoflipInstallError.activeAppCouldNotStop
    }

    private func ensureLoaderIdle() async throws {
        guard try await loaderLocked() else { return }
        do {
            _ = try await FlipperRPC.shared.command(timeout: 10) { main in
                main.content = .appExitRequest(PBApp_AppExitRequest())
            }
        } catch {
            throw TumoflipInstallError.activeAppCouldNotStop
        }
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 200_000_000)
            if try await loaderLocked() == false {
                // Loader unlock can precede the app's final file close by a short
                // interval. Give storage handles time to drain before activation.
                try await Task.sleep(nanoseconds: 750_000_000)
                return
            }
        }
        throw TumoflipInstallError.activeAppCouldNotStop
    }

    private func installErrorText(_ e: TumoflipInstallError) -> String {
        switch e {
        case .sourceMissing(let s): return "Missing in archive: \(s) — rolled back."
        case .hashMismatch(let s): return "Hash mismatch: \(s) — rolled back."
        case .deviceVerifyFailed(let t): return "On-device verify failed: \(t) — rolled back."
        case .deviceVerificationUnavailable(let t):
            return "On-device MD5 timed out: \(t) — rolled back without deleting the last verified copy."
        case .stagingVerifyFailed(let target, let expected, let actual):
            let name = (target as NSString).lastPathComponent
            guard let actual else {
                return "Staged copy missing: \(name) — rolled back without re-uploading."
            }
            if actual != expected {
                return "Staged copy incomplete: \(name) · device \(actual) B vs source \(expected) B — rolled back without re-uploading."
            }
            return "Staged copy corrupted: \(name) · size matches but MD5 differs — rolled back without re-uploading."
        case .stagingVerificationUnavailable(let target, let actual):
            let name = (target as NSString).lastPathComponent
            let size = actual.map { " · staged size \($0) B" } ?? ""
            return "Could not read staged MD5: \(name)\(size) — rolled back without re-uploading."
        case .incompatible(let m): return "Incompatible: \(m). Nothing was changed."
        case .rollbackIncomplete(let t):
            return "Install failed AND rollback could not restore \(t.count) file(s): \(t.joined(separator: ", ")). Re-open to retry recovery."
        case .statePersistenceFailed(let path):
            return "Could not safely persist transaction state at \(path). Nothing else will be changed."
        case .activeAppCouldNotStop:
            return "Close the running Flipper app and retry. No package files were changed."
        case .cancelled:
            // Normally handled as a friendly "Stopped" in install()'s catch; this is the
            // fallback wording if it ever reaches here.
            return "Stopped — rolled back to the previous version, nothing changed."
        }
    }
    private func friendly(_ error: Error) -> String {
        if (error as? URLError)?.code == .some(.notConnectedToInternet) { return "No internet connection." }
        if case FlipperRPCError.timeout = error {
            return "The Flipper stopped responding over Bluetooth during the install. "
                + "Reboot the Flipper, reconnect, then try again — the transaction was rolled "
                + "back, so your files are safe. (A wired install is more reliable for large sets.)"
        }
        return error.localizedDescription
    }
}

#if DEBUG
extension TumoflipUpdater {
    enum ActionBarQAScenario: String, CaseIterable, Identifiable {
        case both = "Both actions"
        case install = "Install only"
        case cleanup = "Cleanup only"
        case identity = "Identity pending"
        case installing = "Installing"
        case cleaning = "Cleaning"

        var id: String { rawValue }
    }

    static func actionBarQAFixture(
        initial: ActionBarQAScenario = .both
    ) -> TumoflipUpdater {
        func file(_ source: String, _ target: String, bytes: Int) -> TumoflipManifest.PackageFile {
            TumoflipManifest.PackageFile(
                bytes: bytes,
                sha256: String(repeating: "a", count: 64),
                md5: String(repeating: "b", count: 32),
                source: source,
                target: target
            )
        }

        let cockpit = file(
            "apps/cockpit.fap",
            "/ext/apps/Tools/cockpit.fap",
            bytes: 118_000
        )
        let frequencyAnalyzer = file(
            "apps/frequency_analyzer.fap",
            "/ext/apps/Sub-GHz/frequency_analyzer.fap",
            bytes: 142_000
        )
        let subGHzPlaylist = file(
            "apps/subghz_playlist.fap",
            "/ext/apps/Sub-GHz/subghz_playlist.fap",
            bytes: 142_000
        )
        let xremote = file(
            "apps/tumoflip_xremote.fap",
            "/ext/apps/Module One/IR Blaster/tumoflip_xremote.fap",
            bytes: 172_000
        )
        let moduleCockpit = file(
            "apps/module_one_cockpit.fap",
            "/ext/apps/Module One/module_one_cockpit.fap",
            bytes: 112_000
        )
        let acRemote = file(
            "apps/ac_remote.fap",
            "/ext/apps/Module One/IR Blaster/.ac_remote.fap",
            bytes: 108_000
        )
        let protocolPack = file(
            "resources/protocol_pack.txt",
            "/ext/subghz/assets/protocol_pack.txt",
            bytes: 74_000
        )
        let cleanup = TumoflipManifest.CleanupEntry(
            canonical: xremote.target,
            legacy: "/ext/apps/Module One/legacy_xremote.fap"
        )
        let manifest = TumoflipManifest(
            schema: 2,
            releaseId: String(repeating: "c", count: 64),
            firmware: .init(
                api: "88.0",
                name: "tumoflip",
                version: "t-flppr-fw-004",
                target: 7,
                radioAddress: nil
            ),
            artifacts: [:],
            packages: [
                "base": [cockpit],
                "arf": [frequencyAnalyzer, subGHzPlaylist],
                "module_one": [xremote, moduleCockpit, acRemote],
                "protocol_packs": [protocolPack],
            ],
            cleanup: [cleanup],
            safety: nil,
            packageRelease: .init(
                id: "t-flppr-fw-004-packages-1b0eba79c",
                type: "package-only",
                sourceCommit: "1b0eba79c6c02a7c3307db604233aefe76cdd042",
                sourceDirty: false,
                sourceFirmwareVersion: "t-dev-004-014",
                targetReleaseTag: "v1.0.4",
                firmwareFlashUnchanged: true
            )
        )
        let identity = TumoflipDeviceIdentity(
            firmwareVersion: manifest.firmware.version,
            originFork: "tumoflip",
            firmwareCommit: "b3add26",
            firmwareCommitDirty: false,
            firmwareAPI: manifest.firmware.api,
            hardwareTarget: manifest.firmware.target
        )

        let updater = TumoflipUpdater()
        updater.manifest = manifest
        updater.releaseTag = "v1.0.4"
        updater.packageRevisionDate = ISO8601DateFormatter().date(
            from: "2026-08-11T08:21:16Z"
        )
        updater.hasPackageZip = true
        updater.groupStatus = [
            "base": .upToDate,
            "arf": .upToDate,
            "module_one": .updateAvailable,
            "protocol_packs": .upToDate,
        ]
        updater.fileStatus = [
            cockpit.target: .upToDate,
            frequencyAnalyzer.target: .upToDate,
            subGHzPlaylist.target: .upToDate,
            xremote.target: .needsUpdate,
            moduleCockpit.target: .upToDate,
            acRemote.target: .upToDate,
            protocolPack.target: .upToDate,
        ]
        updater.deviceIdentity = identity
        updater.firmwareRoute = TumoflipFirmwareRouter.route(
            identity: identity,
            manualOverride: nil
        )
        updater.compatibilityApiMajor = 88
        updater.compatibilityTarget = 7
        updater.compatibilityChecked = true
        updater.setActionBarQAScenario(initial)
        return updater
    }

    func setActionBarQAScenario(_ scenario: ActionBarQAScenario) {
        let targets = Set(
            TumoflipManifest.knownGroups.flatMap { manifest?.packages[$0] ?? [] }.map(\.target)
        )
        let cleanup = manifest?.cleanup ?? []
        stopRequested = false
        stopToken.reset()
        if scenario != .identity {
            compatibilityApiMajor = 88
            compatibilityTarget = 7
            compatibilityChecked = true
        }

        switch scenario {
        case .both:
            excludedFiles = []
            pendingCleanup = ["module_one": cleanup]
            phase = .ready
        case .install:
            excludedFiles = []
            pendingCleanup = [:]
            phase = .ready
        case .cleanup:
            excludedFiles = targets
            pendingCleanup = ["module_one": cleanup]
            phase = .ready
        case .identity:
            excludedFiles = []
            pendingCleanup = [:]
            compatibilityApiMajor = nil
            compatibilityTarget = nil
            compatibilityChecked = false
            phase = .ready
        case .installing:
            excludedFiles = []
            pendingCleanup = ["module_one": cleanup]
            phase = .installing(done: 3, total: 8, file: "tumoflip_xremote.fap")
        case .cleaning:
            excludedFiles = []
            pendingCleanup = ["module_one": cleanup]
            phase = .cleaning(done: 1, total: 2, file: "legacy_xremote.fap")
        }
    }
}
#endif
