import SwiftUI

struct FirmwareLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var transfer: TransferChannelStore
    @ObservedObject var library: FirmwareLibrary
    @State private var showHelp = false
    @State private var pendingRelease: FirmwareRelease?
    @State private var detailsRelease: FirmwareRelease?
    @State private var releaseDrawerExpanded = false

    private var releaseDrawerBinding: Binding<Bool> {
        Binding(
            get: { releaseDrawerExpanded },
            set: { isExpanded in
                releaseDrawerExpanded = isExpanded
                if !isExpanded {
                    pendingRelease = nil
                }
            }
        )
    }

    var body: some View {
        CardScroll(refreshAction: refreshLibrary) {
            connectionCard
            if library.visibleGroups.isEmpty {
                emptyCard
            } else {
                catalogOverviewCard
            }

            // Match ESP32 and FW Packages: only the folder tab participates
            // in the page layout. Release history slides over the overview.
            Color.clear.frame(height: 58)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if canShowReleaseDrawer {
                BottomFolderDrawer(
                    isExpanded: releaseDrawerBinding,
                    title: "FIRMWARE RELEASES",
                    summary: releaseDrawerSummary,
                    systemImage: "memorychip.fill",
                    accessibilityIdentifier: "firmware-releases-drawer-toggle",
                    panelHeight: releaseDrawerHeight,
                    maxPanelHeight: 420
                ) {
                    releaseDetailsPanel
                }
            }
        }
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Firmware help")
            }
        }
        .safeAreaInset(edge: .bottom) { progressBar }
        .sheet(isPresented: $showHelp) { FirmwareHelpView() }
        .sheet(item: $detailsRelease) { FirmwareReleaseDetailsView(release: $0) }
    }

    private var connectionCard: some View {
        SectionCard(
            title: "Ready to transfer",
            systemImage: "arrow.down.to.line.compact",
            accessory: AnyView(StatusPill(
                text: transfer.activeChannel.label,
                color: transfer.activeChannel == .usb ? Theme.info : .secondary,
                systemImage: transfer.activeChannel.systemImage
            ))
        ) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.installedVersion ?? "Flipper not identified")
                        .font(.subheadline).fontWeight(.semibold)
                    if let api = library.installedAPI {
                        Text("API \(api)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                phasePill
            }
        }
    }

    private func refreshLibrary() async {
        guard !library.busy else { return }
        await library.refreshAndWait()
    }

    private var channelPicker: some View {
        Picker("Channel", selection: Binding(
            get: { library.selectedChannel },
            set: { library.setChannel($0) }
        )) {
            Text("Main").tag(TumoflipFirmwareChannel.stable)
            Text("Dev").tag(TumoflipFirmwareChannel.dev)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .disabled(library.busy)
        .accessibilityIdentifier("firmware-channel-picker")
    }

    private var emptyCard: some View {
        SectionCard(title: "No releases", systemImage: "tray") {
            if library.busy {
                LoadingStateView(title: "Loading firmware releases…", compact: true)
            } else {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var emptyMessage: String {
        if library.busy { return "Loading releases..." }
        if library.selectedChannel == .dev {
            return "No Dev builds have been published after the latest Main release."
        }
        return "No Main firmware releases found."
    }

    private var catalogOverviewCard: some View {
        SectionCard(
            title: "Release catalog",
            systemImage: "memorychip.fill",
            accessory: AnyView(StatusPill(
                text: library.selectedChannel == .stable ? "Main" : "Dev",
                color: library.selectedChannel == .stable ? Theme.success : Theme.purple,
                systemImage: library.selectedChannel == .stable
                    ? "checkmark.seal.fill" : "hammer.fill"
            ))
        ) {
            if let latest = library.visibleReleases.first {
                firmwareOverviewRow(
                    title: "Latest build",
                    detail: latest.version,
                    systemImage: "sparkles"
                )
                firmwareOverviewRow(
                    title: "Published",
                    detail: releaseMetadata(latest),
                    systemImage: "calendar"
                )
            }
            firmwareOverviewRow(
                title: "Available",
                detail: releaseDrawerSummary,
                systemImage: "square.stack.3d.up.fill"
            )
            Text("Open the folder tab below to switch channels, inspect builds, and prepare an updater.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func firmwareOverviewRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var releaseDrawerSummary: String {
        let count = library.visibleReleases.count
        return "\(count) \(count == 1 ? "build" : "builds")"
    }

    private var canShowReleaseDrawer: Bool {
        !library.visibleGroups.isEmpty
            && !library.busy
            && !library.hasTerminalFeedback
    }

    private var releaseDrawerHeight: CGFloat {
        // A group with one release is already identified by its release row;
        // only multi-build Dev groups need an extra heading.
        let drawerChromeAndSections: CGFloat = 120
        let multiBuildHeaders = library.visibleGroups.filter { $0.releases.count > 1 }.count
        let groupHeaders = CGFloat(multiBuildHeaders) * 24
        let releaseRows = CGFloat(min(library.visibleReleases.count, 5)) * 36
        return min(420, max(230, drawerChromeAndSections + groupHeaders + releaseRows))
    }

    private var releaseDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("RELEASE CHANNEL", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.8)
                Spacer(minLength: 8)
                Text(library.selectedChannel == .stable ? "Main" : "Dev")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            channelPicker

            Divider().opacity(0.45)

            HStack(spacing: 7) {
                Label("AVAILABLE BUILDS", systemImage: "square.stack.3d.up")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.8)
                Spacer(minLength: 8)
                Text(releaseDrawerSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(library.visibleGroups) { group in
                    releaseGroupSection(group)
                }
            }
        }
    }

    private func releaseGroupSection(_ group: FirmwareVersionGroup) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if group.releases.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    Text("Version \(group.line)")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("\(group.releases.count) builds")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(group.releases.enumerated()), id: \.element.id) { index, release in
                compactReleaseRow(
                    release,
                    title: group.releases.count == 1
                        ? "Version \(group.line)"
                        : release.buildLabel,
                    isLatest: index == 0 && group.id == library.visibleGroups.first?.id
                )
                if pendingRelease?.id == release.id {
                    InlineActionConfirmationRow(
                        title: "Archive › update",
                        systemImage: "checkmark.shield.fill",
                        iconColor: Theme.success,
                        tint: Theme.accent,
                        confirmTitle: "Prepare",
                        confirmSystemImage: "arrow.down.to.line.compact",
                        accessibilityIdentifier: "firmware-preparation-confirmation",
                        cancelAccessibilityLabel: "Cancel preparation",
                        confirmAccessibilityLabel: "Confirm prepare \(release.version)",
                        onCancel: cancelPreparation,
                        onConfirm: { confirmPreparation(of: release) }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                if index < group.releases.count - 1 {
                    Divider().padding(.leading, 4)
                }
            }
        }
    }

    private func compactReleaseRow(
        _ release: FirmwareRelease,
        title: String,
        isLatest: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: library.selectedChannel == .dev ? "hammer.fill" : "checkmark.seal.fill")
                .font(.caption2)
                .foregroundStyle(Theme.accent)
                .frame(width: 16)

            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            if library.installedVersion == release.version {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.success)
                    .lineLimit(1)
            } else if isLatest {
                Text("Latest")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
            }

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                Button { detailsRelease = release } label: {
                    compactActionIcon(
                        "info.circle",
                        foreground: Theme.accent,
                        background: Theme.accent.opacity(0.12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(release.version)")

                Button { requestPreparation(of: release) } label: {
                    compactActionIcon(
                        "arrow.down.to.line.compact",
                        foreground: .white,
                        background: Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(library.busy || !hasTransferChannel)
                .accessibilityLabel(
                    library.installedVersion == release.version
                        ? "Prepare \(release.version) again"
                        : "Prepare \(release.version)"
                )
            }
        }
        .frame(minHeight: 31)
        .accessibilityIdentifier("firmware-release-\(release.version)")
    }

    private func compactActionIcon(
        _ systemName: String,
        foreground: Color,
        background: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: 24, height: 24)
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(foreground)
        }
        .frame(width: 29, height: 29)
        .contentShape(Rectangle())
    }

    private func releaseMetadata(_ release: FirmwareRelease) -> String {
        let date = release.publishedAt.formatted(date: .abbreviated, time: .omitted)
        let size = ByteCountFormatter.string(fromByteCount: release.updaterSize, countStyle: .file)
        return "\(date) · \(size)"
    }

    private var hasTransferChannel: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-firmware-library-layout-qa") {
            return true
        }
        #endif
        return transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private func requestPreparation(of release: FirmwareRelease) {
        library.clearTerminalFeedback()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingRelease = release
        }
    }

    private func cancelPreparation() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            pendingRelease = nil
        }
    }

    private func confirmPreparation(of release: FirmwareRelease) {
        pendingRelease = nil
        releaseDrawerExpanded = false
        Task { await library.stage(release) }
    }

    private func retryLastTransfer() {
        guard let release = library.lastAttemptedRelease else {
            library.refresh()
            return
        }
        requestPreparation(of: release)
    }

    @ViewBuilder private var phasePill: some View {
        switch library.phase {
        case .idle, .ready:
            StatusPill(text: "Ready", color: .secondary, systemImage: "circle")
        case .loading, .preparing, .downloading, .verifying, .staging, .done, .failed:
            EmptyView()
        }
    }

    @ViewBuilder private var progressBar: some View {
        switch library.phase {
        case .preparing(let version):
            transferProgress(title: "Preparing \(version)", fraction: nil)
        case .downloading(let version, let fraction):
            transferProgress(title: "Downloading \(version)", fraction: fraction)
        case .verifying(let version):
            transferProgress(title: "Verifying \(version)", fraction: nil)
        case .staging(let version, let file, let done, let total):
            transferProgress(
                title: "\(version) · \(file)",
                fraction: total > 0 ? Double(done) / Double(total) : nil,
                canStop: true)
        case .done(let message):
            resultBar(message, color: Theme.success, icon: "checkmark.circle.fill")
        case .failed(let message):
            resultBar(
                message,
                color: Theme.danger,
                icon: "exclamationmark.triangle.fill",
                actionTitle: "Retry",
                action: retryLastTransfer
            )
        default:
            EmptyView()
        }
    }

    private func transferProgress(title: String, fraction: Double?, canStop: Bool = false) -> some View {
        VStack(spacing: 8) {
            UnifiedProgressView(
                title: title,
                detail: fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) },
                fraction: fraction
            )
            if canStop {
                Button(role: .destructive) { library.requestStop() } label: {
                    Label(library.stopRequested ? "Stopping after this file" : "Stop",
                          systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(library.stopRequested)
            }
        }
        .padding()
        .background(.bar)
    }

    @ViewBuilder
    private func resultBar(
        _ message: String,
        color: Color,
        icon: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        if let actionTitle, let action {
            ActionableErrorView(
                title: "Firmware transfer failed",
                message: message,
                actionTitle: actionTitle,
                action: action
            )
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 10)
            .background(.bar)
        } else {
            Label(message, systemImage: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
        }
    }
}

private struct FirmwareReleaseDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    let release: FirmwareRelease

    var body: some View {
        NavigationStack {
            List {
                Section("Release") {
                    LabeledContent("Version", value: release.version)
                    LabeledContent(
                        "Channel",
                        value: release.channel == .stable ? "Main" : "Dev")
                    LabeledContent(
                        "Published",
                        value: release.publishedAt.formatted(date: .long, time: .shortened))
                    LabeledContent(
                        "Updater",
                        value: ByteCountFormatter.string(
                            fromByteCount: release.updaterSize, countStyle: .file))
                }
                if !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Notes") {
                        Text(release.notes).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(release.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct FirmwareHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("Choose Main or Dev, then select a release.", systemImage: "list.bullet")
                Label("Dev shows only builds published after the latest Main release.", systemImage: "clock.badge.checkmark")
                Label("The updater is verified with SHA-256 before transfer.", systemImage: "checkmark.shield")
                Label("Files are staged atomically; update.fuf is written last.", systemImage: "doc.badge.gearshape")
                Label("Start installation from Archive > update on the Flipper.", systemImage: "hand.tap")
            }
            .navigationTitle("Firmware help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct UpdatesHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("Firmware prepares a full Main or Dev updater.", systemImage: "memorychip")
                Label("FW Packages refresh Tumoflip apps and resources.", systemImage: "shippingbox")
                Label("Community apps installs compatible All The Plugins apps.", systemImage: "puzzlepiece.extension")
                Label("Keep the app open during BLE transfers.", systemImage: "iphone.radiowaves.left.and.right")
            }
            .navigationTitle("Updates help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
