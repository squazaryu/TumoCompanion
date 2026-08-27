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
        CardScroll(refreshAction: { await up.refresh() }) {
            statusCard
            if up.boards.isEmpty && up.archivedBoards.isEmpty && !up.busy { emptyCard }

            // Keep the normal state on one page. Board controls and version
            // history live in the adaptive drawer below, while this compact
            // summary remains visible next to the release status.
            Color.clear.frame(height: packageDrawerExpanded ? 8 : 2)
        }
        .navigationTitle("ESP32 Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if hasStagedPackages {
                packageDrawer
            }
        }
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
                                   color: up.updateAvailable ? .orange : .green,
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
                    color: currentChannel == .usb ? .blue : .secondary,
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
                    .foregroundStyle(.green)
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
            withAnimation(.snappy(duration: 0.26)) {
                packageDrawerExpanded = true
            }
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
                    color: newer ? .orange : .green,
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

    private func boardCard(_ b: ESP32Updater.Board) -> some View {
        let newer = up.newVersion(for: b)
        let archivedSource = up.isArchived(b)
        return SectionCard(title: b.display, systemImage: "memorychip",
                           accessory: AnyView(
                            StatusPill(text: newer ? "Update" : "Latest",
                                       color: newer ? .orange : .green,
                                       systemImage: newer ? "arrow.down.circle.fill" : "checkmark.circle.fill"))) {
            HStack {
                Text(archivedSource ? "Archived source" : "Active package")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(b.currentVersion).font(.caption).fontWeight(.medium)
            }
            if let tag = up.latestTag {
                HStack {
                    Text("Latest").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(tag).font(.caption).fontWeight(.medium)
                        .foregroundStyle(newer ? .orange : .green)
                }
            }
            Divider().opacity(0.4)
            if newer, let tag = up.latestTag {
                PillButton(title: "Update to \(tag) via \(currentChannel.label)", systemImage: "arrow.down.circle", tint: Theme.accent) {
                    Task { await up.install(b) }
                }
                .disabled(up.busy || !hasFileChannel)
            } else {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
                PillButton(title: "Download again via \(currentChannel.label)", systemImage: "arrow.down.circle", tint: Theme.accent) {
                    Task { await up.install(b) }
                }
                .disabled(up.busy || !hasFileChannel || !up.canStageLatest)
            }
            if archivedSource {
                Text("Creates a new active package. The archived copy stays unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Board key: \(b.key)").font(.caption2).foregroundStyle(.secondary)
        }
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

    /// Folder-tab drawer matching the Home Tools interaction. The collapsed tab
    /// is always visible; the full board controls and version history only take
    /// space after the user asks for them.
    private var packageDrawer: some View {
        VStack(spacing: 0) {
            if packageDrawerExpanded {
                packageDrawerPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.snappy(duration: 0.26)) {
                    packageDrawerExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption.weight(.bold))
                    Text("ESP32 PACKAGES")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                    Spacer(minLength: 8)
                    Text(drawerSummary)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: packageDrawerExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("esp32-packages-drawer-toggle")
            .accessibilityLabel("ESP32 packages")
            .accessibilityValue(packageDrawerExpanded ? "Expanded" : "Collapsed")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.pagePadding)
    }

    private var packageDrawerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)

            HStack(spacing: 7) {
                Label("ESP32 PACKAGES", systemImage: "folder")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
                Text(drawerSummary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(up.stagingBoards) { board in
                        boardCard(board)
                    }
                    if !up.versionGroups.isEmpty {
                        versionManagerCard
                    }
                }
            }
            .frame(maxHeight: packageDrawerPanelHeight)
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
    }

    private var packageDrawerPanelHeight: CGFloat {
        let boardHeight = CGFloat(up.stagingBoards.count) * 154
        let historyHeight: CGFloat = up.versionGroups.isEmpty ? 0 : 90
        return min(max(CGFloat(150), boardHeight + historyHeight), CGFloat(340))
    }

    private var drawerSummary: String {
        let boards = up.stagingBoards.count
        let updates = up.stagingBoards.filter { up.newVersion(for: $0) }.count
        if updates > 0 { return "\(updates) update\(updates == 1 ? "" : "s")" }
        return "\(boards) board\(boards == 1 ? "" : "s")"
    }

    private var versionManagerCard: some View {
        CollapsibleCard(title: "Firmware versions", systemImage: "clock.arrow.circlepath",
                        accessory: AnyView(StatusPill(text: "\(up.versionGroups.count)", color: .secondary))) {
            Text("Choose a staged Marauder version per board key. Active folders are visible to esp_flasher; archived folders are hidden until restored.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !up.olderBoards.isEmpty {
                PillButton(title: "Archive all active older", systemImage: "archivebox", tint: Theme.accent) {
                    Task { await up.archiveOlder() }
                }
                .disabled(up.busy)
            }

            VStack(spacing: 10) {
                ForEach(up.versionGroups) { group in
                    DisclosureGroup(isExpanded: versionGroupBinding(group.key)) {
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
                        .padding(.top, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.display)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(group.key)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(group.versions.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.secondary)
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
                .foregroundStyle(location == .current ? .green : .secondary)
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

    private func versionGroupBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedVersionGroups.contains(key) },
            set: { expanded in
                if expanded {
                    expandedVersionGroups.insert(key)
                } else {
                    expandedVersionGroups.remove(key)
                }
            }
        )
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
