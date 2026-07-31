import SwiftUI
import UIKit
import UserNotifications

/// Applies the chosen interface style directly to the host UIWindow. Doing this
/// at the window level (vs SwiftUI's `.preferredColorScheme`) means the style is
/// set before/at the first layout pass, so the tab bar never re-lays-out into a
/// shifted position when the app forces a scheme different from the system one.
struct WindowStyleApplier: UIViewRepresentable {
    let style: UIUserInterfaceStyle
    func makeUIView(context: Context) -> UIView {
        let v = UIView(); v.isHidden = true; v.isUserInteractionEnabled = false; return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        apply(uiView.window, style: style)
        // Window may not be attached on the first pass — retry next runloop.
        DispatchQueue.main.async { apply(uiView.window, style: style) }
    }
    private func apply(_ window: UIWindow?, style: UIUserInterfaceStyle) {
        if let w = window { w.overrideUserInterfaceStyle = style; return }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for w in ws.windows { w.overrideUserInterfaceStyle = style }
        }
    }
}

enum AppIconOption: String, CaseIterable, Identifiable {
    case orange, dolphin, green, purple, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .orange:  return "Auto · Light / Dark"
        case .dolphin: return "Light"
        case .green:   return "Dark"
        case .purple:  return "Liquid Glass"
        case .mono:    return "Liquid Glass · Dark"
        }
    }
    /// nil = primary AppIcon.
    var alternateName: String? {
        switch self {
        case .orange:  return nil
        case .dolphin: return "AppIcon-Dolphin"
        case .green:   return "AppIcon-Green"
        case .purple:  return "AppIcon-Purple"
        case .mono:    return "AppIcon-Mono"
        }
    }
    var swatch: Color {
        switch self {
        case .orange:  return .orange
        case .dolphin: return .orange
        case .green:   return Color(white: 0.12)
        case .purple:  return Color(white: 0.9)
        case .mono:    return Color(white: 0.28)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var deviceServices: DeviceServiceCoordinator
    @ObservedObject private var buddy = BuddyRelay.shared
    @State private var currentIcon = UIApplication.shared.alternateIconName
    @State private var iconError: String?
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        CardScroll {
            SectionCard(title: "Dolphin", systemImage: "photo.on.rectangle.angled") {
                NavigationLink {
                    DolphinGalleryView()
                } label: {
                    Label("Dolphin Gallery", systemImage: "rectangle.stack")
                }
            }

            SectionCard(title: "Appearance", systemImage: "paintbrush") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if UIApplication.shared.supportsAlternateIcons {
                SectionCard(title: "App icon", systemImage: "app.badge") {
                    ForEach(AppIconOption.allCases) { opt in
                        Button { setIcon(opt) } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(opt.swatch)
                                    .frame(width: 28, height: 28)
                                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15)))
                                Text(opt.label).foregroundStyle(.primary)
                                Spacer()
                                if currentIcon == opt.alternateName {
                                    Image(systemName: "checkmark").foregroundStyle(.orange)
                                }
                            }
                        }
                        if opt != AppIconOption.allCases.last { Divider().opacity(0.4) }
                    }
                    if let e = iconError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
            }

            SectionCard(title: "Connection", systemImage: "antenna.radiowaves.left.and.right") {
                Toggle(isOn: $ble.keepAlive) {
                    Label("Keep bridge alive in background", systemImage: "bolt.horizontal.circle")
                }
                .tint(Theme.accent)
                Text("Holds the Bluetooth link open while the app is backgrounded so the Flipper can trigger the relay (and other App Bridge actions) without opening the app — iOS reconnects automatically when the Flipper is back in range. Costs a little battery, and can't survive force-quitting the app from the App Switcher (an iOS limit) or re-pairing the Flipper.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionCard(title: "Device services", systemImage: "iphone.and.arrow.forward") {
                Toggle(isOn: $deviceServices.locationEnabled) {
                    serviceRow(
                        title: "Share iPhone location",
                        systemImage: "location.fill",
                        status: deviceServices.locationState
                    )
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("device-services-location")
                Text("Lets a connected Flipper request one GPS fix, including while this app is in the background. Background requests require Always Location; tracking stops after the reply and no history is stored.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().opacity(0.4)

                Toggle(isOn: $deviceServices.networkEnabled) {
                    serviceRow(
                        title: "Allow safe HTTPS",
                        systemImage: "network",
                        status: deviceServices.networkState
                    )
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("device-services-network")
                Text("Allows one bounded HTTPS GET to the approved public test endpoint, including after a BLE background wake. Raw sockets, redirects, credentials and local addresses stay blocked.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if deviceServices.locationState == .denied ||
                    deviceServices.locationState == .foregroundOnly {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                if let error = deviceServices.lastError {
                    Text("Last error: \(error)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            .onAppear {
                deviceServices.prepareBackgroundLocationAuthorization()
            }
            .onChange(of: deviceServices.locationEnabled) { _, enabled in
                if enabled { deviceServices.prepareBackgroundLocationAuthorization() }
            }

            SectionCard(title: "Claude Buddy", systemImage: "bell.badge") {
                Toggle(isOn: $buddy.enabled) {
                    Label("Claude Buddy passthrough", systemImage: "bell.badge")
                }
                .tint(Theme.accent)
                if buddy.enabled {
                    HStack {
                        Image(systemName: buddy.active ? "dot.radiowaves.left.and.right" : "moon.zzz")
                            .foregroundStyle(buddy.active ? .green : .secondary)
                        Text(buddy.active ? "Active — Buddy app is talking (RPC paused)"
                                          : "Idle — RPC available; opens automatically with the Buddy app")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let last = buddy.lastEvent {
                        Text("Last: \(last)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("↓ \(buddy.bytesDown) B  ·  ↑ \(buddy.bytesUp) B")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Safe to leave on. Passthrough arms itself only while the Claude Buddy app is the active app on the Flipper — then it pipes its serial both ways and pauses RPC. Otherwise RPC (Device/Files/View) works normally and nothing is written to the link.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SectionCard(title: "Notifications", systemImage: "bell") {
                HStack {
                    Label("Update notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(notifStatusText)
                        .font(.caption)
                        .foregroundStyle(notifStatus == .authorized ? .green : .secondary)
                }
                if notifStatus == .notDetermined {
                    Button("Enable notifications") {
                        PluginUpdateMonitor.enableIfNeeded()
                        Task { try? await Task.sleep(nanoseconds: 800_000_000); await refreshNotif() }
                    }
                } else if notifStatus == .denied {
                    Button("Open iOS Settings") {
                        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                    }
                }
                Text("Checks when the app opens and whenever iOS grants background time. Background timing is controlled by iOS, so opening TumoCompanion is the fastest local-only refresh.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DiagnosticsCard()

            SectionCard(title: "About", systemImage: "info.circle") {
                HStack {
                    Text("App Bridge").foregroundStyle(.secondary)
                    Spacer()
                    Text(ble.state == .ready ? (ble.appBridgeV2 ? "v2 (FAB2)" : "v1 (FAB1)") : "—")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(ble.appBridgeV2 ? .green : .secondary)
                }
                Divider().opacity(0.4)
                HStack(alignment: .top, spacing: 12) {
                    Text("Version")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(BuildInfo.label)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .textSelection(.enabled)
                }
                Divider().opacity(0.4)
                Button { settings.onboardingDone = false } label: {
                    Label("Show intro again", systemImage: "questionmark.circle")
                }
                Text("App Bridge negotiates automatically on connect: v2 (FAB2) when the firmware supports it, otherwise v1 (FAB1).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshNotif() }
    }

    private var notifStatusText: String {
        switch notifStatus {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off (enable in iOS Settings)"
        default: return "Not set"
        }
    }

    private func refreshNotif() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run { notifStatus = s.authorizationStatus }
    }

    private func serviceRow(
        title: String,
        systemImage: String,
        status: DeviceServiceState
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status.label)
                .font(.caption)
                .foregroundStyle(status == .inUse ? .green : .secondary)
        }
    }

    private func setIcon(_ opt: AppIconOption) {
        guard currentIcon != opt.alternateName else { return }
        UIApplication.shared.setAlternateIconName(opt.alternateName) { err in
            DispatchQueue.main.async {
                if let err = err { iconError = err.localizedDescription }
                else { iconError = nil; currentIcon = opt.alternateName }
            }
        }
    }
}

private enum DiagnosticHelpTopic: String, Identifiable {
    case appBridge
    case tumoVM
    case tumoCard
    case tumoFabric

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appBridge: return "App Bridge Console"
        case .tumoVM: return "TumoVM NFC Smoke"
        case .tumoCard: return "TumoCard NFC Smoke"
        case .tumoFabric: return "TumoFabric Counter"
        }
    }

    var explanation: String {
        switch self {
        case .appBridge:
            return "Sends manual App Bridge v2 (FAB2) commands and shows raw replies. Use it to diagnose the bridge protocol, capabilities and framing."
        case .tumoVM:
            return "Runs a small NFC transport and state-restoration check against TumoVM. It verifies that the NFC session can open, exchange data and return control safely."
        case .tumoCard:
            return "Checks the TumoCard application identifiers and the shared NFC/USB state. It is intended for protocol diagnostics, not for everyday card use."
        case .tumoFabric:
            return "Exercises a FAB2 session counter, sequence handling, replay protection and idempotency. It helps find duplicated or out-of-order bridge requests."
        }
    }
}

private struct DiagnosticsCard: View {
    @State private var helpTopic: DiagnosticHelpTopic?

    var body: some View {
        CollapsibleCard(
            title: "Diagnostics",
            systemImage: "stethoscope",
            startExpanded: false
        ) {
            diagnosticRow(
                title: "App Bridge Console",
                systemImage: "terminal",
                help: .appBridge
            ) { AppBridgeConsoleView() }
            Divider().opacity(0.4)
            diagnosticRow(
                title: "TumoVM NFC Smoke",
                systemImage: "wave.3.right.circle",
                help: .tumoVM
            ) { TumoVMNFCSmokeView() }
            Divider().opacity(0.4)
            diagnosticRow(
                title: "TumoCard NFC Smoke",
                systemImage: "rectangle.stack.badge.person.crop",
                help: .tumoCard
            ) { TumoCardNFCSmokeView() }
            Divider().opacity(0.4)
            diagnosticRow(
                title: "TumoFabric Counter",
                systemImage: "point.3.connected.trianglepath.dotted",
                help: .tumoFabric
            ) { TumoFabricView() }
        }
        .sheet(item: $helpTopic) { topic in
            NavigationStack {
                ScrollView {
                    Text(topic.explanation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(topic.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { helpTopic = nil }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func diagnosticRow<Destination: View>(
        title: String,
        systemImage: String,
        help: DiagnosticHelpTopic,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        HStack(spacing: 12) {
            NavigationLink(destination: destination()) {
                Label(title, systemImage: systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { helpTopic = help } label: {
                Image(systemName: "questionmark.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("About \(title)")
        }
    }
}
