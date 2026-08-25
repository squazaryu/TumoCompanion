import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var control: FlipperControl
    @EnvironmentObject var transfer: TransferChannelStore
    @ObservedObject private var layout = HomeLayoutStore.shared
    @Binding var path: [HomeTileID]
    @State private var showCustomize = false
    @State private var connectionPulse = false
    @State private var previewPulse = false

    private let cols = [GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            CardScroll(refreshAction: refreshConnection) {
                connectionCard
                if ble.state == .ready { remotePreviewCard }
                if ble.state != .ready && !ble.discovered.isEmpty { nearbyCard }
                ForEach(HomeGroupID.allCases) { groupCard($0) }
                versionFooter
            }
            .navigationTitle("Home")
            .navigationDestination(for: HomeTileID.self) { destination($0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCustomize = true } label: { Image(systemName: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if ble.state == .connected || ble.state == .ready {
                        Button("Disconnect") { ble.disconnect() }
                    } else {
                        Button {
                            ble.state == .scanning ? ble.stopScan() : ble.startScan()
                        } label: {
                            Image(systemName: ble.state == .scanning ? "stop.circle" : "arrow.clockwise")
                        }
                    }
                }
            }
            .sheet(isPresented: $showCustomize) {
                NavigationStack { CustomizeHomeView() }
            }
            .onAppear {
                if ble.state == .disconnected { ble.autoConnect() }
                if ble.state == .ready { control.startScreenStream() }
                restartConnectionPulseIfNeeded()
                restartPreviewPulseIfNeeded()
            }
            .onDisappear {
                control.stopScreenStream()
                connectionPulse = false
                previewPulse = false
            }
            .onChange(of: ble.state) { _, state in
                if state == .ready {
                    control.startScreenStream()
                    restartConnectionPulseIfNeeded()
                    restartPreviewPulseIfNeeded()
                } else {
                    control.stopScreenStream()
                    connectionPulse = false
                    previewPulse = false
                }
            }
            .onChange(of: control.streaming) { _, active in
                if active { restartPreviewPulseIfNeeded() } else { previewPulse = false }
            }
        }
    }

    // MARK: - Connection hero

    private func refreshConnection() async {
        ble.autoConnect()
        if ble.state == .ready { control.startScreenStream() }
        // Let CoreBluetooth deliver a retained-link state change before the refresh
        // control disappears. This is intentionally short and never starts a second
        // scan while a connection attempt is already in progress.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func restartConnectionPulseIfNeeded() {
        guard ble.state == .scanning || ble.state == .connecting || ble.state == .connected else {
            connectionPulse = false
            return
        }
        connectionPulse = false
        DispatchQueue.main.async {
            guard self.ble.state == .scanning || self.ble.state == .connecting || self.ble.state == .connected else { return }
            self.connectionPulse = true
        }
    }

    private func restartPreviewPulseIfNeeded() {
        guard ble.state == .ready, control.streaming else {
            previewPulse = false
            return
        }
        previewPulse = false
        DispatchQueue.main.async {
            guard self.ble.state == .ready, self.control.streaming else { return }
            self.previewPulse = true
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.18)).frame(width: 52, height: 52)
                    if ble.state == .scanning || ble.state == .connecting || ble.state == .connected {
                        Circle()
                            .stroke(color.opacity(0.6), lineWidth: 2)
                            .frame(width: 52, height: 52)
                            .scaleEffect(connectionPulse ? 1.55 : 1)
                            .opacity(connectionPulse ? 0 : 0.75)
                            .animation(.easeOut(duration: 1.25).repeatForever(autoreverses: false),
                                       value: connectionPulse)
                    }
                    Image(systemName: ble.state == .ready ? "checkmark" :
                            (ble.state == .scanning ? "dot.radiowaves.left.and.right" : "bolt.horizontal"))
                        .font(.title3).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.connectedName ?? "Flipper Zero").font(.title3).fontWeight(.semibold)
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if ble.state == .ready, let b = ble.battery {
                    batteryBadge(b)
                }
            }
            HStack(spacing: 8) {
                StatusPill(
                    text: ble.state == .ready
                        ? (ble.serialOwner == .claudeBuddy ? "Claude Buddy" : "Ready")
                        : statusShort,
                    color: ble.serialOwner == .claudeBuddy ? .purple : color,
                    systemImage: ble.serialOwner == .claudeBuddy ? "bell.badge.fill" : nil
                )
                if ble.state == .ready {
                    StatusPill(text: ble.supportsAppBridge ? (ble.appBridgeV2 ? "Bridge v2" : "Bridge v1") : "No bridge",
                               color: ble.supportsAppBridge ? (ble.appBridgeV2 ? .green : .secondary) : .orange,
                               systemImage: "antenna.radiowaves.left.and.right")
                }
                StatusPill(
                    text: "Files \(transfer.activeChannel.label)",
                    color: transfer.activeChannel == .usb ? .blue : .secondary,
                    systemImage: transfer.activeChannel.systemImage
                )
                Spacer()
                if ble.state != .ready && ble.state != .connected {
                    Button {
                        ble.state == .scanning ? ble.stopScan() : ble.startScan()
                    } label: {
                        Label(ble.state == .scanning ? "Scanning…" : "Scan",
                              systemImage: ble.state == .scanning ? "stop.circle" : "arrow.clockwise")
                            .font(.caption).fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: color)
    }

    private var remotePreviewCard: some View {
        NavigationLink(value: HomeTileID.screen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("Remote", systemImage: HomeTileID.screen.systemImage)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                FlipperScreenCanvas(pixels: control.screenPixels)
                    .frame(maxWidth: .infinity)
                    .frame(height: 132)

                HStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(control.streaming ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        if control.streaming {
                            Circle()
                                .stroke(Color.green.opacity(0.55), lineWidth: 1.5)
                                .frame(width: 7, height: 7)
                                .scaleEffect(previewPulse ? 2.8 : 1)
                                .opacity(previewPulse ? 0 : 0.8)
                                .animation(.easeOut(duration: 1.35).repeatForever(autoreverses: false),
                                           value: previewPulse)
                        }
                    }
                    Text(control.streaming ? "Live screen" : "Waiting for screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Tap to control")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .card(tint: .teal, padding: 14)
    }

    private var nearbyCard: some View {
        SectionCard(title: "Nearby", systemImage: "wave.3.right") {
            VStack(spacing: 10) {
                ForEach(ble.discovered) { f in
                    Button { ble.connect(f.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.name).font(.subheadline).fontWeight(.medium)
                                Text(f.id.uuidString.prefix(8)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            signal(f.rssi)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Collapsible tile groups

    @ViewBuilder private func groupCard(_ group: HomeGroupID) -> some View {
        let tiles = layout.tiles(group)
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button { withAnimation(.snappy) { layout.toggle(group) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.systemImage).font(.caption).foregroundStyle(Theme.accent)
                        Text(group.name.uppercased())
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary).tracking(0.5)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(layout.isExpanded(group) ? 0 : -90))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if layout.isExpanded(group) {
                    LazyVGrid(columns: cols, spacing: 10) {
                        ForEach(tiles) { tile in
                            NavigationLink(value: tile) { DashTile(spec: tile.spec) }
                                .buttonStyle(.plain)
                                .disabled(isDisabled(tile))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder private func destination(_ tile: HomeTileID) -> some View {
        switch tile {
        case .info:    DeviceInfoView()
        case .apps:    InstalledAppsView()
        case .files:   FilesView()
        case .airadar: AIRadarView()
        case .wifi:    TumoSurveyView()
        case .fieldServices: FieldServicesView()
        case .spectrum: TumoSpectrumView()
        case .relay:   BridgeView()
        case .tumonet: TumoNetView()
        case .esp32:   ESP32FirmwareView()
        case .updates: UpdatesView()
        case .backup:  BackupView()
        case .remotes: RemotesView()
        case .media:   MediaRemoteView()
        case .screen:  ScreenView()
        }
    }

    /// Info needs a live RPC link; the rest open offline (or show their own empty state).
    private func isDisabled(_ tile: HomeTileID) -> Bool { tile == .info && ble.state != .ready }

    private var versionFooter: some View {
        HStack {
            Spacer()
            Text(BuildInfo.label).font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private var color: Color {
        switch ble.state {
        case .ready: return .green
        case .connected, .connecting, .scanning: return .yellow
        case .poweredOff, .unauthorized: return .red
        default: return .gray
        }
    }

    private var label: String {
        switch ble.state {
        case .ready:
            return ble.serialOwner == .claudeBuddy
                ? "Connected · serial in use by Buddy"
                : "Connected & ready"
        case .connected: return "Connecting services…"
        case .connecting: return "Connecting…"
        case .scanning: return "Scanning for Flippers"
        case .poweredOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not authorized"
        default: return "Not connected"
        }
    }

    private var statusShort: String {
        switch ble.state {
        case .scanning: return "Scanning"
        case .connecting, .connected: return "Connecting"
        case .poweredOff: return "BT off"
        default: return "Offline"
        }
    }

    private func batteryBadge(_ level: Int) -> some View {
        let color: Color = level <= 15 ? .red : level <= 30 ? .orange : .green
        let icon = level <= 10 ? "battery.0" : level <= 35 ? "battery.25"
                 : level <= 60 ? "battery.50" : level <= 85 ? "battery.75" : "battery.100"
        return VStack(spacing: 2) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            Text("\(level)%").font(.caption).fontWeight(.semibold).foregroundStyle(color)
        }
    }

    private func signal(_ rssi: Int) -> some View {
        let bars = rssi > -55 ? 3 : rssi > -70 ? 2 : 1
        return HStack(spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? Theme.accent : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(6 + i * 4))
            }
        }
    }
}

struct DashTileSpec {
    let title: String
    let systemImage: String
    let tint: Color
}

struct DashTile: View {
    let spec: DashTileSpec
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: spec.systemImage)
                .font(.title3).foregroundStyle(spec.tint)
            Text(spec.title).font(.caption).fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 62)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(spec.tint.opacity(0.12), lineWidth: 1))
    }
}
