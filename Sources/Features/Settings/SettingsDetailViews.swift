import SwiftUI
import UIKit
import UserNotifications

struct ConnectivitySettingsView: View {
    @EnvironmentObject private var ble: FlipperBLE
    @EnvironmentObject private var deviceServices: DeviceServiceCoordinator
    @ObservedObject private var buddy = BuddyRelay.shared

    var body: some View {
        CardScroll {
            SectionCard(title: "Connection", systemImage: "antenna.radiowaves.left.and.right") {
                Toggle(isOn: $ble.keepAlive) {
                    Label("Keep bridge alive in background", systemImage: "bolt.horizontal.circle")
                }
                .tint(Theme.accent)
                Text("Holds the Bluetooth link open while the app is backgrounded so the Flipper can trigger the relay and other App Bridge actions. It costs a little battery and cannot survive force-quitting the app.")
                    .settingsDescription()
            }

            SectionCard(title: "Device services", systemImage: "iphone.and.arrow.forward") {
                Toggle(isOn: $deviceServices.locationEnabled) {
                    serviceRow(title: "Share iPhone location", systemImage: "location.fill", status: deviceServices.locationState)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("device-services-location")
                Text("Lets a connected Flipper request one GPS fix. Background requests require Always Location and stop after every reply.")
                    .settingsDescription()

                Divider().opacity(0.4)

                Toggle(isOn: $deviceServices.networkEnabled) {
                    serviceRow(title: "Allow safe HTTPS", systemImage: "network", status: deviceServices.networkState)
                }
                .tint(Theme.accent)
                .accessibilityIdentifier("device-services-network")
                Text("Allows bounded Weather, Place, Release and diagnostic HTTPS requests. Raw sockets, redirects and Flipper-supplied hosts stay blocked.")
                    .settingsDescription()

                if deviceServices.locationState == .denied || deviceServices.locationState == .foregroundOnly {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                if let error = deviceServices.lastError {
                    Text("Last error: \(error)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                NavigationLink { FieldServicesView() } label: {
                    Label("Field Services settings", systemImage: "location.viewfinder")
                }
                .accessibilityIdentifier("field-services-settings-link")
            }
            .onAppear { deviceServices.prepareBackgroundLocationAuthorization() }
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
                        Text(buddy.active ? "Active — RPC is paused" : "Idle — RPC is available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let last = buddy.lastEvent {
                        Text("Last: \(last)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("↓ \(buddy.bytesDown) B  ·  ↑ \(buddy.bytesUp) B")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Passthrough arms only while the Claude Buddy app is active on the Flipper. Otherwise normal RPC access remains available.")
                    .settingsDescription()
            }
        }
        .navigationTitle("Connectivity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func serviceRow(title: String, systemImage: String, status: DeviceServiceState) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status.label)
                .font(.caption)
                .foregroundStyle(status == .inUse ? .green : .secondary)
        }
    }
}

struct AutomationSettingsView: View {
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        CardScroll(refreshAction: refresh) {
            SectionCard(title: "Notifications", systemImage: "bell") {
                HStack {
                    Label("Update notifications", systemImage: "bell.badge")
                    Spacer()
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(status == .authorized ? .green : .secondary)
                }
                if status == .notDetermined {
                    Button("Enable notifications") {
                        PluginUpdateMonitor.enableIfNeeded()
                        Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            await refresh()
                        }
                    }
                } else if status == .denied {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Text("Checks when the app opens and whenever iOS grants background time. Pull down on this screen to re-read the current permission state.")
                    .settingsDescription()
            }
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    private var statusText: String {
        switch status {
        case .authorized, .provisional, .ephemeral: return "On"
        case .denied: return "Off"
        default: return "Not set"
        }
    }

    private func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        status = settings.authorizationStatus
    }
}

struct DeveloperSettingsView: View {
    @StateObject private var githubAuth = GitHubAuthStore.shared

    var body: some View {
        CardScroll {
            GitHubAccessCard(auth: githubAuth)
            DiagnosticsCard()
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ble: FlipperBLE

    var body: some View {
        CardScroll {
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
                    Text("Version").foregroundStyle(.secondary)
                    Text(BuildInfo.label)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Divider().opacity(0.4)
                Button { settings.onboardingDone = false } label: {
                    Label("Show intro again", systemImage: "questionmark.circle")
                }
                Text("App Bridge negotiates automatically on connect: v2 (FAB2) when supported, otherwise v1 (FAB1).")
                    .settingsDescription()
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum DiagnosticHelpTopic: String, Identifiable {
    case appBridge, tumoVM, tumoCard, tumoFabric

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
        CollapsibleCard(title: "Diagnostics", systemImage: "stethoscope", startExpanded: false) {
            diagnosticRow(title: "App Bridge Console", systemImage: "terminal", help: .appBridge) { AppBridgeConsoleView() }
            Divider().opacity(0.4)
            diagnosticRow(title: "TumoVM NFC Smoke", systemImage: "wave.3.right.circle", help: .tumoVM) { TumoVMNFCSmokeView() }
            Divider().opacity(0.4)
            diagnosticRow(title: "TumoCard NFC Smoke", systemImage: "rectangle.stack.badge.person.crop", help: .tumoCard) { TumoCardNFCSmokeView() }
            Divider().opacity(0.4)
            diagnosticRow(title: "TumoFabric Counter", systemImage: "point.3.connected.trianglepath.dotted", help: .tumoFabric) { TumoFabricView() }
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
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { helpTopic = nil } }
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
                Image(systemName: "questionmark.circle").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("About \(title)")
        }
    }
}
