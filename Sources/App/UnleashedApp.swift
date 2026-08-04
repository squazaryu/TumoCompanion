import SwiftUI
import UIKit

@main
struct UnleashedApp: App {
    @StateObject private var ble = FlipperBLE.shared
    @StateObject private var rpc = FlipperRPC.shared
    @StateObject private var control = FlipperControl()
    @StateObject private var relay = RelayExecutor()
    @StateObject private var companion = CompanionBridge.shared
    @StateObject private var aiRadarRelay = AIRadarRelay()
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var transfer = TransferChannelStore.shared
    @StateObject private var updates = UpdatesCoordinator()
    @StateObject private var deviceServices = DeviceServiceCoordinator()
    @StateObject private var fieldServices = FieldServicesStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Give the tab bar a fully-configured opaque appearance applied to BOTH
        // standard AND scrollEdge. Without scrollEdge set, iOS 15+ leaves the bar
        // metrics undefined on first paint, so labels render shifted/clipped until
        // an interaction forces a re-layout (the "titles slide down then fix after
        // I tap a tab" bug). No custom font this time — that broke the metrics.
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        // BG task handler must be registered before launch completes.
        UpdateNotificationPresenter.shared.configure()
        PluginUpdateMonitor.register()
        Task { @MainActor in
            await InstallActivityController.dismissOrphanedActivities()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(ble)
                .environmentObject(rpc)
                .environmentObject(control)
                .environmentObject(relay)
                .environmentObject(companion)
                .environmentObject(aiRadarRelay)
                .environmentObject(settings)
                .environmentObject(transfer)
                .environmentObject(updates)
                .environmentObject(deviceServices)
                .environmentObject(fieldServices)
                .tint(.orange)
                .background(WindowStyleApplier(style: settings.appearance.uiStyle))
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the foreground: reattach to the Flipper. A Flipper
            // stops advertising while connected, so this reattaches to the held
            // link instead of a scan that would never find it.
            if phase == .active {
                ble.autoConnect()
                PluginUpdateMonitor.applicationDidBecomeActive()
                MacBridgeDiscovery.shared.start()
                HomeAssistantDiscovery.shared.start()
                BuddyRelay.shared.startIfEnabled()
                transfer.restoreSavedUSBRoot(showError: false)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var relay: RelayExecutor
    @EnvironmentObject var settings: SettingsStore
    @State private var tab = 0
    @State private var homePath: [HomeTileID] = []

    @ViewBuilder
    var body: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-fw-packages-action-bar-qa") {
            FWPackagesActionBarQAView()
        } else if ProcessInfo.processInfo.arguments.contains("-device-info-layout-qa") {
            DeviceInfoLayoutQAView()
        } else if ProcessInfo.processInfo.arguments.contains("-live-activity-layout-qa") {
            LiveActivityLayoutQAView()
        } else if ProcessInfo.processInfo.arguments.contains("-wifi-map-density-qa") {
            WiFiNetworkMapDensityQAView()
        } else if ProcessInfo.processInfo.arguments.contains("-wifi-live-map-cluster-qa") {
            WiFiLiveMapSelectionQAView(showCluster: true)
        } else if ProcessInfo.processInfo.arguments.contains("-wifi-live-map-selection-qa") {
            WiFiLiveMapSelectionQAView()
        } else {
            appContent
        }
#else
        appContent
#endif
    }

    private var appContent: some View {
        tabs
            .fullScreenCover(isPresented: Binding(
                get: { !settings.onboardingDone },
                set: { if $0 == false { settings.onboardingDone = true } })) {
                OnboardingView { settings.onboardingDone = true }
            }
            .onOpenURL { handle($0) }
    }

    private var tabs: some View {
        // Four top-level tabs. Files / Relay / WiFi and the tool screens still live as
        // tiles on Home (grouped + customizable); deep links push them onto Home's stack.
        // Apps Market is its own persistent tab since it's a whole browse/search/install
        // flow, not a one-shot tool.
        TabView(selection: $tab) {
            DevicesView(path: $homePath)
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            ScreenView()
                .tabItem { Label("Screen", systemImage: "rectangle.on.rectangle") }.tag(1)
            NavigationStack { CatalogListView() }
                .tabItem { Label("Apps Market", systemImage: "bag.fill") }.tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
    }

    /// Handle external / Shortcut deep links: unleashed://<dest> and unleashed://relay/<action>.
    /// Files / Relay / WiFi are no longer tabs, so they're pushed onto Home's stack.
    private func handle(_ url: URL) {
        guard url.scheme == "unleashed" else { return }
        switch url.host {
        case "home":     tab = 0; homePath = []
        case "screen":   tab = 1
        case "appstore": tab = 2
        case "settings": tab = 3
        case "files":    tab = 0; homePath = [.files]
        case "wifi":     tab = 0; homePath = [.wifi]
        case "media":    tab = 0; homePath = [.media]
        case "tumonet":  tab = 0; homePath = [.tumonet]
        case "relay":
            tab = 0; homePath = [.relay]
            let action = url.pathComponents.last ?? ""
            if ["on", "off", "toggle"].contains(action) { relay.test(action: action) }
        default: break
        }
    }

}

#if DEBUG
private struct LiveActivityLayoutQAView: View {
    @State private var controller = InstallActivityController()

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Live Activity QA")
                .font(.headline)
            Text("Background the app to inspect Lock Screen and Dynamic Island progress.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task {
            controller.start(total: 4, title: "Installing firmware packages")
            controller.update(
                current: 2,
                total: 4,
                detail: "tumoflip_xremote.fap"
            )
        }
    }
}
#endif
