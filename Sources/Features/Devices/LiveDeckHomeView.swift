import SwiftUI

/// Compact Home dashboard for the connected Flipper.
///
/// The console is the single source of truth for device and screen state. The
/// remaining surfaces are compact, two-column widgets so the useful state is
/// visible without a long launcher page or duplicated activity indicators.
struct LiveDeckHomeView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var control: FlipperControl
    @EnvironmentObject private var updates: UpdatesCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var path: [HomeTileID]
    let refreshAction: () async -> Void

    #if DEBUG
    private var automationPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("-live-deck-connected-qa")
    }
    #else
    private var automationPreview: Bool { false }
    #endif

    private func navigate(_ tile: HomeTileID) {
        path.append(tile)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CardScroll(refreshAction: refreshAction) {
                LiveDeckConsoleCard(
                    onScreen: { navigate(.screen) },
                    onNavigate: navigate,
                    automationPreview: automationPreview
                )

                LiveDeckNearbyCard()

                VStack(spacing: 10) {
                    // Keep these surfaces full width. A mixed LazyVGrid made
                    // gridCellColumns(2) unreliable on older iOS 17 layouts.
                    LiveDeckSourcesCard(
                        onOpenCenter: { navigate(.updates) },
                        onNavigate: navigate,
                        automationPreview: automationPreview
                    )
                    LiveDeckToolsQuickAccessCard(onNavigate: navigate)
                }

                LiveDeckFooter()
                // Leave room for the fixed folder tab without making the tab
                // part of the scrolling content.
                Color.clear.frame(height: 34)
            }

            LiveDeckToolsDrawer(onNavigate: navigate)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: ble.state)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: control.streaming)
    }
}

private struct LiveDeckConsoleCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var control: FlipperControl
    @EnvironmentObject private var transfer: TransferChannelStore

    let onScreen: () -> Void
    let onNavigate: (HomeTileID) -> Void
    let automationPreview: Bool

    private var isReady: Bool { automationPreview || ble.state == .ready }

    private var displayName: String {
        automationPreview ? "Flipper TUMOFLIP" : (ble.connectedName ?? "Flipper Zero")
    }

    private var displayedBattery: Int? {
        automationPreview ? 79 : ble.battery
    }

    private var tint: Color {
        if automationPreview { return .green }
        switch ble.state {
        case .ready: return .green
        case .connected, .connecting, .scanning: return .yellow
        case .poweredOff, .unauthorized: return .red
        default: return .secondary
        }
    }

    private var status: LiveDeckConnectionStatus {
        if automationPreview { return .ready }
        switch ble.state {
        case .ready: return .ready
        case .scanning: return .scanning
        case .connecting, .connected: return .connecting
        case .poweredOff: return .offline("Bluetooth is off")
        case .unauthorized: return .offline("Bluetooth permission needed")
        case .disconnected: return .offline("No Flipper connected")
        }
    }

    private var bridgeTitle: String {
        guard isReady else { return "No bridge" }
        guard automationPreview || ble.supportsAppBridge else { return "No bridge" }
        return automationPreview || ble.appBridgeV2 ? "Bridge v2" : "Bridge v1"
    }

    private var channelTitle: String {
        transfer.activeChannel == .usb ? "USB" : "BLE"
    }

    private var statusRailFont: Font {
        .system(size: 12, weight: .semibold, design: .rounded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("FLIPPER CONSOLE", systemImage: "rectangle.on.rectangle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .tracking(0.8)
                Spacer()
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: onScreen) {
                        ZStack {
                            if isReady {
                                if automationPreview {
                                    LiveDeckPreviewScreen(battery: displayedBattery ?? 0)
                                        .transition(.opacity)
                                } else {
                                    FlipperScreenCanvas(pixels: control.screenPixels)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 108)
                                        .transition(.opacity)
                                }
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "rectangle.on.rectangle.slash")
                                        .font(.title3)
                                    Text("Connect Flipper")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 108)
                            }
                        }
                        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((control.streaming || automationPreview) ? "Open live Flipper screen" : "Open Flipper screen")
                }
                .layoutPriority(1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.callout.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    LiveDeckConsoleActionList(onNavigate: onNavigate)
                }
                .frame(minWidth: 138, maxWidth: 166, alignment: .leading)
            }

            // The status rail belongs to the whole console card, not only the
            // screen column. A full-width rail keeps longer states such as
            // "Connecting" readable and leaves room for the battery glyph.
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    Text(status.shortTitle)
                        .font(statusRailFont)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                metadataDivider

                if let battery = displayedBattery {
                    LiveDeckBattery(level: battery, showsIcon: true, valueFont: statusRailFont)
                        .frame(maxWidth: .infinity, alignment: .center)
                    metadataDivider
                }

                HStack(spacing: 4) {
                    Image(systemName: transfer.activeChannel.systemImage)
                        .font(.caption2.weight(.medium))
                    Text(channelTitle)
                        .font(statusRailFont)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                metadataDivider
                Text(bridgeTitle)
                    .font(statusRailFont)
                    .foregroundStyle(.primary.opacity(0.72))
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(statusRailFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.22), lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: tint, padding: 12)
    }

    private var metadataDivider: some View {
        Text("·")
            .foregroundStyle(.tertiary)
    }
}

/// Stable visual fixture for UI screenshots. A real connected device always
/// uses the live pixel buffer; the fixture prevents an empty automation buffer
/// from looking like a broken orange panel during design review.
private struct LiveDeckPreviewScreen: View {
    let battery: Int

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.on.rectangle")
                Text("TUMOFLIP")
                Spacer()
                Text("BLE")
                Image(systemName: battery > 20 ? "battery.75percent" : "battery.25percent")
            }
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.65)).frame(height: 1)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONNECTED")
                    Text("APP BRIDGE")
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("READY")
                    Text("\(battery)%")
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.black.opacity(0.78))
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .background(
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.62, blue: 0.12), Color(red: 0.93, green: 0.48, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.5), lineWidth: 1)
        }
    }
}

private struct LiveDeckConsoleActionList: View {
    let onNavigate: (HomeTileID) -> Void

    private let tiles: [HomeTileID] = [.info, .files, .apps, .backup]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
            ForEach(tiles) { tile in
                Button { onNavigate(tile) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tile.systemImage)
                            .font(.subheadline.weight(.medium))
                        Text(tile.title)
                            .font(.caption2.weight(.medium))
                    }
                    .lineLimit(1)
                    .foregroundStyle(.primary.opacity(0.82))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 37)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tile == .info ? "Info" : "Open \(tile.title)")
            }
        }
    }
}

private struct LiveDeckNearbyCard: View {
    @EnvironmentObject private var ble: FlipperBLE

    var body: some View {
        if ble.state != .ready && !ble.discovered.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Label("NEARBY FLIPPERS", systemImage: "wave.3.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .tracking(0.7)

                ForEach(ble.discovered) { flipper in
                    Button { ble.connect(flipper.id) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flipper.name)
                                    .font(.subheadline.weight(.semibold))
                                Text(flipper.id.uuidString.prefix(8))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            LiveDeckSignal(rssi: flipper.rssi)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(tint: Theme.accent, padding: 12)
        }
    }
}

private struct LiveDeckSignal: View {
    let rssi: Int

    var body: some View {
        let bars = rssi > -55 ? 3 : rssi > -70 ? 2 : 1
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? Theme.accent : Color.gray.opacity(0.28))
                    .frame(width: 4, height: CGFloat(6 + index * 4))
            }
        }
        .accessibilityLabel("Signal \(rssi) dBm")
    }
}

private struct LiveDeckSourcesCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var updates: UpdatesCoordinator

    let onOpenCenter: () -> Void
    let onNavigate: (HomeTileID) -> Void
    let automationPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label("SOURCES", systemImage: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .tracking(0.65)
                Spacer()
                Button("Open center", action: onOpenCenter)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("updates-open-center")
            }

            VStack(spacing: 2) {
                Button { onNavigate(.firmware) } label: {
                    LiveDeckSourceRow(
                        title: "Firmware",
                        subtitle: "Device release channel",
                        status: automationPreview || ble.state == .ready ? .ready("Ready") : .waiting("Waiting"),
                        systemImage: "cpu"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("updates-source-firmware")

                Divider()

                Button { onNavigate(.packages) } label: {
                    LiveDeckSourceRow(
                        title: "FW Packages",
                        subtitle: "Catalog on demand",
                        status: packageStatus,
                        systemImage: "shippingbox"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("updates-source-packages")

                Divider()

                Button { onNavigate(.communityApps) } label: {
                    LiveDeckSourceRow(
                        title: "Community Apps",
                        subtitle: "Audit when needed",
                        status: communityStatus,
                        systemImage: "square.grid.2x2"
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("updates-source-community")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.accent, padding: 10)
    }

    private var packageStatus: LiveDeckSourceStatus {
        if updates.packages.busy { return .loading("Updating") }
        if updates.packages.manifest != nil { return .ready("Ready") }
        return .waiting("On demand")
    }

    private var communityStatus: LiveDeckSourceStatus {
        if updates.plugins.isBusy { return .loading("Checking") }
        if !updates.plugins.pendingProtectedReview.isEmpty { return .attention("Review") }
        if !updates.plugins.updates.isEmpty { return .ready("Ready") }
        return .waiting("On demand")
    }
}

private struct LiveDeckSourceRow: View {
    let title: String
    let subtitle: String
    let status: LiveDeckSourceStatus
    let systemImage: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.regular))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(status.tint)
                    .frame(width: 6, height: 6)
                Text(status.title)
                    .font(.caption.weight(.regular))
                    .foregroundStyle(status.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

private struct LiveDeckToolsQuickAccessCard: View {
    @ObservedObject private var layout = HomeLayoutStore.shared

    let onNavigate: (HomeTileID) -> Void

    private var columnCount: Int {
        switch layout.toolsQuickAccessTiles.count {
        case 0: return 1
        case 1...3: return layout.toolsQuickAccessTiles.count
        case 4: return 2
        default: return 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label("QUICK ACCESS", systemImage: "square.grid.3x2")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .tracking(0.65)
            }

            if layout.toolsQuickAccessTiles.isEmpty {
                Text("Choose tools in Settings → Home dashboard.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount),
                    spacing: 8
                ) {
                    ForEach(layout.toolsQuickAccessTiles) { tool in
                        Button { onNavigate(tool.id) } label: {
                            VStack(alignment: .center, spacing: 8) {
                                Image(systemName: tool.systemImage)
                                    .font(.title3.weight(.regular))
                                    .foregroundStyle(.primary.opacity(0.68))
                                Text(tool.title)
                                    .font(.caption2.weight(.regular))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.72)
                            }
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(tool.title)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Theme.accent, padding: 10)
    }
}

private struct LiveDeckToolsDrawer: View {
    @ObservedObject private var layout = HomeLayoutStore.shared
    @State private var isOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onNavigate: (HomeTileID) -> Void

    private var remainingTools: [HomeToolSpec] {
        HomeToolCatalog.all.filter { !layout.isToolQuickAccess($0.id) }
    }

    private var toolRows: Int {
        max(1, (remainingTools.count + 1) / 2)
    }

    private var gridHeight: CGFloat {
        guard !remainingTools.isEmpty else { return 0 }
        let rows = CGFloat(toolRows)
        return rows * 38 + CGFloat(max(toolRows - 1, 0)) * 8
    }

    private var visibleGridHeight: CGFloat {
        // Keep the drawer compact for the normal two-to-four item case. Only
        // a genuinely long list becomes internally scrollable.
        min(gridHeight, 220)
    }

    private var panelHeight: CGFloat {
        // Handle + two VStack gaps + header/content padding. The content
        // height is derived from the actual number of rows, so the panel does
        // not reserve a large empty block or clip its last row.
        let contentHeight = remainingTools.isEmpty ? 18 : visibleGridHeight
        return 69 + contentHeight
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isOpen {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .onTapGesture { close() }
                        .transition(.opacity)

                    toolsPanel
                        .frame(height: panelHeight)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.bottom, 54)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(true)
            }

            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill")
                        .font(.caption.weight(.bold))
                    Text("TOOLS")
                        .font(.caption.weight(.bold))
                        .tracking(0.8)
                    Spacer()
                    Text("\(remainingTools.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tools")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .zIndex(10)
    }

    @ViewBuilder
    private var toolsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)

            HStack(spacing: 7) {
                Label("MORE TOOLS", systemImage: "folder")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.8)
                Spacer()
                Text("\(remainingTools.count) available")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if remainingTools.isEmpty {
                Text("All tools are in Quick Access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(remainingTools) { tool in
                            Button {
                                close()
                                onNavigate(tool.id)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: tool.systemImage)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary.opacity(0.68))
                                    Text(tool.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(tool.title)")
                        }
                    }
                }
                .frame(height: visibleGridHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 9)
        .padding(.bottom, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) {
            isOpen.toggle()
        }
    }

    private func close() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24)) {
            isOpen = false
        }
    }
}

private struct LiveDeckFooter: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            Text("Ready for field work")
                .font(.caption2.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(BuildInfo.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
}

private struct LiveDeckBattery: View {
    let level: Int
    var showsIcon = true
    var valueFont: Font = .caption2.weight(.bold)

    private var tint: Color {
        level <= 15 ? .red : level <= 30 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsIcon {
                Image(systemName: batteryImage)
                    .font(.caption.weight(.semibold))
            }
            Text("\(level)%")
                .font(valueFont)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Battery \(level) percent")
    }

    private var batteryImage: String {
        switch level {
        case ...10: return "battery.0"
        case ...35: return "battery.25"
        case ...60: return "battery.50"
        case ...85: return "battery.75"
        default: return "battery.100"
        }
    }
}

private enum LiveDeckConnectionStatus: Equatable {
    case ready
    case scanning
    case connecting
    case offline(String)

    var shortTitle: String {
        switch self {
        case .ready: return "Ready"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        }
    }

}

private enum LiveDeckSourceStatus: Equatable {
    case ready(String)
    case loading(String)
    case waiting(String)
    case attention(String)

    var title: String {
        switch self {
        case .ready(let value), .loading(let value), .waiting(let value), .attention(let value): return value
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .loading: return .orange
        case .waiting: return .secondary
        case .attention: return .red
        }
    }
}

private extension PluginUpdater {
    var isBusy: Bool {
        if validating { return true }
        switch phase {
        case .fetching, .downloading, .scanning, .installing, .cleaning, .verifying:
            return true
        default:
            return false
        }
    }
}

/// Kept as a compatibility model for the existing Customize Home screen.
struct DashTileSpec {
    let title: String
    let systemImage: String
    let tint: Color
}
