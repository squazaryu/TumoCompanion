import SwiftUI

/// Detail screen for the "Community apps" source (all-the-plugins). Reached by tapping
/// its row in the unified Updates "Sources" list — this is the only place the per-file
/// diff list (potentially 50-300+ rows) is allowed to render, keeping the parent
/// dashboard's height constant regardless of how large the pending diff is.
struct PluginUpdatesDetailView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject var updater: PluginUpdater
    @State private var showReleasePicker = false
    @State private var expandedCategories: Set<String> = []   // collapsed by default
    @State private var incompatibleExpanded = false
    @State private var showHelp = false
    @State private var showCleanupConfirmation = false
    @State private var detailsDrawerExpanded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            CardScroll(refreshAction: refreshCommunityApps) {
                communityStatusCard
                communityOverviewCard
                communityActionBar

                // Keep only the folder tab's collapsed footprint in the page.
                // Release selection and long app lists slide over the overview.
                Color.clear.frame(height: 58)
            }

            BottomFolderDrawer(
                isExpanded: $detailsDrawerExpanded,
                title: "APP DETAILS",
                summary: communityDetailsSummary,
                systemImage: "puzzlepiece.extension.fill",
                accessibilityIdentifier: "community-apps-details-drawer-toggle",
                panelHeight: communityDetailsDrawerHeight,
                maxPanelHeight: 420
            ) {
                communityDetailsPanel
            }
        }
        .navigationTitle("Community apps")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Community apps help")
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { HistoryView(updater: updater) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        updater.resetBaseline()
                        Task { await updater.check() }   // forces the baseline choice → re-scan
                    } label: {
                        Label("Reset baseline / re-scan Flipper", systemImage: "arrow.clockwise.circle")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(busy)
            }
        }
        .onAppear { if case .idle = updater.phase, updater.updates.isEmpty { Task { await updater.check() } } }
        .sheet(isPresented: $showReleasePicker) {
            NavigationStack { PluginReleasePickerView(updater: updater) }
        }
        .sheet(isPresented: $showHelp) { CommunityAppsHelpView() }
        .alert("Clean up old Community app routes?", isPresented: $showCleanupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clean Up \(updater.pendingCleanupCount)", role: .destructive) {
                Task { await updater.cleanUpPendingRoutes() }
            }
        } message: {
            Text(
                "Only exact files recorded from an older Community Pack are eligible. "
                + "Tumoflip-protected, custom, modified, or unverified files are kept."
            )
        }
    }

    private var communityStatusCard: some View {
        SectionCard(
            title: "Community apps",
            systemImage: "shippingbox",
            accessory: AnyView(StatusPill(
                text: transfer.activeChannel.label,
                color: transfer.activeChannel == .usb ? .blue : .secondary,
                systemImage: transfer.activeChannel.systemImage
            ))
        ) {
            statusRow
            if updater.canVerifyOnDevice {
                PillButton(
                    title: "Verify on device",
                    systemImage: "checkmark.seal",
                    tint: .secondary
                ) {
                    Task { await updater.verifyInstalled() }
                }
                .disabled(busy || !hasFileChannel)
            }
        }
    }

    private var communityOverviewCard: some View {
        SectionCard(
            title: "Community catalog",
            systemImage: "puzzlepiece.extension.fill",
            accessory: AnyView(StatusPill(
                text: updater.manualReleaseTag ?? "Auto",
                color: updater.manualReleaseTag == nil ? .secondary : .orange,
                systemImage: updater.manualReleaseTag == nil ? "wand.and.stars" : "pin.fill"
            ))
        ) {
            communityOverviewRow(
                title: "Release",
                detail: updater.tag.isEmpty ? "Not checked" : updater.tag,
                systemImage: "tag"
            )
            communityOverviewRow(
                title: "Changes",
                detail: communityChangesSummary,
                systemImage: "checklist"
            )
            communityOverviewRow(
                title: "Last run",
                detail: communityLastRunSummary,
                systemImage: lastRunNeedsAttention
                    ? "exclamationmark.triangle.fill" : "checkmark.seal"
            )
            Text("Pull down to check again. Open the folder tab below for releases, app selection, and audit details.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func communityOverviewRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(lastRunNeedsAttention && title == "Last run" ? .orange : Theme.accent)
                .frame(width: 22)
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
    }

    private var communityChangesSummary: String {
        if updater.phase == .needsBaseline { return "First sync required" }
        if !updater.updates.isEmpty {
            return "\(updater.updates.count) changed · \(updater.selectedCount) selected"
        }
        if busy { return "Checking…" }
        return updater.tag.isEmpty ? "Not checked" : "Up to date"
    }

    private var communityLastRunSummary: String {
        if let result = updater.verifyResult {
            return result.ok
                ? "\(result.verified) verified"
                : "\(result.failed.count) need review"
        }
        if let cleanup = updater.lastCleanup {
            return cleanup.kept.isEmpty
                ? "\(cleanup.removed.count) cleaned"
                : "\(cleanup.kept.count) kept for review"
        }
        return "No device check yet"
    }

    @ViewBuilder
    private var communityActionBar: some View {
        if case .installing = updater.phase {
            compactCommunityAction(
                title: updater.stopRequested ? "Stopping…" : "Stop install",
                systemImage: "stop.circle.fill",
                tint: .red,
                role: .destructive,
                action: updater.requestStop
            )
            .disabled(updater.stopRequested)
        } else if !busy,
                  updater.selectedCount > 0 || updater.pendingCleanupCount > 0 {
            HStack(spacing: 10) {
                if updater.selectedCount > 0 {
                    compactCommunityAction(
                        title: "Install \(updater.selectedCount)",
                        systemImage: "square.and.arrow.down.on.square",
                        tint: Theme.accent,
                        action: { Task { await updater.install() } }
                    )
                    .disabled(!hasFileChannel || updater.validating)
                    .accessibilityIdentifier("community-install-action")
                }
                if updater.pendingCleanupCount > 0 {
                    compactCommunityAction(
                        title: "Clean Up \(updater.pendingCleanupCount)",
                        systemImage: "trash",
                        tint: .orange,
                        role: .destructive,
                        action: { showCleanupConfirmation = true }
                    )
                    .disabled(!hasFileChannel)
                    .accessibilityIdentifier("community-cleanup-action")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    private func compactCommunityAction(
        title: String,
        systemImage: String,
        tint: Color,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(tint)
                .background(tint.opacity(0.13), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var communityDetailsSummary: String {
        if updater.phase == .needsBaseline { return "First sync" }
        if !updater.updates.isEmpty {
            return "\(updater.updates.count) update\(updater.updates.count == 1 ? "" : "s")"
        }
        return updater.tag.isEmpty ? "Not checked" : "Up to date"
    }

    private var communityDetailsDrawerHeight: CGFloat {
        let releaseSection: CGFloat = 82
        let baselineSection: CGFloat = updater.phase == .needsBaseline ? 100 : 0
        let categoryRows = CGFloat(min(max(installCategories.count, 1), 4)) * 40
        let updateSection: CGFloat = updater.updates.isEmpty ? 36 : 42 + categoryRows
        let lastRunSection: CGFloat = updater.verifyResult != nil || updater.lastCleanup != nil ? 110 : 0
        return min(420, max(240, releaseSection + baselineSection + updateSection + lastRunSection))
    }

    private var communityDetailsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label("COMMUNITY RELEASE", systemImage: "tag")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.8)
                Spacer(minLength: 8)
                StatusPill(
                    text: updater.manualReleaseTag ?? "Auto",
                    color: updater.manualReleaseTag == nil ? .secondary : .orange,
                    systemImage: updater.manualReleaseTag == nil ? "wand.and.stars" : "pin.fill"
                )
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(updater.tag.isEmpty ? "No release loaded" : updater.tag)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(updater.manualReleaseTag == nil ? "Latest compatible release" : "Pinned release")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { showReleasePicker = true } label: {
                    Label("Choose", systemImage: "list.bullet")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.accent.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("community-release-picker-action")
            }

            if updater.phase == .needsBaseline {
                Divider().opacity(0.45)
                firstSyncDetails
            }

            if !updater.updates.isEmpty || !updater.blockedUpdates.isEmpty {
                Divider().opacity(0.45)
                changedAppsDetails
            }

            if updater.verifyResult != nil || updater.lastCleanup != nil {
                Divider().opacity(0.45)
                lastRunDetails
            }
        }
    }

    private var firstSyncDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("FIRST SYNC", systemImage: "scope")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.primary.opacity(0.62))
                .tracking(0.8)
            HStack(spacing: 8) {
                compactCommunityAction(
                    title: "Scan Flipper",
                    systemImage: "magnifyingglass",
                    tint: Theme.accent,
                    action: { Task { await updater.scanBaseline() } }
                )
                .disabled(!hasFileChannel)
                compactCommunityAction(
                    title: "Already installed",
                    systemImage: "checkmark.circle",
                    tint: .secondary,
                    action: updater.seedBaseline
                )
            }
        }
    }

    private var changedAppsDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label("CHANGED APPS", systemImage: "checklist")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .tracking(0.8)
                Spacer(minLength: 8)
                selectMenu
            }
            if updater.changedFromScan > 0 {
                Label(
                    "\(updater.changedFromScan) local build\(updater.changedFromScan == 1 ? "" : "s") left unselected",
                    systemImage: "exclamationmark.shield.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            LazyVStack(spacing: 6) {
                ForEach(installCategories, id: \.self) { category in
                    categorySection(category)
                }
                if !updater.blockedUpdates.isEmpty { incompatibleSection }
            }
        }
    }

    private var lastRunDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Label(
                    "LAST RUN",
                    systemImage: lastRunNeedsAttention
                        ? "exclamationmark.triangle.fill" : "checkmark.seal"
                )
                .font(.caption.weight(.bold))
                .foregroundStyle(lastRunNeedsAttention ? .orange : Color.primary.opacity(0.62))
                .tracking(0.8)
                Spacer(minLength: 8)
                lastRunPills
            }
            if let result = updater.verifyResult {
                verifyDetail(result)
            }
            if let cleanup = updater.lastCleanup {
                if updater.verifyResult != nil { Divider().opacity(0.35) }
                cleanupDetail(cleanup)
            }
        }
    }

    /// Bulk-selection menu used in the bottom app-details drawer.
    private var selectMenu: some View {
        Menu {
            Button("Select all") { select { _ in true } }
            Button("Deselect all") { select { _ in false } }
            Divider()
            Button("Only new") { select(\.isNew) }
            Button("Only updates") { select { !$0.isNew } }
            Divider()
            Button("Only base pack") { select { $0.pack == "base" } }
            Button("Only extra pack") { select { $0.pack == "extra" } }
        } label: {
            HStack(spacing: 4) {
                Text("\(updater.selectedCount)/\(updater.installableUpdates.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "checklist").font(.caption).foregroundStyle(Theme.accent)
            }
        }
    }

    private var hasFileChannel: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-community-apps-layout-qa") {
            return true
        }
        #endif
        return transfer.activeChannel == .usb || ble.state == .ready || ble.state == .connected
    }

    private func refreshCommunityApps() async {
        guard !busy else { return }
        await updater.check()
        if hasFileChannel { await updater.validateCompatibility() }
    }

    private var busy: Bool {
        if updater.validating { return true }
        switch updater.phase {
        case .fetching, .downloading, .scanning, .installing, .cleaning, .verifying:
            return true
        default: return false
        }
    }

    /// Whether the consolidated "Last run" card should open expanded — only when there's
    /// something that actually needs a look (a failed verify, or a duplicate kept for
    /// manual review), not just routine "everything's fine" output.
    private var lastRunNeedsAttention: Bool {
        if let vr = updater.verifyResult, !vr.ok { return true }
        if let cl = updater.lastCleanup, !cl.kept.isEmpty { return true }
        return false
    }

    private var lastRunPills: some View {
        HStack(spacing: 6) {
            if let vr = updater.verifyResult { verifyPills(vr) }
            if let cl = updater.lastCleanup { cleanupPills(cl) }
        }
    }

    private func verifyPills(_ vr: VerifyResult) -> some View {
        HStack(spacing: 6) {
            Text("\(vr.verified)✓").font(.caption).foregroundStyle(.green)
            if !vr.ok { Text("\(vr.failed.count)✗").font(.caption).foregroundStyle(.orange) }
        }
    }

    private func cleanupPills(_ cl: CleanupResult) -> some View {
        HStack(spacing: 6) {
            if !cl.removed.isEmpty { Text("\(cl.removed.count) removed").font(.caption).foregroundStyle(.green) }
            if !cl.kept.isEmpty { Text("\(cl.kept.count) kept").font(.caption).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder private func cleanupDetail(_ cl: CleanupResult) -> some View {
        if !cl.removed.isEmpty {
            Text("Removed obsolete Community Pack route\(cl.removed.count == 1 ? "" : "s") (verified history):")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("community-cleanup-removed")
            Text(cl.removed.prefix(12).joined(separator: "\n") + (cl.removed.count > 12 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("community-cleanup-removed-paths")
        }
        if !cl.kept.isEmpty {
            Text(
                "Kept legacy file\(cl.kept.count == 1 ? "" : "s") for review "
                + "(not verified as an old pack build — possible custom/modified file):"
            )
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("community-cleanup-kept")
            Text(cl.kept.prefix(12).joined(separator: "\n") + (cl.kept.count > 12 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("community-cleanup-kept-paths")
        }
    }

    @ViewBuilder private func verifyDetail(_ vr: VerifyResult) -> some View {
        HStack(spacing: 8) {
            StatusPill(text: "\(vr.verified) verified", color: .green, systemImage: "checkmark.circle.fill")
            if !vr.ok {
                StatusPill(text: "\(vr.failed.count) failed", color: .orange, systemImage: "xmark.circle.fill")
            }
            Spacer()
            Text(vr.tag).font(.caption2).foregroundStyle(.secondary)
        }
        if !vr.ok {
            Text(vr.failed.prefix(8).joined(separator: "\n") + (vr.failed.count > 8 ? "\n…" : ""))
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Listed below — tap Install to (re)install them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Distinct install-location categories (the `/ext/apps/<category>/` folder each
    /// app actually lands in), alphabetical, with the uncategorised bucket last.
    private var installCategories: [String] {
        Set(updater.installableUpdates.map(\.targetCategory)).sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// One install-category section: collapsed by default. The header has TWO tap
    /// targets — a checkbox that selects/deselects the whole category (skip e.g. Games
    /// in one tap), and the rest of the row which expands to reveal each app's own
    /// toggle. Kept as sibling buttons so the checkbox tap never triggers expand.
    @ViewBuilder private func categorySection(_ category: String) -> some View {
        let items = updater.installableUpdates.filter { $0.targetCategory == category }
        let sel = items.filter(\.selected).count
        let box = sel == 0 ? "square" : (sel == items.count ? "checkmark.square.fill" : "minus.square.fill")
        let isOpen = expandedCategories.contains(category)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { setSelected(sel < items.count, inCategory: category) } label: {
                    Image(systemName: box)
                        .font(.body)
                        .foregroundStyle(sel == 0 ? Color.secondary : Theme.accent)
                        .frame(width: 26, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation(.snappy) { toggleExpanded(category) }
                } label: {
                    HStack(spacing: 6) {
                        Text(category.isEmpty ? "Other" : category)
                            .font(.subheadline).fontWeight(.medium)
                        Text("\(sel)/\(items.count)")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if isOpen {
                ForEach(items) { u in
                    row(for: u)
                        .padding(.leading, 28)
                        .contextMenu {
                            Button { updater.addExclusion(u.name) } label: {
                                Label("Protect (never update)", systemImage: "lock")
                            }
                        }
                }
            }
            Divider().opacity(0.25)
        }
    }

    private func toggleExpanded(_ category: String) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }

    private func setSelected(_ selected: Bool, inCategory category: String) {
        updater.setSelected(selected) { $0.targetCategory == category }
    }

    private var incompatibleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { incompatibleExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    Text("Incompatible").font(.subheadline).fontWeight(.medium)
                    Text("\(updater.blockedUpdates.count)")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Image(systemName: incompatibleExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if incompatibleExpanded {
                ForEach(updater.blockedUpdates) { update in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.name).font(.subheadline)
                            Text(updater.reason(update) ?? FapCompatibility.unknownDeviceReason)
                                .font(.caption2).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(update.pack == "base" ? "BASE" : "EXTRA")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)
                }
            }
            Divider().opacity(0.25)
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch updater.phase {
        case .idle:
            if updater.updates.isEmpty {
                Label("Pull down to check for updates", systemImage: "arrow.down")
                    .foregroundStyle(.secondary)
            }
        case .needsBaseline: EmptyView()
        case .fetching:    progress("Checking GitHub…")
        case .downloading: progress("Downloading packs…")
        case .scanning(let i, let n): progress("Scanning via \(transfer.activeChannel.label)… \(i)/\(n)")
        case .verifying(let i, let n): progress("Verifying on device… \(i)/\(n)")
        case .installing(let i, let n): installingRow(i, n)
        case .cleaning(let i, let n): progress("Cleaning old routes… \(i)/\(n)")
        case .done(let m):
            Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let m):
            ActionableErrorView(
                title: "Community apps check failed",
                message: m,
                actionTitle: "Retry",
                action: { Task { await updater.check() } }
            )
        }
    }

    private func progress(_ text: String) -> some View {
        LoadingStateView(title: text, compact: true)
    }

    /// Live install row: app counter + the current file's name and a real byte
    /// progress bar, so it's obvious it's moving (not hung).
    @ViewBuilder private func installingRow(_ i: Int, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LoadingStateView(
                title: "Installing via \(updater.installDetail?.channel.label ?? transfer.activeChannel.label)",
                detail: "App \(i)/\(n)",
                compact: true
            )
            if let d = updater.installDetail {
                UnifiedProgressView(
                    title: d.name,
                    detail: d.attempt > 1
                        ? "retry \(d.attempt) · \(byteStr(d.sent)) / \(byteStr(d.total))"
                        : "\(byteStr(d.sent)) / \(byteStr(d.total))",
                    fraction: Double(d.sent) / Double(max(d.total, 1)),
                    tint: .orange
                )
            }
        }
    }

    private func byteStr(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Row for one update, keyed and looked up by `id` rather than a `ForEach($array)`
    /// positional Binding. `updater.updates` shrinks the moment an install/exclusion
    /// completes (`removeAll`/reassignment); a `ForEach($array)`-projected Binding can
    /// still be resolving a now-stale index at that exact moment (SwiftUI keeps the
    /// screen "warm" even one level back in the nav stack), which trapped with an
    /// out-of-bounds Array subscript inside SwiftUI's own Toggle/ForEach machinery. An
    /// id-based lookup Binding just no-ops if the item is already gone instead of
    /// crashing — this is by VALUE (a snapshot for this render), the Binding is the
    /// only thing that reaches back into the live array, and only by id, never by index.
    private func row(for u: PluginUpdate) -> some View {
        Toggle(isOn: selectionBinding(for: u.id)) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(u.name).font(.subheadline)
                    Text(updateSubtitle(u))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(u.isNew ? "NEW" : "UPD")
                        .font(.caption2).bold()
                        .foregroundStyle(u.isNew ? .green : .orange)
                    Text(byteStr(u.size))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectionBinding(for id: PluginUpdate.ID) -> Binding<Bool> {
        Binding(
            get: { updater.updates.first { $0.id == id }?.selected ?? false },
            set: { updater.setSelected($0, id: id) }
        )
    }

    private func updateSubtitle(_ update: PluginUpdate) -> String {
        // The install category is now the section header, so the row shows the
        // orthogonal context: which pack it came from (and its original folder if
        // the installer re-routes it somewhere else).
        var s = update.pack == "base" ? "Base pack" : "Extra pack"
        if update.isRouted { s += " · from \(update.category)" }
        return s
    }

    /// Set each row's selection to whether it matches the predicate.
    private func select(_ match: (PluginUpdate) -> Bool) {
        updater.selectOnly(where: match)
    }
}

private struct CommunityAppsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Label("Community apps checks All The Plugins and shows only changed files.",
                      systemImage: "puzzlepiece.extension")
                Label("The first sync creates a baseline from the current Flipper or selected release.",
                      systemImage: "scope")
                Label("Apps with the wrong firmware API are blocked before installation.",
                      systemImage: "exclamationmark.shield")
                Label("Protected Tumoflip apps are never replaced automatically.",
                      systemImage: "lock.shield")
                Label("Clean Up is a separate transaction and removes only old pack bytes after both paths are verified.",
                      systemImage: "trash")
                Label("A stopped transfer discards only the incomplete app file.",
                      systemImage: "stop.circle")
            }
            .navigationTitle("Community apps help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Lets you pin all-the-plugins to an exact GitHub release instead of always trusting
/// "latest" — the escape hatch for a same-day follow-up build (tag suffixed p2, p3, …)
/// that Auto hasn't reflected yet, or for deliberately rolling back.
struct PluginReleasePickerView: View {
    @ObservedObject var updater: PluginUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Button {
                    updater.setManualReleaseTag(nil)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Auto").foregroundStyle(.primary)
                            Text("Always use GitHub's latest release")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if updater.manualReleaseTag == nil {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Section {
                if updater.loadingReleases && updater.availableReleases.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if updater.availableReleases.isEmpty {
                    Text("Couldn't load releases from GitHub.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(updater.availableReleases) { release in
                    Button {
                        updater.setManualReleaseTag(release.tag)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(release.tag).foregroundStyle(release.hasPacks ? .primary : .secondary)
                                Text(release.publishedAt, style: .date)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !release.hasPacks {
                                Text("no packs").font(.caption2).foregroundStyle(.orange)
                            } else if updater.manualReleaseTag == release.tag {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!release.hasPacks)
                }
            } header: {
                Text("Recent releases")
            } footer: {
                Text("xMasterX occasionally ships a same-day follow-up (tag suffixed p2, p3, …) — pick it here if Auto hasn't picked it up yet.")
            }
        }
        .navigationTitle("Release")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
        .refreshable { await updater.loadAvailableReleases() }
        .task { if updater.availableReleases.isEmpty { await updater.loadAvailableReleases() } }
    }
}
