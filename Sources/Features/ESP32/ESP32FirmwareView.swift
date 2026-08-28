import SwiftUI

@MainActor
struct ESP32FirmwareView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @StateObject private var up: ESP32Updater
    @State private var expandedVersionGroups: Set<String> = []
    @State private var packageDrawerExpanded = false
    @State private var deleteTarget: ESP32Updater.Board?
    @State private var deleteAll = false
    @State private var deleteArchived = false

    init() {
        _up = StateObject(wrappedValue: ESP32Updater())
    }

    init(updater: ESP32Updater) {
        _up = StateObject(wrappedValue: updater)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CardScroll(refreshAction: { await up.refresh() }) {
                statusCard
                if up.boards.isEmpty && up.archivedBoards.isEmpty && !up.busy { emptyCard }

                // The folder tab is fixed above the app tab bar, just like
                // Home → Tools. Keep only its collapsed footprint in the page
                // content so the overview remains one screen tall.
                Color.clear.frame(height: 58)
            }

            if hasStagedPackages {
                BottomFolderDrawer(
                    isExpanded: $packageDrawerExpanded,
                    title: "ESP32 PACKAGES",
                    summary: drawerSummary,
                    systemImage: "folder.fill",
                    accessibilityIdentifier: "esp32-packages-drawer-toggle",
                    panelHeight: packageDrawerHeight
                ) {
                    esp32DetailsPanel
                }
            }
        }
        .navigationTitle("ESP32 Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .task { if up.latestTag == nil { await up.refresh() } }
        .alert("Remove this folder?", isPresented: Binding(
            get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let b = deleteTarget { Task { await up.delete(b) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Removes \(deleteTarget?.display ?? "") \(deleteTarget?.currentVersion ?? "") staged on the SD. The firmware already flashed on the ESP32 isn't affected.")
        }
        .alert("Delete all active older versions?", isPresented: $deleteAll) {
            Button("Delete \(up.olderBoards.count)", role: .destructive) { Task { await up.deleteOlder() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every outdated active flash folder from the SD, keeping the newest of each board. Archived folders are not affected.")
        }
        .alert("Delete archived versions?", isPresented: $deleteArchived) {
            Button("Delete \(up.archivedBoards.count)", role: .destructive) { Task { await up.deleteArchived() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every archived ESP32 flash folder from the SD. The firmware already flashed on the ESP32 isn't affected.")
        }
    }

    private var statusCard: some View {
        SectionCard(title: "ESP32 Marauder", systemImage: "cpu",
                    accessory: up.latestTag == nil ? nil : AnyView(
                        StatusPill(text: up.updateAvailable ? "Update" : "Latest",
                                   color: up.updateAvailable ? Theme.warning : Theme.success,
                                   systemImage: up.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle.fill"))) {
            HStack {
                Text("Latest release").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(up.latestTag ?? "—").font(.subheadline).fontWeight(.semibold)
            }
            if up.busy, let p = up.progress {
                ProgressView(value: p)
                if let d = up.progressText {
                    Text(d).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if up.busy {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Label("File channel", systemImage: currentChannel.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                StatusPill(
                    text: currentChannel.label,
                    color: currentChannel == .usb ? Theme.info : .secondary,
                    systemImage: currentChannel.systemImage
                )
            }
            if let s = up.status {
                Text(s).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if up.verifiedPackageAvailable {
                Label("Verified full installer package", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            }

            if !up.stagingBoards.isEmpty {
                Divider().opacity(0.4)
                ForEach(up.stagingBoards) { board in
                    boardSummaryRow(board)
                }
            }

            Text("Packages are staged on the Flipper SD and flashed from esp_flasher.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func boardSummaryRow(_ board: ESP32Updater.Board) -> some View {
        let newer = up.newVersion(for: board)
        return Button {
            packageDrawerExpanded = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(board.display)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(board.currentVersion)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: newer ? "Update" : "Latest",
                    color: newer ? Theme.warning : Theme.success,
                    systemImage: newer ? "arrow.down.circle.fill" : "checkmark.circle.fill"
                )
                Image(systemName: "chevron.up")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("esp32-board-summary-\(board.key)")
        .accessibilityLabel("Open \(board.display) package details")
    }

    private var currentChannel: TransferChannel {
        up.busy ? up.transferChannel : transfer.activeChannel
    }

    private var hasFileChannel: Bool {
        transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private var hasStagedPackages: Bool {
        !up.stagingBoards.isEmpty || !up.versionGroups.isEmpty
    }

    private var esp32DetailsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label("ESP32 PACKAGES", systemImage: "folder")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                Text(drawerSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if !up.stagingBoards.isEmpty {
                VStack(spacing: 7) {
                    ForEach(up.stagingBoards) { board in
                        packageBoardRow(board)
                    }
                }
            }

            if !up.versionGroups.isEmpty {
                Divider().opacity(0.45)
                HStack(spacing: 7) {
                    Label("VERSION HISTORY", systemImage: "clock.arrow.circlepath")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.primary.opacity(0.62))
                        .tracking(0.8)
                    Spacer()
                    Text("\(up.versionGroups.count) board\(up.versionGroups.count == 1 ? "" : "s")")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
                versionManagerCard
            }
        }
    }

    private var drawerSummary: String {
        let boards = up.stagingBoards.count
        let updates = up.stagingBoards.filter { up.newVersion(for: $0) }.count
        if updates > 0 { return "\(updates) update\(updates == 1 ? "" : "s")" }
        return "\(boards) board\(boards == 1 ? "" : "s")"
    }

    private var packageDrawerHeight: CGFloat {
        // Match Home → Tools: the drawer grows with the number of visible
        // cards, while a longer history remains scrollable inside the drawer.
        let boardRows = CGFloat(max(up.stagingBoards.count, 1)) * 90
        // Version history is intentionally a compact preview. Its rows remain
        // scrollable inside the drawer, so the tab never grows a large empty
        // tail just because an archive exists on disk.
        let history = up.versionGroups.isEmpty ? 0 : min(80, up.versionGroups.count * 40)
        // Include enough drawer chrome to leave only a deliberate visual gap
        // below the overview card instead of a large unused band.
        let drawerChrome: CGFloat = 84
        return min(500, max(220, drawerChrome + boardRows + CGFloat(history)))
    }

    /// A compact board row for the drawer. The release summary already exposes
    /// the board list, so the expanded view only adds the action and provenance
    /// needed to download or restore a package.
    private func packageBoardRow(_ board: ESP32Updater.Board) -> some View {
        let newer = up.newVersion(for: board)
        let archivedSource = up.isArchived(board)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "memorychip")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(board.display)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("\(archivedSource ? "Archived" : "Active") · \(board.currentVersion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: newer ? "Update" : "Latest",
                    color: newer ? Theme.warning : Theme.success,
                    systemImage: newer ? "arrow.down.circle.fill" : "checkmark.circle.fill"
                )
            }

            HStack(spacing: 8) {
                Text("Latest \(up.latestTag ?? "—")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(newer ? Theme.warning : Color.secondary)
                Spacer(minLength: 8)
                if newer, let tag = up.latestTag {
                    packageActionButton(
                        title: "Update to \(tag)",
                        enabled: !up.busy && hasFileChannel
                    ) {
                        Task { await up.install(board) }
                    }
                } else {
                    packageActionButton(
                        title: "Download again",
                        enabled: !up.busy && hasFileChannel && up.canStageLatest
                    ) {
                        Task { await up.install(board) }
                    }
                }
            }
            if archivedSource {
                Text("Archived copy stays unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func packageActionButton(
        title: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.down.circle")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.accent : Color.secondary)
        .background(
            (enabled ? Theme.accent : Color.secondary).opacity(enabled ? 0.16 : 0.12),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .strokeBorder(
                    (enabled ? Theme.accent : Color.secondary).opacity(0.26),
                    lineWidth: 1
                )
        }
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private var versionManagerCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !up.olderBoards.isEmpty {
                PillButton(title: "Archive all active older", systemImage: "archivebox", tint: Theme.accent) {
                    Task { await up.archiveOlder() }
                }
                .disabled(up.busy)
            }

            VStack(spacing: 6) {
                ForEach(up.versionGroups) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Button {
                            toggleVersionGroup(group.key)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "memorychip")
                                    .font(.caption2)
                                    .foregroundStyle(Color.primary.opacity(0.58))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(group.display)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text("\(group.versions.count) version\(group.versions.count == 1 ? "" : "s")")
                                        .font(.caption2)
                                        .foregroundStyle(Color.primary.opacity(0.58))
                                }
                                Spacer(minLength: 8)
                                Image(systemName: expandedVersionGroups.contains(group.key)
                                      ? "chevron.up" : "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("esp32-version-group-\(group.key)")
                        .accessibilityValue(
                            expandedVersionGroups.contains(group.key) ? "Expanded" : "Collapsed"
                        )

                        if expandedVersionGroups.contains(group.key) {
                            VStack(spacing: 8) {
                                if let current = group.current {
                                    versionRow(current, location: .current)
                                }
                                ForEach(group.activeOlder) { board in
                                    versionRow(board, location: .activeOlder)
                                }
                                ForEach(group.archived) { board in
                                    versionRow(board, location: .archived)
                                }
                            }
                            .padding(.leading, 25)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            HStack {
                if up.olderBoards.count > 1 {
                    Button(role: .destructive) { deleteAll = true } label: {
                        Label("Delete active older", systemImage: "trash").font(.caption)
                    }
                    .disabled(up.busy)
                }
                if up.archivedBoards.count > 1 {
                    Button(role: .destructive) { deleteArchived = true } label: {
                        Label("Delete archive", systemImage: "trash").font(.caption)
                    }
                    .disabled(up.busy)
                }
            }
        }
    }

    private enum VersionLocation {
        case current
        case activeOlder
        case archived

        var label: String {
            switch self {
            case .current: return "Active"
            case .activeOlder: return "Older"
            case .archived: return "Archived"
            }
        }

        var icon: String {
            switch self {
            case .current: return "checkmark.circle.fill"
            case .activeOlder: return "exclamationmark.circle"
            case .archived: return "archivebox"
            }
        }
    }

    private func versionRow(_ b: ESP32Updater.Board, location: VersionLocation) -> some View {
        HStack {
            Image(systemName: location.icon)
                .foregroundStyle(location == .current ? Theme.success : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.currentVersion).font(.subheadline)
                Text(location.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch location {
            case .current:
                Label("visible", systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .activeOlder:
                Button { Task { await up.archive(b) } } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
                Button(role: .destructive) { deleteTarget = b } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
            case .archived:
                Button { Task { await up.restore(b) } } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
                Button(role: .destructive) { deleteTarget = b } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(up.busy)
            }
        }
        .contentShape(Rectangle())
    }

    private func toggleVersionGroup(_ key: String) {
        if expandedVersionGroups.contains(key) {
            expandedVersionGroups.remove(key)
        } else {
            expandedVersionGroups.insert(key)
        }
    }

    private var emptyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
            Text("No Marauder flash folders found under esp_flasher. Flash once with the Flipper’s esp_flasher app to create one, then updates land here.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
