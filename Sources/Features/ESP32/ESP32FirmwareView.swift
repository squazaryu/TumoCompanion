import SwiftUI

@MainActor
struct ESP32FirmwareView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @StateObject private var up: ESP32Updater
    @State private var expandedVersionGroups: Set<String> = []
    @State private var packageDrawerExpanded = false
    @State private var versionHistoryExpanded = false
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

            if hasStagedPackages {
                packageDrawer
            }
            if !up.versionGroups.isEmpty {
                versionHistoryDrawer
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
    @ViewBuilder
    private var packageDrawer: some View {
        if packageDrawerExpanded {
            VStack(spacing: 0) {
                packageDrawerPanel
                packageDrawerTab(expanded: true)
            }
        } else {
            packageDrawerTab(expanded: false)
        }
    }

    private func packageDrawerTab(expanded: Bool) -> some View {
        Button {
            packageDrawerExpanded.toggle()
            if packageDrawerExpanded { versionHistoryExpanded = false }
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
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGroupedBackground), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("esp32-packages-drawer-toggle")
        .accessibilityLabel("ESP32 packages")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    /// Version history is intentionally a separate drawer. The board overview
    /// should never end with a partially visible archive card when two boards
    /// are present, while archive/restore/delete controls remain discoverable.
    @ViewBuilder
    private var versionHistoryDrawer: some View {
        if versionHistoryExpanded {
            VStack(spacing: 0) {
                versionHistoryPanel
                versionHistoryTab(expanded: true)
            }
        } else {
            versionHistoryTab(expanded: false)
        }
    }

    private func versionHistoryTab(expanded: Bool) -> some View {
        Button {
            versionHistoryExpanded.toggle()
            if versionHistoryExpanded { packageDrawerExpanded = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.bold))
                Text("VERSION HISTORY")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                Spacer(minLength: 8)
                Text("\(up.versionGroups.count) board\(up.versionGroups.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGroupedBackground), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("esp32-version-history-toggle")
        .accessibilityLabel("ESP32 version history")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private var versionHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)

            HStack(spacing: 7) {
                Label("VERSION HISTORY", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
                Spacer()
                Text("\(up.versionGroups.count) board\(up.versionGroups.count == 1 ? "" : "s")")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // The parent CardScroll is the single scrolling surface for this
            // screen. Let the history drawer size itself instead of nesting a
            // capped ScrollView that can clip archive controls.
            versionManagerCard
                .padding(.bottom, 2)
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

            // Keep one page-level scrolling surface. The drawer grows to the
            // number of board cards, so C5 and Module One can never be clipped
            // or painted behind the folder tab.
            VStack(spacing: 12) {
                ForEach(up.stagingBoards) { board in
                    packageBoardRow(board)
                }
            }
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

    private var drawerSummary: String {
        let boards = up.stagingBoards.count
        let updates = up.stagingBoards.filter { up.newVersion(for: $0) }.count
        if updates > 0 { return "\(updates) update\(updates == 1 ? "" : "s")" }
        return "\(boards) board\(boards == 1 ? "" : "s")"
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
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(archivedSource ? "Archived" : "Active") · \(board.currentVersion)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: newer ? "Update" : "Latest",
                    color: newer ? .orange : .green,
                    systemImage: newer ? "arrow.down.circle.fill" : "checkmark.circle.fill"
                )
            }

            HStack(spacing: 8) {
                Text("Latest \(up.latestTag ?? "—")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(newer ? .orange : .secondary)
                Spacer(minLength: 8)
                if newer, let tag = up.latestTag {
                    Button("Update to \(tag)") { Task { await up.install(board) } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(up.busy || !hasFileChannel)
                } else {
                    Button("Download again") { Task { await up.install(board) } }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .disabled(up.busy || !hasFileChannel || !up.canStageLatest)
                }
            }
            if archivedSource {
                Text("Archived copy stays unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
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
