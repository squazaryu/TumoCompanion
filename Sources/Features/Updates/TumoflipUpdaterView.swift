import SwiftUI

/// Detail screen for the "Firmware packages" source (tumoflip SD packages). Reached by
/// tapping its row in the unified Updates "Sources" list. Lets the user pick Base / ARF /
/// Module One / Protocol Pack groups from the latest release and installs them with
/// staging, on-device verification, and rollback. Firmware DFU flashing is a separate
/// flow and is intentionally not offered here.
struct TumoflipUpdaterView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var updater: TumoflipUpdater
    @State private var expanded: Set<String> = []
    @State private var pendingOverride: TumoflipFirmwareChannel?
    @State private var pendingCleanupCount: Int?
    @State private var showHelp = false
    @State private var packageDrawerExpanded = false

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
                            color: transfer.activeChannel == .usb ? Theme.info : .secondary,
                            systemImage: transfer.activeChannel.systemImage))) {
                statusRow
                syncCatalogRow
                verifyRow
            }

            packageOverviewCard
            actionBar

            // The folder tab is fixed above the app tab bar, matching Home
            // → Tools. Reserve only its collapsed height in the page flow.
            Color.clear.frame(height: 58)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if updater.manifest != nil {
                BottomFolderDrawer(
                    isExpanded: packageDrawerBinding,
                    title: "PACKAGE DETAILS",
                    summary: packageDetailsSummary,
                    systemImage: "shippingbox.fill",
                    accessibilityIdentifier: "fw-packages-details-drawer-toggle",
                    panelHeight: packageDetailsDrawerHeight,
                    maxPanelHeight: 400
                ) {
                    packageDetailsPanel
                }
            }
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
                if updater.busy { ProgressView() }
            }
        }
        .onAppear {
            Task {
                if updater.manifest == nil {
                    await updater.reload(recover: hasFileChannel)
                }
                await updater.validateCompatibility()
            }
        }
        .sheet(isPresented: $showHelp) { TumoflipPackagesHelpView() }
    }

    private var packageDrawerBinding: Binding<Bool> {
        Binding(
            get: { packageDrawerExpanded },
            set: { expanded in
                packageDrawerExpanded = expanded
                if !expanded { pendingOverride = nil }
            }
        )
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

    private var packageOverviewCard: some View {
        SectionCard(
            title: "Package catalog",
            systemImage: "shippingbox.fill",
            accessory: AnyView(StatusPill(
                text: updater.firmwareRoute.channel.label,
                color: channelColor(updater.firmwareRoute.channel),
                systemImage: channelIcon(updater.firmwareRoute.channel)
            ))
        ) {
            packageOverviewRow(
                title: "Channel",
                detail: channelDrawerSummary,
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            packageOverviewRow(
                title: "Groups",
                detail: packageGroupsSummary,
                systemImage: "shippingbox"
            )
            Text("Open the folder tab below for channel controls, revisions, and per-file selection.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func packageOverviewRow(title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
    }

    private var packageDetailsSummary: String {
        let pending = groupLabels.reduce(0) { total, group in
            total + updater.files(group.key).filter { updater.status(file: $0.target) != .upToDate }.count
        }
        if pending > 0 { return "\(pending) update\(pending == 1 ? "" : "s")" }
        return updater.firmwareRoute.channel.label
    }

    private var packageDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Label("PACKAGE CHANNEL", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.7)
                Spacer()
                StatusPill(
                    text: updater.firmwareRoute.channel.label,
                    color: channelColor(updater.firmwareRoute.channel),
                    systemImage: channelIcon(updater.firmwareRoute.channel)
                )
            }

            channelDetails

            Divider().opacity(0.45)

            HStack(spacing: 7) {
                Label("PACKAGE GROUPS", systemImage: "shippingbox")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.7)
                Spacer()
                Text(packageGroupsSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.62))
            }

            VStack(spacing: 0) {
                ForEach(groupLabels, id: \.key) { g in
                    groupRow(g)
                }
            }

            if updater.hasFirmwareOwnedBaseline {
                Label(
                    "\(updater.firmwareOwnedFileCount) built-in FAPs · reference only",
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
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !updater.hasPackageZip {
                Label("This release has the manifest but no install archive (tumoflip-packages.zip) yet — installing isn't available until a release publishes it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var packageDetailsDrawerHeight: CGFloat {
        // Keep the initial drawer visibly smaller than the primary screen.
        // Expanded per-file lists scroll inside the panel instead of growing it.
        360
    }

    private var packageGroupsSummary: String {
        let standalone = groupLabels.reduce(0) { $0 + updater.selectableCount($1.key) }
        let pending = groupLabels.reduce(0) { total, group in
            total + updater.files(group.key).filter { updater.status(file: $0.target) != .upToDate }.count
        }
        if pending > 0 {
            return "\(pending) update\(pending == 1 ? "" : "s")"
        }
        if standalone > 0 {
            return "\(standalone) standalone"
        }
        return "Reference only"
    }

    @ViewBuilder
    private var channelDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            if updater.deviceIdentity?.firmwareCommitDirty == true {
                Label("Installed firmware reports a dirty commit; package compatibility should be treated as higher risk.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = updater.firmwareRoute.warning {
                Label(warning.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                channelChoiceButton(
                    "Auto",
                    enabled: updater.manualChannelOverride != nil && !updater.busy,
                    action: clearManualChannelOverride
                )
                channelChoiceButton(
                    "Stable",
                    enabled: !updater.busy && updater.manualChannelOverride != .stable,
                    action: { requestChannelOverride(.stable) }
                )
                channelChoiceButton(
                    "Dev",
                    enabled: !updater.busy && updater.manualChannelOverride != .dev,
                    action: { requestChannelOverride(.dev) }
                )
                Spacer(minLength: 2)
                catalogRevisionPicker
            }

            if let channel = pendingOverride {
                InlineActionConfirmationRow(
                    title: "Use \(channel.label) packages",
                    detail: "Manual override · checked again before install",
                    systemImage: channelIcon(channel),
                    iconColor: channelColor(channel),
                    tint: channelColor(channel),
                    confirmTitle: "Switch",
                    accessibilityIdentifier: "fw-packages-channel-confirmation",
                    cancelAccessibilityLabel: "Cancel package channel switch",
                    confirmAccessibilityLabel: "Confirm switch to \(channel.label) packages",
                    onCancel: cancelChannelOverride,
                    onConfirm: confirmChannelOverride
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let manifest = updater.manifest {
                catalogSummary(manifest)
                if let selected = updater.selectedCatalogRevision,
                   let current = updater.availableCatalogOptions.compactMap(\.revision).max(),
                   selected < current {
                    Label(
                        "Rollback revision selected. Install will restore this immutable package snapshot; firmware is unchanged.",
                        systemImage: "arrow.uturn.backward.circle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("fw-packages-rollback-selected")
                }
            }
        }
    }

    @ViewBuilder
    private var catalogRevisionPicker: some View {
        if !updater.availableCatalogOptions.isEmpty {
            Menu {
                Button(action: selectLatestCatalogRevision) {
                    Label("Automatic (latest compatible)", systemImage: "wand.and.stars")
                }
                ForEach(updater.availableCatalogOptions) { option in
                    Button { selectCatalogRevision(option.revision) } label: {
                        Label(
                            catalogOptionLabel(option),
                            systemImage: option.revision == updater.selectedCatalogRevision
                                ? "checkmark.circle.fill" : "clock.arrow.circlepath"
                        )
                    }
                }
            } label: {
                Label("Revision", systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Theme.accent)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Theme.accent.opacity(0.2), lineWidth: 1)
                    }
            }
            .disabled(updater.busy)
            .accessibilityIdentifier("fw-packages-revision-picker")
        }
    }

    private func catalogSummary(_ manifest: TumoflipManifest) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(packageRevisionDisplay)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .accessibilityIdentifier("fw-packages-revision")
                HStack(spacing: 3) {
                    Text(firmwareCompatibilityDisplay(manifest))
                        .accessibilityIdentifier("fw-packages-compatible-firmware")
                    Text("· API \(manifest.firmware.api)")
                }
                .font(.caption2)
                .foregroundStyle(Color.primary.opacity(0.62))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            }
            Spacer(minLength: 4)
            if updater.firmwareFlashUnchanged {
                Label(catalogRoleTitle(manifest), systemImage: "checkmark.shield.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.success)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.success.opacity(0.16), in: Capsule())
                    .accessibilityIdentifier("fw-packages-apps-only")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func catalogRoleTitle(_ manifest: TumoflipManifest) -> String {
        if manifest.isIndependentBaselineCatalog { return "Baseline" }
        if manifest.isFirmwareSnapshotCatalog { return "Snapshot" }
        return "Apps only"
    }

    private var channelDrawerSummary: String {
        let channel = updater.firmwareRoute.channel.label
        let revision = updater.packageRevision.isEmpty ? "latest" : "Rev \(updater.packageRevision)"
        return "\(channel) · \(revision)"
    }

    private func channelChoiceButton(
        _ title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.accent : Color.primary.opacity(0.68))
        .background(
            (enabled ? Theme.accent : Color.primary).opacity(enabled ? 0.16 : 0.10),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    (enabled ? Theme.accent : Color.primary).opacity(0.22),
                    lineWidth: 1
                )
        }
        .disabled(!enabled)
        .accessibilityLabel(title)
        .accessibilityValue(enabled ? "Available" : "Unavailable")
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
        if let independent = manifest.independentCompatibilityDisplay {
            return independent
        }
        return "\(updater.releaseTag) · \(manifest.firmware.version)"
    }

    @ViewBuilder private func groupRow(_ g: (key: String, title: String, icon: String)) -> some View {
        let n = updater.count(g.key)
        let sel = updater.selectedCount(g.key)
        let selectable = updater.selectableCount(g.key)
        let firmwareOwned = updater.firmwareOwnedCount(g.key)
        let cleanupEntries = updater.cleanupEntries(g.key)
        let pendingUpdates = updater.files(g.key).lazy.filter {
            updater.status(file: $0.target) != .upToDate
        }.count
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if n > 0 {
                    // Tri-state selection is limited to standalone overlays. The
                    // firmware-owned baseline is visible, but cannot be overwritten
                    // from this screen.
                    Button { updater.setGroup(g.key, selected: sel < selectable) } label: {
                        Image(systemName: sel == 0 ? "square" : (sel == selectable ? "checkmark.square.fill" : "minus.square.fill"))
                            .font(.body)
                            .foregroundStyle(sel == 0 ? Color.secondary : Theme.accent)
                            .frame(width: 24, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(selectable == 0 || updater.busy || updater.validating)
                    .accessibilityIdentifier("fw-packages-select-\(g.key)")
                } else {
                    Image(systemName: firmwareOwned > 0 ? "shippingbox" : "square")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                }

                Image(systemName: g.icon)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if n > 0 {
                        Text("\(sel)/\(selectable) · \(byteStr(updater.bytes(g.key)))")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else if firmwareOwned > 0 {
                        Text("\(firmwareOwned) built-in")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityIdentifier("fw-packages-baseline-\(g.key)")
                    }
                }
                Spacer(minLength: 4)
                PackageGroupStatusBadge(
                    pendingUpdates: pendingUpdates,
                    cleanupCount: cleanupEntries.count,
                    accessibilityIdentifier: "fw-packages-status-\(g.key)"
                )
                if n > 0 {
                    Button {
                        withAnimation { toggleExpanded(g.key) }
                    } label: {
                        Image(systemName: expanded.contains(g.key) ? "chevron.up" : "chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 22, height: 28)
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
                                    .font(.caption2).foregroundStyle(Theme.danger)
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
                                .foregroundStyle(Theme.warning)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Cleanup required")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.warning)
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
            if g.key != groupLabels.last?.key { Divider().opacity(0.45) }
        }
        .padding(.vertical, 4)
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
        VStack(spacing: 7) {
            FWPackagesActionBar(
                phase: updater.phase,
                installCount: installActionCount,
                cleanupCount: pendingCleanupCount == nil ? updater.cleanupFileCount : 0,
                // install() repeats the complete identity/API/target gate before any SD
                // mutation. A failed proactive check must not deadlock a connected user.
                canInstall: hasFileChannel && !updater.busy,
                canCleanUp: hasFileChannel && !updater.busy,
                stopRequested: updater.stopRequested,
                identityNotice: identityNotice,
                install: { Task { await updater.install() } },
                cleanUp: requestCleanup,
                stop: updater.requestStop
            )

            if let count = pendingCleanupCount {
                InlineActionConfirmationRow(
                    title: "\(count) obsolete file\(count == 1 ? "" : "s")",
                    detail: "Manifest verified · rollback on failure",
                    systemImage: "trash.slash.fill",
                    iconColor: Theme.warning,
                    tint: Theme.warning,
                    confirmTitle: "Clean Up",
                    confirmRole: .destructive,
                    accessibilityIdentifier: "fw-packages-cleanup-confirmation",
                    cancelAccessibilityLabel: "Cancel FW Packages cleanup",
                    confirmAccessibilityLabel: "Confirm FW Packages cleanup",
                    onCancel: cancelCleanup,
                    onConfirm: confirmCleanup
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
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
                        StatusPill(text: "Catalog ready", color: Theme.success, systemImage: "checkmark.seal.fill")
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
                    .accessibilityIdentifier("fw-packages-progress")
                keepAwakeNote
            }
        case .installing(let done, let total, let file):
            VStack(alignment: .leading, spacing: 6) {
                UnifiedProgressView(
                    title: file,
                    detail: "\(Int(Double(done) / Double(max(total, 1)) * 100))% · \(updater.transferChannel.label)",
                    fraction: Double(min(done, total)) / Double(max(total, 1)),
                    tint: Theme.accent
                )
                .accessibilityIdentifier("fw-packages-progress")
                keepAwakeNote
            }
        case .cleaning(let done, let total, let file):
            VStack(alignment: .leading, spacing: 6) {
                UnifiedProgressView(
                    title: file,
                    detail: "\(done)/\(total) · \(updater.transferChannel.label)",
                    fraction: Double(min(done, total)) / Double(max(total, 1)),
                    tint: Theme.warning
                )
                .accessibilityIdentifier("fw-packages-progress")
                keepAwakeNote
            }
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let m):
            ActionableErrorView(
                title: "FW Packages action failed",
                message: m,
                actionTitle: "Retry",
                action: { Task {
                    await updater.reload(recover: hasFileChannel)
                    await updater.validateCompatibility()
                } }
            )
        }
    }

    private func progress(_ text: String) -> some View {
        LoadingStateView(title: text, compact: true)
    }

    /// Shown during a live transaction: locking the phone mid-install tears down BLE.
    private var keepAwakeNote: some View {
        Label(transfer.activeChannel == .usb
              ? "Keep USB SD Mode active on the Flipper until this finishes."
              : "Keep the screen on and the app open — don't lock your phone until this finishes.",
              systemImage: transfer.activeChannel == .usb ? "cable.connector" : "lock.open.iphone")
            .font(.caption2).foregroundStyle(Theme.warning)
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
                            .font(.caption2).foregroundStyle(Theme.success).labelStyle(.titleAndIcon)
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

    private func clearManualChannelOverride() {
        Task {
            updater.clearManualChannelOverride()
            await updater.reload(recover: false)
        }
    }

    private func requestChannelOverride(_ channel: TumoflipFirmwareChannel) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingOverride = channel
        }
    }

    private func cancelChannelOverride() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingOverride = nil
        }
    }

    private func confirmChannelOverride() {
        guard let channel = pendingOverride else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingOverride = nil
            packageDrawerExpanded = false
        }
        Task {
            updater.setManualChannelOverride(channel)
            await updater.reload(recover: false)
        }
    }

    private func requestCleanup() {
        guard updater.cleanupFileCount > 0 else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingCleanupCount = updater.cleanupFileCount
        }
    }

    private func cancelCleanup() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingCleanupCount = nil
        }
    }

    private func confirmCleanup() {
        guard pendingCleanupCount != nil else { return }
        pendingCleanupCount = nil
        Task { await updater.cleanUpPending() }
    }

    private func selectLatestCatalogRevision() {
        Task { await updater.selectCatalogRevision(nil) }
    }

    private func selectCatalogRevision(_ revision: Int?) {
        Task { await updater.selectCatalogRevision(revision) }
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
            return ("Up to date", Theme.success, "checkmark.circle.fill")
        case .needsUpdate, .missing, .unknown, .validationError:
            // Keep fail-closed transport/validation distinctions in the model while
            // presenting the agreed three-state package-row vocabulary.
            return ("Needs update", Theme.warning, "arrow.down.circle.fill")
        }
    }

    private func channelColor(_ channel: TumoflipFirmwareChannel) -> Color {
        switch channel {
        case .stable: return Theme.success
        case .dev: return Theme.purple
        }
    }

    private func channelIcon(_ channel: TumoflipFirmwareChannel) -> String {
        switch channel {
        case .stable: return "checkmark.seal.fill"
        case .dev: return "hammer.fill"
        }
    }

    /// Display mapping for a group/overall status. `nil` for `.empty` (no badge).
    private func statusInfo(_ s: TumoflipInstaller.GroupStatus) -> (text: String, color: Color, icon: String)? {
        switch s {
        case .upToDate:        return ("Up to date", Theme.success, "checkmark.circle.fill")
        case .updateAvailable: return ("Update available", Theme.warning, "arrow.down.circle.fill")
        case .notInstalled:    return ("Not installed", .secondary, "circle.dashed")
        case .empty:           return nil
        }
    }
}

private struct PackageGroupStatusBadge: View {
    let pendingUpdates: Int
    let cleanupCount: Int
    let accessibilityIdentifier: String

    var body: some View {
        Group {
            if pendingUpdates == 0 && cleanupCount == 0 {
                Label("Current", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else {
                Text(actionSummary)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.warning.opacity(0.16), in: Capsule())
            }
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var actionSummary: String {
        var parts: [String] = []
        if pendingUpdates > 0 {
            parts.append("\(pendingUpdates) update\(pendingUpdates == 1 ? "" : "s")")
        }
        if cleanupCount > 0 {
            parts.append("\(cleanupCount) cleanup")
        }
        return parts.joined(separator: " · ")
    }
}

struct FWPackagesActionBar: View {
    let phase: TumoflipUpdater.Phase
    let installCount: Int
    let cleanupCount: Int
    let canInstall: Bool
    let canCleanUp: Bool
    let stopRequested: Bool
    let identityNotice: FWPackagesIdentityNotice?
    let install: () -> Void
    let cleanUp: () -> Void
    let stop: () -> Void

    @ViewBuilder
    var body: some View {
        switch phase {
        case .checking, .syncingCatalog:
            EmptyView()
        case .downloading, .installing:
            transactionStop(title: "Stop install")
        case .cleaning:
            transactionStop(title: "Stop cleanup")
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
                    .foregroundStyle(identityNotice.isBlocking ? Theme.danger : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if installCount > 0 {
                    compactAction(
                        title: "Install \(installCount)",
                        systemImage: "square.and.arrow.down.on.square",
                        tint: Theme.accent,
                        action: install
                    )
                    .disabled(!canInstall)
                    .accessibilityIdentifier("fw-packages-install-action")
                    .accessibilityLabel(
                        "Install \(installCount) file\(installCount == 1 ? "" : "s")"
                    )
                }
                if cleanupCount > 0 {
                    compactAction(
                        title: "Clean Up \(cleanupCount)",
                        systemImage: "trash",
                        tint: Theme.warning,
                        role: .destructive,
                        action: cleanUp
                    )
                    .disabled(!canCleanUp)
                    .accessibilityIdentifier("fw-packages-cleanup-action")
                    .accessibilityLabel(
                        "Clean Up \(cleanupCount) file\(cleanupCount == 1 ? "" : "s")"
                    )
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func compactAction(
        title: String,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        }
    }

    private func transactionStop(title: String) -> some View {
        compactAction(
            title: stopRequested ? "Stopping safely…" : title,
            systemImage: "stop.circle.fill",
            tint: Theme.danger,
            role: .destructive,
            action: stop
        )
        .disabled(stopRequested)
        .accessibilityIdentifier("fw-packages-stop-action")
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
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
        let arguments = ProcessInfo.processInfo.arguments
        let initial: TumoflipUpdater.ActionBarQAScenario
        if arguments.contains("-fw-packages-installing-qa") {
            initial = .installing
        } else if arguments.contains("-fw-packages-identity-pending") {
            initial = .identity
        } else {
            initial = .both
        }
        _updater = StateObject(
            wrappedValue: TumoflipUpdater.actionBarQAFixture(initial: initial)
        )
        _scenario = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            TumoflipUpdaterView(updater: updater)
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
