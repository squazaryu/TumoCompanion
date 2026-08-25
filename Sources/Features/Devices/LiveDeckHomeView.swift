import SwiftUI

/// The Home dashboard is intentionally a live deck rather than a launcher grid.
/// Each surface owns one piece of state (device, screen, activity, sources, actions)
/// so a change in one subsystem does not make the whole screen jump.
struct LiveDeckHomeView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var control: FlipperControl
    @EnvironmentObject private var transfer: TransferChannelStore
    @EnvironmentObject private var updates: UpdatesCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var path: [HomeTileID]
    let refreshAction: () async -> Void

    private func navigate(_ tile: HomeTileID) {
        path.append(tile)
    }

    var body: some View {
        CardScroll(refreshAction: refreshAction) {
            LiveDeckDeviceCard(onNavigate: { navigate(.info) })
            LiveDeckNearbyCard()
            LiveDeckScreenCard(onNavigate: { navigate(.screen) })
            LiveDeckActivityCard(onNavigate: navigate)
            LiveDeckSourcesCard(onNavigate: { navigate(.updates) })
            LiveDeckQuickActions(onNavigate: navigate)
            LiveDeckToolsCard(onNavigate: navigate)
            LiveDeckFooter()
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: ble.state)
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: control.streaming)
    }
}

private struct LiveDeckNearbyCard: View {
    @EnvironmentObject private var ble: FlipperBLE

    var body: some View {
        if ble.state != .ready && !ble.discovered.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("NEARBY FLIPPERS", systemImage: "wave.3.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .tracking(0.7)
                ForEach(ble.discovered) { flipper in
                    Button { ble.connect(flipper.id) } label: {
                        HStack(spacing: 12) {
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
            .card(tint: Theme.accent, padding: 16)
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

// MARK: - Device

private struct LiveDeckDeviceCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var transfer: TransferChannelStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    let onNavigate: () -> Void

    private var tint: Color {
        switch ble.state {
        case .ready: return .green
        case .connected, .connecting, .scanning: return .yellow
        case .poweredOff, .unauthorized: return .red
        default: return .secondary
        }
    }

    private var status: LiveDeckConnectionStatus {
        switch ble.state {
        case .ready: return .ready
        case .scanning: return .scanning
        case .connecting, .connected: return .connecting
        case .poweredOff: return .offline("Bluetooth is off")
        case .unauthorized: return .offline("Bluetooth permission needed")
        case .disconnected: return .offline("No Flipper connected")
        }
    }

    var body: some View {
        Button(action: onNavigate) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(tint.opacity(0.16))
                            .frame(width: 58, height: 58)
                        if status.isAnimated && !reduceMotion {
                            Circle()
                                .stroke(tint.opacity(0.6), lineWidth: 2)
                                .frame(width: 58, height: 58)
                                .scaleEffect(pulse ? 1.6 : 1)
                                .opacity(pulse ? 0 : 0.8)
                        }
                        Image(systemName: status.systemImage)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(tint)
                    }
                    .task(id: status) {
                        guard status.isAnimated, !reduceMotion else { return }
                        pulse = false
                        withAnimation(.easeOut(duration: 1.25).repeatForever(autoreverses: false)) {
                            pulse = true
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("TUMO LIVE DECK")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tint)
                            .tracking(1.1)
                        Text(ble.connectedName ?? "Flipper Zero")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Circle().fill(tint).frame(width: 7, height: 7)
                            Text(status.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if ble.state == .ready, let battery = ble.battery {
                        LiveDeckBattery(level: battery)
                    }
                }

                HStack(spacing: 8) {
                    LiveDeckBadge(
                        text: ble.state == .ready
                            ? (ble.serialOwner == .claudeBuddy ? "Buddy" : "Ready")
                            : status.shortTitle,
                        color: ble.serialOwner == .claudeBuddy ? .purple : tint,
                        systemImage: ble.serialOwner == .claudeBuddy ? "bell.badge.fill" : nil
                    )
                    if ble.state == .ready {
                        LiveDeckBadge(
                            text: ble.supportsAppBridge
                                ? (ble.appBridgeV2 ? "Bridge v2" : "Bridge v1")
                                : "No bridge",
                            color: ble.supportsAppBridge ? .green : .orange,
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                    }
                    LiveDeckBadge(
                        text: transfer.activeChannel.label,
                        color: transfer.activeChannel == .usb ? .blue : .secondary,
                        systemImage: transfer.activeChannel.systemImage
                    )
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(tint: tint, padding: 18)
        .disabled(ble.state != .ready)
    }
}

private struct LiveDeckBattery: View {
    let level: Int

    private var tint: Color {
        level <= 15 ? .red : level <= 30 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Image(systemName: batteryImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text("\(level)%")
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
        }
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

// MARK: - Screen

private struct LiveDeckScreenCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var control: FlipperControl
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    let onNavigate: () -> Void

    var body: some View {
        Button(action: onNavigate) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label("REMOTE SCREEN", systemImage: "rectangle.on.rectangle")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.teal)
                        .tracking(0.7)
                    Spacer()
                    LiveDeckLiveIndicator(isLive: control.streaming, reduceMotion: reduceMotion)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                ZStack {
                    if ble.state == .ready {
                        FlipperScreenCanvas(pixels: control.screenPixels)
                            .frame(maxWidth: .infinity)
                            .frame(height: 148)
                            .transition(.opacity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "rectangle.on.rectangle.slash")
                                .font(.title2)
                            Text("Connect a Flipper to see its screen")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 148)
                    }
                }
                .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.teal.opacity(0.22), lineWidth: 1)
                }

                HStack(spacing: 7) {
                    Circle()
                        .fill(control.streaming ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .overlay {
                            if control.streaming && !reduceMotion {
                                Circle()
                                    .stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                                    .scaleEffect(pulse ? 2.6 : 1)
                                    .opacity(pulse ? 0 : 0.8)
                            }
                        }
                    Text(control.streaming ? "Live screen · tap to control" : "Screen mirror is waiting")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Open remote")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.teal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(tint: .teal, padding: 14)
        .task(id: control.streaming) {
            guard control.streaming, !reduceMotion else { return }
            pulse = false
            withAnimation(.easeOut(duration: 1.35).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - Activity

private struct LiveDeckActivityCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var control: FlipperControl
    @EnvironmentObject private var transfer: TransferChannelStore
    @EnvironmentObject private var updates: UpdatesCoordinator
    let onNavigate: (HomeTileID) -> Void

    private var activity: LiveDeckActivity {
        if ble.state == .scanning || ble.state == .connecting || ble.state == .connected {
            return .connecting
        }
        guard ble.state == .ready else { return .offline }
        if control.streaming { return .screen }
        if updates.packages.busy { return .packages }
        if updates.plugins.isBusy { return .community }
        return .idle(channel: transfer.activeChannel)
    }

    var body: some View {
        Button { onNavigate(activity.destination) } label: {
            HStack(spacing: 14) {
                LiveDeckActivityGlyph(activity: activity)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CURRENT ACTIVITY")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(activity.tint)
                        .tracking(0.7)
                    Text(activity.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(activity.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(tint: activity.tint, padding: 16)
    }
}

private struct LiveDeckActivityGlyph: View {
    let activity: LiveDeckActivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle()
                .fill(activity.tint.opacity(0.15))
                .frame(width: 52, height: 52)
            Image(systemName: activity.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(activity.tint)
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .task(id: activity.isBusy) {
            guard activity.isBusy, !reduceMotion else { return }
            spinning = false
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - Sources

private struct LiveDeckSourcesCard: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var updates: UpdatesCoordinator
    let onNavigate: () -> Void

    var body: some View {
        Button(action: onNavigate) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("SOURCES", systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .tracking(0.7)
                    Spacer()
                    Text("Open center")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }

                LiveDeckSourceRow(
                    title: "Firmware",
                    subtitle: ble.state == .ready ? "Device release channel" : "Connect to inspect releases",
                    status: ble.state == .ready ? .ready("Ready") : .waiting("Waiting"),
                    systemImage: "cpu"
                )
                LiveDeckSourceRow(
                    title: "FW Packages",
                    subtitle: packageSubtitle,
                    status: packageStatus,
                    systemImage: "shippingbox"
                )
                LiveDeckSourceRow(
                    title: "Community Apps",
                    subtitle: communitySubtitle,
                    status: communityStatus,
                    systemImage: "square.grid.2x2"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(tint: Theme.accent, padding: 16)
    }

    private var packageSubtitle: String {
        if updates.packages.busy { return "Refreshing catalog…" }
        if let manifest = updates.packages.manifest {
            return manifest.isReferenceOnlyCatalog ? "Independent baseline catalog" : "Catalog ready to install"
        }
        return "Catalog on demand"
    }

    private var packageStatus: LiveDeckSourceStatus {
        if updates.packages.busy { return .loading("Updating") }
        if updates.packages.manifest != nil { return .ready("Ready") }
        return .waiting("Not loaded")
    }

    private var communitySubtitle: String {
        if updates.plugins.isBusy { return "Auditing Community Pack…" }
        if updates.plugins.pendingProtectedReview.isEmpty, !updates.plugins.updates.isEmpty {
            return "Audited Community Pack"
        }
        return "Audit when needed"
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
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(status.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            LiveDeckStatusText(status: status)
        }
    }
}

private struct LiveDeckStatusText: View {
    let status: LiveDeckSourceStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        HStack(spacing: 5) {
            if status.isLoading {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .task {
                        guard !reduceMotion else { return }
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            spinning = true
                        }
                    }
            } else {
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
            Text(status.title)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(status.tint)
    }
}

// MARK: - Quick actions and footer

private struct LiveDeckQuickActions: View {
    let onNavigate: (HomeTileID) -> Void
    private let actions: [(HomeTileID, String, String, Color)] = [
        (.files, "Files", "folder", .blue),
        (.apps, "Apps", "square.grid.2x2", .purple),
        (.info, "Device", "info.circle", .green),
        (.updates, "Updates", "arrow.down.circle", .orange)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QUICK LAUNCH")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(0.7)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(actions, id: \.0) { tile, title, image, color in
                        Button { onNavigate(tile) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: image)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(color)
                                    .frame(width: 38, height: 38)
                                    .background(color.opacity(0.13), in: Circle())
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 82, height: 76)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(color.opacity(0.13), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct LiveDeckToolsCard: View {
    @State private var expanded = false
    let onNavigate: (HomeTileID) -> Void

    private let tools: [(HomeTileID, String, String, Color)] = [
        (.fieldServices, "Field Services", "iphone.and.arrow.forward", .blue),
        (.wifi, "WiFi Survey", "wifi", .teal),
        (.airadar, "AI Radar", "dot.radiowaves.left.and.right", .purple),
        (.spectrum, "Spectrum", "waveform.path.ecg", .orange),
        (.relay, "Relay", "switch.2", .green),
        (.tumonet, "TumoNet", "network", .indigo),
        (.esp32, "ESP32", "cpu", .pink),
        (.backup, "Backup", "externaldrive", .brown),
        (.remotes, "Remotes", "switch.2", .cyan),
        (.media, "Media Remote", "play.rectangle", .mint)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("TOOLS", systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.7)
                    Spacer()
                    Text("\(tools.count) tools")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tools")

            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.0) { index, tool in
                        Button {
                            expanded = false
                            onNavigate(tool.0)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tool.2)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(tool.3)
                                    .frame(width: 28)
                                Text(tool.1)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        if index < tools.count - 1 {
                            Divider().opacity(0.35)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

private struct LiveDeckFooter: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.accent)
            Text("Ready for field work")
                .font(.caption.weight(.medium))
            Spacer()
            Text(BuildInfo.label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - Small view models

private enum LiveDeckConnectionStatus: Equatable {
    case ready
    case scanning
    case connecting
    case offline(String)

    var title: String {
        switch self {
        case .ready: return "Connected & ready"
        case .scanning: return "Scanning for Flippers"
        case .connecting: return "Establishing link"
        case .offline(let reason): return reason
        }
    }

    var shortTitle: String {
        switch self {
        case .ready: return "Ready"
        case .scanning: return "Scanning"
        case .connecting: return "Connecting"
        case .offline: return "Offline"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .connecting: return "bolt.horizontal"
        case .offline: return "bolt.slash"
        }
    }

    var isAnimated: Bool {
        switch self {
        case .scanning, .connecting: return true
        default: return false
        }
    }
}

private enum LiveDeckActivity: Equatable {
    case offline
    case connecting
    case screen
    case packages
    case community
    case idle(channel: TransferChannel)

    var title: String {
        switch self {
        case .offline: return "Waiting for a Flipper"
        case .connecting: return "Establishing link"
        case .screen: return "Remote stream is live"
        case .packages: return "FW Packages are working"
        case .community: return "Community Pack is checking"
        case .idle: return "Ready for field work"
        }
    }

    var subtitle: String {
        switch self {
        case .offline: return "Pull to refresh and reconnect"
        case .connecting: return "Negotiating BLE services"
        case .screen: return "Screen frames are arriving in real time"
        case .packages: return "Catalog or package transfer is in progress"
        case .community: return "Protected apps are being reconciled"
        case .idle(let channel): return "Files and tools available via \(channel.label)"
        }
    }

    var systemImage: String {
        switch self {
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        case .connecting: return "link"
        case .screen: return "rectangle.on.rectangle"
        case .packages: return "shippingbox"
        case .community: return "square.grid.2x2"
        case .idle: return "sparkles"
        }
    }

    var tint: Color {
        switch self {
        case .offline: return .secondary
        case .connecting: return .yellow
        case .screen: return .teal
        case .packages: return .orange
        case .community: return .purple
        case .idle: return .green
        }
    }

    var isBusy: Bool {
        switch self {
        case .connecting, .packages, .community: return true
        default: return false
        }
    }

    var destination: HomeTileID {
        switch self {
        case .screen: return .screen
        case .packages, .community: return .updates
        default: return .info
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

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

private struct LiveDeckBadge: View {
    let text: String
    let color: Color
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(color.opacity(0.13), in: Capsule())
    }
}

private struct LiveDeckLiveIndicator: View {
    let isLive: Bool
    let reduceMotion: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .overlay {
                    if isLive && !reduceMotion {
                        Circle()
                            .stroke(Color.green.opacity(0.55), lineWidth: 1.5)
                            .scaleEffect(pulse ? 2.2 : 1)
                            .opacity(pulse ? 0 : 0.8)
                    }
                }
            Text(isLive ? "LIVE" : "IDLE")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isLive ? .green : .orange)
        }
        .task(id: isLive) {
            guard isLive, !reduceMotion else { return }
            pulse = false
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

/// Kept as a small compatibility model for the existing Customize Home screen.
/// The live deck itself no longer renders `DashTile` or a tile grid.
struct DashTileSpec {
    let title: String
    let systemImage: String
    let tint: Color
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
