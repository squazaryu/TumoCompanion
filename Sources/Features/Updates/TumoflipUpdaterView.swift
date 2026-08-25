import SwiftUI

/// Detail screen for the "Firmware packages" source (tumoflip SD packages). Reached by
/// tapping its row in the unified Updates "Sources" list. Lets the user pick Base / ARF /
/// Module One / Protocol Pack groups from the latest release and installs them with
/// staging, on-device verification, and rollback. Firmware DFU flashing is a separate
/// flow and is intentionally not offered here.
struct TumoflipUpdaterView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject var updater: TumoflipUpdater
    @State private var expanded: Set<String> = []
    @State private var pendingOverride: TumoflipFirmwareChannel?
    @State private var pendingCleanupCount: Int?
    @State private var showHelp = false

    private let groupLabels: [(key: String, title: String, icon: String)] = [
        ("base", "Base", "shippingbox.fill"),
        ("arf", "ARF Sub-GHz", "car.fill"),
        ("module_one", "Module One", "square.grid.2x2.fill"),
        ("protocol_packs", "Protocol Packs", "antenna.radiowaves.left.and.right"),
    ]

    init(updater: TumoflipUpdater, initiallyExpanded: Set<String> = []) {
        self.updater = updater
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        CardScroll(refreshAction: refreshPackages) {
            SectionCard(title: "Firmware packages", systemImage: "cpu.fill",
                        accessory: AnyView(StatusPill(
                            text: transfer.activeChannel.label,
                            color: transfer.activeChannel == .usb ? .blue : .secondary,
                            systemImage: transfer.activeChannel.systemImage))) {
                statusRow
                syncCatalogRow
                verifyRow
            }

            channelCard

            if updater.manifest != nil { groupsCard }
        }
        .navigationTitle("Firmware packages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("FW Packages help")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if updater.busy {
                    ProgressView()
                } else {
                    Button {
                        Task {
                            await updater.reload(recover: hasFileChannel)
                            await updater.validateCompatibility()
                        }
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .onAppear {
            Task {
                if updater.manifest == nil {
                    await updater.reload(recover: hasFileChannel)
                }
                await updater.validateCompatibility()
            }
        }
        .sheet(isPresented: $showHelp) { TumoflipPackagesHelpView() }
        .confirmationDialog(
            "Switch package channel?",
            isPresented: Binding(
                get: { pendingOverride != nil },
                set: { if !$0 { pendingOverride = nil } }
            ),
            presenting: pendingOverride
        ) { channel in
            Button("Use \(channel.label) packages", role: channel == .dev ? .destructive : nil) {
                Task {
                    updater.setManualChannelOverride(channel)
                    await updater.reload(recover: false)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { channel in
            Text("This overrides the channel inferred from the installed firmware and will reload \(channel.packageLabel). Install only if the connected Flipper is compatible.")
        }
        .confirmationDialog(
            "Remove legacy package files?",
            isPresented: Binding(
                get: { pendingCleanupCount != nil },
                set: { if !$0 { pendingCleanupCount = nil } }
            ),
            presenting: pendingCleanupCount
        ) { count in
            Button(
                "Clean Up \(count) file\(count == 1 ? "" : "s")",
                role: .destructive
            ) {
                pendingCleanupCount = nil
                Task { await updater.cleanUpPending() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { count in
            Text("\(count) obsolete file\(count == 1 ? "" : "s") will be removed. Current apps are verified against the manifest first, and any failure rolls the cleanup back.")
        }
    }

    private var hasFileChannel: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fw-packages-action-bar-qa") {
            return true
        }
        #endif
        return transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private func refreshPackages() async {
        guard !updater.busy else { return }
        await updater.reload(recover: hasFileChannel)
        await updater.validateCompatibility()
    }

    private var groupsCard: some View {
        SectionCard(title: "Package groups", systemImage: "shippingbox") {
            LazyVStack(spacing: 14) {
                ForEach(groupLabels, id: \.key) { g in
                    groupRow(g)
                }
            }
            if updater.hasFirmwareOwnedBaseline {
                Label(
                    "\(updater.firmwareOwnedFileCount) FAPs belong to the firmware baseline. FW Packages manages only independent overlays and never reinstalls these files.",
                    systemImage: "shippingbox.fill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("fw-packages-firmware-baseline")
            }
            if updater.compatibilityChecked && updater.hasUnvalidatedBinaries {
                Label(FapCompatibility.unknownDeviceReason, systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !updater.hasPackageZip {
                Label("This release has the manifest but no install archive (tumoflip-packages.zip) yet — installing isn't available until a release publishes it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var channelCard: some View {
        CollapsibleCard(
            title: "Package channel",
            systemImage: "point.3.connected.trianglepath.dotted",
            accessory: AnyView(StatusPill(
                text: updater.firmwareRoute.channel.label,
                color: channelColor(updater.firmwareRoute.channel),
                systemImage: channelIcon(updater.firmwareRoute.channel)
            ))
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if updater.deviceIdentity?.firmwareCommitDirty == true {
                    Label("Installed firmware reports a dirty commit; package compatibility should be treated as higher risk.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let warning = updater.firmwareRoute.warning {
                    Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Auto") {
                        Task {
                            updater.clearManualChannelOverride()
                            await updater.reload(recover: false)
                        }
                    }
                    .disabled(updater.manualChannelOverride == nil || updater.busy)

                    Button("Stable") { pendingOverride = .stable }
                        .disabled(updater.busy || updater.manualChannelOverride == .stable)
                    Button("Dev") { pendingOverride = .dev }
                        .disabled(updater.busy || updater.manualChannelOverride == .dev)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if !updater.availableCatalogOptions.isEmpty {
                    Menu {
                        Button {
                            Task { await updater.selectCatalogRevision(nil) }
                        } label: {
                            Label("Automatic (latest compatible)", systemImage: "wand.and.stars")
                        }
                        ForEach(updater.availableCatalogOptions) { option in
                            Button {
                                Task { await updater.selectCatalogRevision(option.revision) }
                            } label: {
                                Label(catalogOptionLabel(option), systemImage: option.revision == updater.selectedCatalogRevision ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                            }
                        }
                    } label: {
                        Label("Choose package revision", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("fw-packages-revision-picker")
                }
                Divider().opacity(0.4)
                metadataRow("Installed", updater.deviceIdentity?.firmwareVersion ?? "Unknown")
                metadataRow("Origin", updater.deviceIdentity?.originFork ?? "Unknown")
                metadataRow("Detected", updater.firmwareRoute.detectedChannel?.packageLabel ?? "Unknown")
                metadataRow("Selected", updater.firmwareRoute.channel.packageLabel)
                Label(
                    "Catalog history is independent of the firmware release. Compatibility is checked by channel, API major and hardware target.",
                    systemImage: "link.badge.plus"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let manifest = updater.manifest {
                    metadataRow(
                        "Compatible FW",
                        firmwareCompatibilityDisplay(manifest),
                        identifier: "fw-packages-compatible-firmware"
                    )
                    metadataRow(
                        "FW Packages",
                        packageRevisionDisplay,
                        identifier: "fw-packages-revision"
                    )
                    if let selected = updater.selectedCatalogRevision,
                       let current = updater.availableCatalogOptions.compactMap(\.revision).max(),
                       selected < current {
                        Label(
                            "Rollback revision selected. Install will restore this immutable package snapshot; firmware is unchanged.",
                            systemImage: "arrow.uturn.backward.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fw-packages-rollback-selected")
                    }
                    metadataRow("Package API", manifest.firmware.api)
                    if updater.firmwareFlashUnchanged {
                        Label(
                            manifest.isFirmwareSnapshotCatalog
                                ? "Exact firmware package snapshot. Missing or changed bundled files can be reinstalled; firmware flashing is unchanged."
                                : manifest.isIndependentBaselineCatalog
                                    ? "Independent baseline catalog. Firmware-owned files are reference-only; no FAP files are managed here."
                                    : "Apps-only package update. Firmware flashing is unchanged.",
                            systemImage: "checkmark.shield.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("fw-packages-apps-only")
                    }
                }
                if let api = updater.deviceIdentity?.firmwareAPI {
                    metadataRow("Installed API", api)
                }
                if let commit = updater.deviceIdentity?.firmwareCommit, !commit.isEmpty {
                    metadataRow("Commit", commit)
                }
            }
        }
    }

    private func metadataRow(
        _ title: String,
        _ value: String,
        identifier: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            if let identifier {
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier(identifier)
            } else {
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private var packageRevisionDisplay: String {
        guard let date = updater.packageRevisionDate else {
            return updater.packageRevision
        }
        return "\(updater.packageRevision) · \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func catalogOptionLabel(_ option: TumoflipPackageCatalogOption) -> String {
        let revision = option.revision.map { String(format: "%03d", $0) } ?? "legacy"
        let suffix = option.repository.role == .legacy ? " · legacy" : ""
        if let date = option.updatedAt {
            return "Rev \(revision)\(suffix) · \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Rev \(revision)\(suffix)"
    }

    private func firmwareCompatibilityDisplay(_ manifest: TumoflipManifest) -> String {
        if manifest.isFirmwareSnapshotCatalog {
            return "Exact \(manifest.firmware.version) · API \(manifest.firmware.api) · f\(manifest.firmware.target)"
        }
        if let release = manifest.packageRelease,
           let channel = release.catalogChannel {
            return "Tumoflip \(channel.capitalized) · API \(manifest.firmware.api) · f\(manifest.firmware.target)"
        }
        return "\(updater.releaseTag) · \(manifest.firmware.version)"
    }

    @ViewBuilder private func groupRow(_ g: (key: String, title: String, icon: String)) -> some View {
        let n = updater.count(g.key)
        let sel = updater.selectedCount(g.key)
        let selectable = updater.selectableCount(g.key)
        let firmwareOwned = updater.firmwareOwnedCount(g.key)
        let cleanupEntries = updater.cleanupEntries(g.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if n > 0 {
                    // Tri-state selection is limited to standalone overlays. The
                    // firmware-owned baseline is visible, but cannot be overwritten
                    // from this screen.
                    Button { updater.setGroup(g.key, selected: sel < selectable) } label: {
                        Image(systemName: sel == 0 ? "square" : (sel == selectable ? "checkmark.square.fill" : "minus.square.fill"))
                            .font(.title3)
                            .foregroundStyle(sel == 0 ? Color.secondary : Theme.accent)
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectable == 0 || updater.busy || updater.validating)
                    .accessibilityIdentifier("fw-packages-select-\(g.key)")
                } else {
                    Image(systemName: firmwareOwned > 0 ? "shippingbox" : "square")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 30)
                }

                Image(systemName: g.icon).foregroundStyle(.orange).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.title).font(.subheadline)
                    if n > 0 {
                        Text("\(sel)/\(selectable) standalone · \(byteStr(updater.bytes(g.key)))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if firmwareOwned > 0 {
                        Text("\(firmwareOwned) firmware-owned · not managed here")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("fw-packages-baseline-\(g.key)")
                    }
                    if let info = groupSummaryInfo(g.key) {
                        Label(info.text, systemImage: info.icon)
                            .font(.caption2)
                            .foregroundStyle(info.color)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .accessibilityIdentifier("fw-packages-status-\(g.key)")
                    }
                    if !cleanupEntries.isEmpty {
                        Label(
                            "\(cleanupEntries.count) Cleanup required",
                            systemImage: "trash.circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .accessibilityIdentifier("fw-packages-cleanup-status-\(g.key)")
                    }
                }
                Spacer()
                if n > 0 {
                    Button {
                        withAnimation { toggleExpanded(g.key) }
                    } label: {
                        Image(systemName: expanded.contains(g.key) ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("fw-packages-expand-\(g.key)")
                }
            }
            if expanded.contains(g.key) {
                VStack(spacing: 6) {
                    ForEach(updater.files(g.key), id: \.target) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: fileBinding(f.target)) {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc").font(.caption2).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(fileName(f.target))
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        fileStatusLabel(updater.status(file: f.target))
                                    }
                                    Spacer()
                                    Text(byteStr(f.bytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            .tint(Theme.accent)
                            .disabled(updater.busy || updater.validating || updater.isFileBlocked(f.target))
                            .accessibilityIdentifier(
                                "fw-packages-file-\(g.key)-\(fileName(f.target))"
                            )
                            .accessibilityLabel(fileName(f.target))
                            .accessibilityValue(fileStatusInfo(updater.status(file: f.target)).text)
                            if let reason = updater.blocked[f.target] {
                                Label(reason, systemImage: "exclamationmark.octagon.fill")
                                    .font(.caption2).foregroundStyle(.red)
                                    .labelStyle(.titleAndIcon)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 28)
                    }
                    ForEach(cleanupEntries, id: \.legacy) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "trash.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Cleanup required")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(entry.legacy)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 28)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Cleanup required")
                        .accessibilityValue(entry.legacy)
                    }
                }
            }
            if g.key != groupLabels.last?.key { Divider() }
        }
    }

    private func fileBinding(_ target: String) -> Binding<Bool> {
        Binding(get: { updater.isFileSelected(target) },
                set: { updater.setFile(target, selected: $0) })
    }

    private var installActionCount: Int {
        guard updater.manifest != nil, updater.hasPackageZip else { return 0 }
        return updater.selectedPendingFileCount
    }

    private var installNeedsIdentity: Bool {
        updater.selectedRequiresCompatibilityIdentity && !updater.hasFreshCompatibilityIdentity
    }

    private var identityNotice: FWPackagesIdentityNotice? {
        guard installNeedsIdentity else { return nil }
        if hasFileChannel {
            return .verificationPending
        }
        return .connectionRequired(transfer.activeChannel)
    }

    private var actionBar: some View {
        FWPackagesActionBar(
            phase: updater.phase,
            installCount: installActionCount,
            cleanupCount: updater.cleanupFileCount,
            // install() repeats the complete identity/API/target gate before any SD
            // mutation. A failed proactive check must not deadlock a connected user.
            canInstall: hasFileChannel && !updater.busy,
            canCleanUp: hasFileChannel && !updater.busy,
            stopRequested: updater.stopRequested,
            transferChannel: updater.transferChannel,
            identityNotice: identityNotice,
            install: { Task { await updater.install() } },
            cleanUp: { pendingCleanupCount = updater.cleanupFileCount },
            stop: updater.requestStop
        )
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle, .ready:
            if updater.manifest == nil {
                Label("Tap refresh to check the latest release", systemImage: "shippingbox").foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("Rev \(updater.packageRevision)", systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if updater.manifest?.isReferenceOnlyCatalog == true {
                        StatusPill(text: "Catalog ready", color: .green, systemImage: "checkmark.seal.fill")
                    } else if let info = statusInfo(updater.overallStatus) {
                        StatusPill(text: info.text, color: info.color, systemImage: info.icon)
                    }
                }
            }
        case .checking:    progress("Checking the latest release…")
        case .syncingCatalog: progress("Syncing the verified catalog to Flipper…")
        case .downloading:
            VStack(alignment: .leading, spacing: 4) {
                progress("Downloading package archive…")
                keepAwakeNote
            }
        case .installing(let done, let total, let file):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(file) · \(updater.transferChannel.label)")
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(Int(Double(done) / Double(max(total, 1)) * 100))%")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
                    .tint(Theme.accent)
                keepAwakeNote
            }
        case .cleaning(let done, let total, let file):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(file) · \(updater.transferChannel.label)")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(done)/\(total)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: Double(min(done, total)), total: Double(max(total, 1)))
                    .tint(.orange)
                keepAwakeNote
            }
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack { ProgressView(); Text(text).foregroundStyle(.secondary) }
    }

    /// Shown during a live transaction: locking the phone mid-install tears down BLE.
    private var keepAwakeNote: some View {
        Label(transfer.activeChannel == .usb
              ? "Keep USB SD Mode active on the Flipper until this finishes."
              : "Keep the screen on and the app open — don't lock your phone until this finishes.",
              systemImage: transfer.activeChannel == .usb ? "cable.connector" : "lock.open.iphone")
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// This is intentionally separate from verification. It updates the FAP's
    /// display-only catalog snapshot even when every package is already current.
    @ViewBuilder private var syncCatalogRow: some View {
        if updater.manifest != nil {
            Button {
                Task { await updater.syncCatalog() }
            } label: {
                HStack {
                    if case .syncingCatalog = updater.phase {
                        ProgressView().scaleEffect(0.85)
                        Text("Syncing catalog…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync catalog to Flipper")
                    }
                    Spacer()
                    Text("no FAP changes")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(updater.busy || !hasFileChannel)
            .accessibilityIdentifier("fw-packages-sync-catalog")
            .accessibilityLabel("Sync package catalog to Flipper")
            .accessibilityHint("Writes only the verified catalog snapshot and does not install or replace FAP files.")
        }
    }

    /// On-demand deep check: hash the actual files on the Flipper to confirm presence/integrity.
    @ViewBuilder private var verifyRow: some View {
        if updater.manifest != nil {
            Button {
                Task { await updater.verifyOnDevice() }
            } label: {
                HStack {
                    if updater.verifying {
                        ProgressView().scaleEffect(0.85)
                        Text("Verifying on device…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark.shield")
                        Text("Verify on device")
                    }
                    Spacer()
                    if updater.lastVerifiedOnDevice && !updater.verifying {
                        Label("device-checked", systemImage: "checkmark.seal.fill")
                            .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                    }
                }
            }
            .disabled(updater.verifying || !hasFileChannel)
        }
    }

    private func byteStr(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    private func toggleExpanded(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func fileName(_ target: String) -> String { (target as NSString).lastPathComponent }

    private func fileStatusLabel(_ status: TumoflipInstaller.FileStatus) -> some View {
        let info = fileStatusInfo(status)
        return Label(info.text, systemImage: info.icon)
            .font(.caption2)
            .foregroundStyle(info.color)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }

    private func fileStatusInfo(
        _ status: TumoflipInstaller.FileStatus
    ) -> (text: String, color: Color, icon: String) {
        switch status {
        case .upToDate:
            return ("Up to date", .green, "checkmark.circle.fill")
        case .needsUpdate, .missing, .unknown, .validationError:
            // Keep fail-closed transport/validation distinctions in the model while
            // presenting the agreed three-state package-row vocabulary.
            return ("Needs update", .orange, "arrow.down.circle.fill")
        }
    }

    private func channelColor(_ channel: TumoflipFirmwareChannel) -> Color {
        switch channel {
        case .stable: return .green
        case .dev: return .purple
        }
    }

    private func channelIcon(_ channel: TumoflipFirmwareChannel) -> String {
        switch channel {
        case .stable: return "checkmark.seal.fill"
        case .dev: return "hammer.fill"
        }
    }

    /// Group summaries use the same per-target truth as the expanded FAP rows. Unknown,
    /// missing, changed, and validation-error targets remain fail-closed as updates.
    private func groupSummaryInfo(
        _ group: String
    ) -> (text: String, color: Color, icon: String)? {
        let files = updater.files(group)
        guard !files.isEmpty else { return nil }
        let needsUpdate = files.lazy.filter {
            updater.status(file: $0.target) != .upToDate
        }.count
        let badge: SourceBadge = needsUpdate == 0
            ? .upToDate
            : .updatesAvailable(needsUpdate, of: files.count)
        return (badge.text, badge.color, badge.systemImage)
    }

    /// Display mapping for a group/overall status. `nil` for `.empty` (no badge).
    private func statusInfo(_ s: TumoflipInstaller.GroupStatus) -> (text: String, color: Color, icon: String)? {
        switch s {
        case .upToDate:        return ("Up to date", .green, "checkmark.circle.fill")
        case .updateAvailable: return ("Update available", .orange, "arrow.down.circle.fill")
        case .notInstalled:    return ("Not installed", .secondary, "circle.dashed")
        case .empty:           return nil
        }
    }
}

struct FWPackagesActionBar: View {
    let phase: TumoflipUpdater.Phase
    let installCount: Int
    let cleanupCount: Int
    let canInstall: Bool
    let canCleanUp: Bool
    let stopRequested: Bool
    let transferChannel: TransferChannel
    let identityNotice: FWPackagesIdentityNotice?
    let install: () -> Void
    let cleanUp: () -> Void
    let stop: () -> Void

    @ViewBuilder
    var body: some View {
        switch phase {
        case .checking, .syncingCatalog:
            EmptyView()
        case .downloading:
            transactionBar(
                title: "Downloading package archive",
                detail: transferChannel.label,
                progress: nil,
                tint: Theme.accent,
                stopTitle: "Stop install"
            )
        case .installing(let done, let total, let file):
            let percent = Int(Double(min(done, total)) / Double(max(total, 1)) * 100)
            transactionBar(
                title: file,
                detail: "\(percent)% · \(transferChannel.label)",
                progress: Double(min(done, total)) / Double(max(total, 1)),
                tint: Theme.accent,
                stopTitle: "Stop install"
            )
        case .cleaning(let done, let total, let file):
            transactionBar(
                title: file,
                detail: "\(done)/\(total) · \(transferChannel.label)",
                progress: Double(min(done, total)) / Double(max(total, 1)),
                tint: .orange,
                stopTitle: "Stop cleanup"
            )
        default:
            if installCount > 0 || cleanupCount > 0 {
                actionButtons
            }
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            if installCount > 0, let identityNotice {
                Label(identityNotice.text, systemImage: identityNotice.systemImage)
                    .font(.caption2)
                    .foregroundStyle(identityNotice.isBlocking ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if installCount > 0 {
                    Button(action: install) {
                        Label(
                            "Install \(installCount)",
                            systemImage: "square.and.arrow.down.on.square"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canInstall)
                    .accessibilityIdentifier("fw-packages-install-action")
                    .accessibilityLabel(
                        "Install \(installCount) file\(installCount == 1 ? "" : "s")"
                    )
                }
                if cleanupCount > 0 {
                    Button(role: .destructive, action: cleanUp) {
                        Label("Clean Up \(cleanupCount)", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(!canCleanUp)
                    .accessibilityIdentifier("fw-packages-cleanup-action")
                    .accessibilityLabel(
                        "Clean Up \(cleanupCount) file\(cleanupCount == 1 ? "" : "s")"
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func transactionBar(
        title: String,
        detail: String,
        progress: Double?,
        tint: Color,
        stopTitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stopRequested ? "Stopping safely…" : title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Group {
                if let progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            }
            .tint(tint)
            .accessibilityIdentifier("fw-packages-progress")

            Button(role: .destructive, action: stop) {
                Label(
                    stopRequested ? "Stopping safely…" : stopTitle,
                    systemImage: "stop.circle.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(stopRequested)
            .accessibilityIdentifier("fw-packages-stop-action")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

enum FWPackagesIdentityNotice: Equatable {
    case verificationPending
    case connectionRequired(TransferChannel)

    var text: String {
        switch self {
        case .verificationPending:
            return "Connected. Firmware compatibility will be verified before installation."
        case .connectionRequired(let channel):
            return "Connect Flipper over BLE to validate apps before installing via \(channel.label)."
        }
    }

    var systemImage: String {
        switch self {
        case .verificationPending: return "checkmark.shield"
        case .connectionRequired: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    var isBlocking: Bool {
        if case .connectionRequired = self { return true }
        return false
    }
}

#if DEBUG
struct FWPackagesActionBarQAView: View {
    @StateObject private var updater: TumoflipUpdater
    @State private var scenario: TumoflipUpdater.ActionBarQAScenario

    init() {
        let initial: TumoflipUpdater.ActionBarQAScenario = ProcessInfo.processInfo.arguments
            .contains("-fw-packages-identity-pending") ? .identity : .both
        _updater = StateObject(
            wrappedValue: TumoflipUpdater.actionBarQAFixture(initial: initial)
        )
        _scenario = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            TumoflipUpdaterView(
                updater: updater,
                initiallyExpanded: ["module_one"]
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(TumoflipUpdater.ActionBarQAScenario.allCases) { item in
                            Button(item.rawValue) {
                                scenario = item
                                updater.setActionBarQAScenario(item)
                            }
                        }
                    } label: {
                        Label(scenario.rawValue, systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("fw-packages-qa-scenario")
                }
            }
        }
    }
}
#endif

private struct TumoflipPackagesHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("FW Packages update Tumoflip apps, resources, and protocol packs on the SD card.",
                      systemImage: "shippingbox")
                Label("The channel follows the installed Stable or Dev firmware unless you override it.",
                      systemImage: "point.3.connected.trianglepath.dotted")
                Label("Files are staged, verified, and rolled back if installation fails.",
                      systemImage: "checkmark.shield")
                Label("Verify on device checks the files currently stored on the Flipper.",
                      systemImage: "checkmark.seal")
                Label("Keep the app open during BLE transfer or USB SD Mode active during USB transfer.",
                      systemImage: "arrow.left.arrow.right")
            }
            .navigationTitle("FW Packages help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
