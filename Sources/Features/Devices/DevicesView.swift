import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var ble: FlipperBLE
    @EnvironmentObject var control: FlipperControl
    @Binding var path: [HomeTileID]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                LiveDeckHomeView(path: $path, refreshAction: refreshConnection)
                    .navigationTitle("Home")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            if ble.state == .connected || ble.state == .ready {
                                Button("Disconnect") { ble.disconnect() }
                            } else {
                                Button {
                                    ble.state == .scanning ? ble.stopScan() : ble.startScan()
                                } label: {
                                    Image(systemName: ble.state == .scanning ? "stop.circle" : "arrow.clockwise")
                                }
                                .accessibilityLabel(ble.state == .scanning ? "Stop scan" : "Scan for Flippers")
                            }
                        }
                    }
                    .onAppear {
                        if ble.state == .disconnected { ble.autoConnect() }
                        if ble.state == .ready { control.startScreenStream() }
                    }
                    .onDisappear {
                        control.stopScreenStream()
                    }
                    .onChange(of: ble.state) { _, state in
                        if state == .ready {
                            control.startScreenStream()
                        } else {
                            control.stopScreenStream()
                        }
                    }
            }
            .navigationDestination(for: HomeTileID.self) { destination($0) }
        }
    }

    private func refreshConnection() async {
        ble.autoConnect()
        if ble.state == .ready { control.startScreenStream() }
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
        case .esp32:         ESP32FirmwareView()
        case .updates:       UpdatesView()
        case .backup:        BackupView()
        case .remotes:       RemotesView()
        case .media:         MediaRemoteView()
        case .screen:        ScreenView()
        }
    }
}
