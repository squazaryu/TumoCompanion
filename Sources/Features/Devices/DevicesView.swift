import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var control: FlipperControl
    @EnvironmentObject var updates: UpdatesCoordinator
    @Binding var path: [HomeTileID]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                LiveDeckHomeView(path: $path, refreshAction: refreshConnection)
                    .navigationTitle("Home")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            if ble.state == .connected || ble.state == .ready {
                                Button("Disconnect") { ble.disconnect() }
                            } else if ble.state == .scanning {
                                Button {
                                    ble.stopScan()
                                } label: {
                                    Image(systemName: "stop.circle")
                                }
                                .accessibilityLabel("Stop scan")
                            }
                        }
                    }
                    .onAppear {
                        if ble.state == .disconnected { ble.autoConnect() }
                        control.startScreenStream(for: .home)
                    }
                    .onDisappear {
                        control.stopScreenStream(for: .home)
                    }
                    .onChange(of: ble.state) { _, _ in
                        control.reconcileScreenStream()
                    }
            }
            .navigationDestination(for: HomeTileID.self) { destination($0) }
        }
    }

    private func refreshConnection() async {
        ble.autoConnect()
        control.startScreenStream(for: .home)
        // Give CoreBluetooth a short window to publish a retained-link state before
        // the refresh control disappears. Never start a second scan here.
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    @ViewBuilder
    private func destination(_ tile: HomeTileID) -> some View {
        switch tile {
        case .info:          DeviceInfoView()
        case .apps:          InstalledAppsView()
        case .files:         FilesView()
        case .airadar:       AIRadarView()
        case .wifi:          TumoSurveyView()
        case .fieldServices: FieldServicesView()
        case .spectrum:      TumoSpectrumView()
        case .relay:         BridgeView()
        case .tumonet:       TumoNetView()
        case .esp32:         ESP32FirmwareView(updater: updates.esp32)
        case .updates:       UpdatesView()
        case .backup:        BackupView()
        case .remotes:       RemotesView()
        case .media:         MediaRemoteView()
        case .screen:        ScreenView()
        case .firmware:      FirmwareLibraryView(library: updates.firmware)
        case .packages:      TumoflipUpdaterView(updater: updates.packages)
        case .communityApps: PluginUpdatesDetailView(updater: updates.plugins)
        }
    }
}
