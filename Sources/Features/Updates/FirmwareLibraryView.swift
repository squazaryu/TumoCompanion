import SwiftUI

struct FirmwareLibraryView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var transfer: TransferChannelStore
    @ObservedObject var library: FirmwareLibrary
    @State private var showHelp = false
    @State private var pendingRelease: FirmwareRelease?
    @State private var detailsRelease: FirmwareRelease?
    @State private var releaseDrawerExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
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

            if !library.visibleGroups.isEmpty, !library.busy {
                BottomFolderDrawer(
                    isExpanded: $releaseDrawerExpanded,
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
                if library.busy { ProgressView() }
            }
        }
        .safeAreaInset(edge: .bottom) { progressBar }
        .sheet(isPresented: $showHelp) { FirmwareHelpView() }
        .sheet(item: $detailsRelease) { FirmwareReleaseDetailsView(release: $0) }
        .confirmationDialog(
            "Prepare this firmware?",
            isPresented: Binding(
                get: { pendingRelease != nil },
                set: { if !$0 { pendingRelease = nil } }
            ),
            presenting: pendingRelease
        ) { release in
            Button("Prepare \(release.version)") {
                Task { await library.stage(release) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { release in
            Text("The verified updater will be copied to Archive > update. Installation still starts on the Flipper.")
        }
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

    private var releaseDrawerHeight: CGFloat {
        // Include the drawer handle/padding and the real action-row footprint.
        // The old estimate was smaller than the rendered content, so the last
        // release could sit underneath the folder tab even with only two builds.
        let drawerChromeAndSections: CGFloat = 132
        let groupHeaders = CGFloat(library.visibleGroups.count) * 30
        let releaseRows = CGFloat(min(library.visibleReleases.count, 5)) * 56
        return min(420, max(280, drawerChromeAndSections + groupHeaders + releaseRows))
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: library.selectedChannel == .dev ? "hammer.fill" : "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text("Version \(group.line)")
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(group.releases.count) \(group.releases.count == 1 ? "build" : "builds")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(group.releases.enumerated()), id: \.element.id) { index, release in
                compactReleaseRow(
                    release,
                    isLatest: index == 0 && group.id == library.visibleGroups.first?.id
                )
                if index < group.releases.count - 1 {
                    Divider().padding(.leading, 4)
                }
            }
        }
    }

    private func compactReleaseRow(_ release: FirmwareRelease, isLatest: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(library.selectedChannel == .stable ? release.version : release.buildLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                    if library.installedVersion == release.version {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.success)
                    } else if isLatest {
                        Text("Latest")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(releaseMetadata(release))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            HStack(spacing: 0) {
                Button { detailsRelease = release } label: {
                    compactActionIcon(
                        "info.circle",
                        foreground: Theme.accent,
                        background: Theme.accent.opacity(0.12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(release.version)")

                Button { pendingRelease = release } label: {
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
        .padding(.vertical, 1)
    }

    private func compactActionIcon(
        _ systemName: String,
        foreground: Color,
        background: Color
    ) -> some View {
        ZStack {
            Circle()
                .fill(background)
                .frame(width: 28, height: 28)
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foreground)
        }
        .frame(width: 34, height: 34)
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

    @ViewBuilder private var phasePill: some View {
        switch library.phase {
        case .done:
            StatusPill(text: "Prepared", color: Theme.success, systemImage: "checkmark.circle.fill")
        case .failed:
            StatusPill(text: "Error", color: Theme.danger, systemImage: "exclamationmark.triangle.fill")
        case .loading, .downloading, .verifying, .staging:
            ProgressView().scaleEffect(0.85)
        case .idle, .ready:
            StatusPill(text: "Ready", color: .secondary, systemImage: "circle")
        }
    }

    @ViewBuilder private var progressBar: some View {
        switch library.phase {
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
                action: { library.refresh() }
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
