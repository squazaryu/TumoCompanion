import SwiftUI
import MapKit
import Combine
import CoreLocation
import UIKit

/// Live WiFi mapping using the **iPhone's GPS** (not an ESP32 GPS module): each
/// scan line relayed from TumoSurvey over App Bridge is tagged with
/// the phone's current position, and the shared `WiFiMapperAPEstimator` estimates
/// each access point from the signal-weighted spread of those observations. Walk/drive
/// while the AP estimates update in real time.
@MainActor
final class WiFiMapperLiveMapViewModel: ObservableObject {
    @Published private(set) var points: [WiFiMapperPoint] = []
    @Published private(set) var estimates: [WiFiMapperAPEstimate] = []
    @Published private(set) var uniqueNetworks = 0
    @Published private(set) var observations = 0
    @Published private(set) var lastObservationAt: Date?
    @Published private(set) var running = false
    @Published private(set) var session = TumoSurveySessionState()

    let location = LocationProvider()
    private let ble: FlipperBLE
    private var relaySub: AnyCancellable?
    private var locationSubscriptions = Set<AnyCancellable>()
    private var pendingAccessPoints: [PendingAccessPoint] = []
    private var seq = 0
    private static let pendingLimit = 500
    // Standard Core Location may reuse a good stationary fix instead of
    // publishing a new timestamp every few seconds, especially indoors. Keep a
    // bounded window and carry the reported accuracy into the estimator rather
    // than making the entire map disappear when a fix is merely approximate.
    private static let maximumFixAge: TimeInterval = 30
    private static let maximumAssociationDelay: TimeInterval = 30
    private static let maximumHorizontalAccuracy = 200.0
    private static let preferredFixAge: TimeInterval = 10
    private static let preferredHorizontalAccuracy = 50.0

    var hasUsableLocation: Bool {
        location.location.map(Self.isUsable) ?? false
    }

    var hasPreferredLocation: Bool {
        location.location.map(Self.isPreferred) ?? false
    }

    init(ble: FlipperBLE = .shared) {
        self.ble = ble
        location.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &locationSubscriptions)
        location.$location
            .compactMap { $0 }
            .sink { [weak self] fix in
                guard let self else { return }
                // Place any scan rows that arrived while Core Location acquired
                // its fix. The nested provider publisher refreshes the UI.
                self.receiveLocation(fix)
            }
            .store(in: &locationSubscriptions)
    }

    func start() {
        location.start()
        running = true
        guard relaySub == nil else { return }
        relaySub = ble.appBridgeIn
            .filter {
                $0.appID == "wifi_mapper" &&
                TumoSurveySessionState.accepts(command: $0.command)
            }
            .sink { [weak self] frame in self?.handle(frame) }
    }

    func stop() {
        running = false
        relaySub?.cancel(); relaySub = nil
        location.stop()
    }

    func clear() {
        points = []
        estimates = []
        uniqueNetworks = 0
        observations = 0
        lastObservationAt = nil
        pendingAccessPoints = []
        seq = 0
    }

    private func handle(_ frame: AppBridgeFrame) {
        let transition = session.apply(command: frame.command, payload: frame.payload)
        if transition == .started {
            clear()
            return
        }
        guard transition == .data else { return }
        guard let text = String(data: frame.payload, encoding: .utf8), !text.isEmpty else { return }
        ingest(text, using: location.location)
    }

    /// Parse a relayed batch and place it at the current iPhone fix. Rows that
    /// beat the first GPS callback are kept briefly instead of being lost.
    func ingest(_ text: String, using fix: CLLocation?) {
        let accessPoints = MarauderLogParser.parse(text).aps.filter {
            $0.rssi != nil && !$0.bssid.isEmpty
        }
        guard !accessPoints.isEmpty else { return }
        guard let fix, Self.isUsable(fix) else {
            let receivedAt = Date()
            pendingAccessPoints.append(contentsOf: accessPoints.map {
                PendingAccessPoint(accessPoint: $0, receivedAt: receivedAt)
            })
            if pendingAccessPoints.count > Self.pendingLimit {
                pendingAccessPoints.removeFirst(pendingAccessPoints.count - Self.pendingLimit)
            }
            return
        }
        append(accessPoints, using: fix)
    }

    func receiveLocation(_ fix: CLLocation) {
        guard !pendingAccessPoints.isEmpty, Self.isUsable(fix) else { return }
        // Only associate rows that arrived close to this fix. Assigning an old
        // scan batch to a later position creates convincing but false AP pins.
        let accessPoints = pendingAccessPoints.compactMap { pending in
            abs(fix.timestamp.timeIntervalSince(pending.receivedAt)) <= Self.maximumAssociationDelay ?
                pending.accessPoint : nil
        }
        pendingAccessPoints = []
        if !accessPoints.isEmpty { append(accessPoints, using: fix) }
    }

    private func append(_ accessPoints: [MarauderAP], using fix: CLLocation) {
        let coord = fix.coordinate
        for ap in accessPoints {
            guard let rssi = ap.rssi else { continue }
            seq += 1
            points.append(WiFiMapperPoint(
                id: "live|\(ap.bssid)|\(seq)",
                sourceName: "live",
                ssid: ap.ssid,
                bssid: ap.bssid,
                auth: ap.auth,
                channel: ap.channel,
                rssi: rssi,
                bestRSSI: nil, lastRSSI: nil, averageRSSI: nil,
                samples: 1,
                tickMS: nil, firstTickMS: nil, lastTickMS: nil,
                latitude: coord.latitude,
                longitude: coord.longitude,
                altitude: fix.altitude,
                accuracy: fix.horizontalAccuracy))
            observations += 1
        }
        lastObservationAt = Date()
        uniqueNetworks = Set(points.map(\.bssid)).count
        // A single observation is still useful: it is shown as a low-confidence
        // position near the phone and converges as more readings arrive.
        estimates = WiFiMapperAPEstimator.estimates(from: points, minimumObservations: 1)
    }

    private static func isUsable(_ fix: CLLocation) -> Bool {
        fix.horizontalAccuracy > 0 &&
            fix.horizontalAccuracy <= maximumHorizontalAccuracy &&
            abs(fix.timestamp.timeIntervalSinceNow) <= maximumFixAge
    }

    private static func isPreferred(_ fix: CLLocation) -> Bool {
        fix.horizontalAccuracy > 0 &&
            fix.horizontalAccuracy <= preferredHorizontalAccuracy &&
            abs(fix.timestamp.timeIntervalSinceNow) <= preferredFixAge
    }
}

private struct PendingAccessPoint {
    let accessPoint: MarauderAP
    let receivedAt: Date
}

struct WiFiMapperLiveMapView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm: WiFiMapperLiveMapViewModel
    @State private var mapSelection: WiFiNetworkMapSelection?
    @State private var mapCommand = WiFiNetworkMapCommand.fitAll()

    @MainActor
    init() {
        _vm = StateObject(wrappedValue: WiFiMapperLiveMapViewModel())
    }

    @MainActor
    init(viewModel: WiFiMapperLiveMapViewModel) {
        _vm = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        CardScroll {
            statusCard
            if !vm.points.isEmpty {
                mapCard
                if !vm.estimates.isEmpty { estimatesCard }
            }
        }
        .navigationTitle("Live Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    vm.clear()
                    mapSelection = nil
                } label: {
                    Image(systemName: "trash")
                }
                    .disabled(vm.observations == 0)
            }
        }
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    private var statusCard: some View {
        SectionCard(title: "Live WiFi Map", systemImage: "location.viewfinder",
                    accessory: AnyView(StatusPill(
                        text: ble.appBridgeV2 ? "App Bridge v2" : "No bridge",
                        color: ble.appBridgeV2 ? .green : .orange,
                        systemImage: "antenna.radiowaves.left.and.right"))) {
            if vm.location.isDenied {
                Label("Location access is off. Enable it in Settings so scans can be placed on the map.",
                      systemImage: "location.slash.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url).font(.caption)
                }
            } else if !ble.appBridgeV2 {
                Label("App Bridge v2 not available — needs a firmware that negotiates it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                gpsRow
                HStack {
                    statTile("\(vm.observations)", "readings")
                    statTile("\(vm.uniqueNetworks)", "networks")
                    statTile("\(vm.estimates.count)", "AP est.")
                }
                if !vm.hasUsableLocation {
                    Label("Waiting for an iPhone location fix. Recent scan rows are buffered for up to 30 seconds.",
                          systemImage: "location.magnifyingglass")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !vm.hasPreferredLocation {
                    Label("Using an approximate iPhone fix. The map stays available and shows a wider uncertainty area.",
                          systemImage: "location.circle")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if vm.observations == 0 {
                    Label(vm.session.isActive ? "Survey active — waiting for mapped observations." : "Waiting for an active survey.",
                          systemImage: "figure.walk")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var gpsRow: some View {
        HStack(spacing: 6) {
            Circle().fill(vm.hasPreferredLocation ? .green : .orange).frame(width: 7, height: 7)
            if let fix = vm.location.location {
                let state = vm.hasUsableLocation ? (vm.hasPreferredLocation ? "" : " · approximate") : " · waiting"
                Text("GPS ±\(Int(fix.horizontalAccuracy)) m\(state)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Acquiring GPS…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let at = vm.lastObservationAt {
                Text("last reading \(at, style: .relative) ago")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var mapCard: some View {
        SectionCard(title: "Map", systemImage: "map") {
            WiFiNetworkClusterMap(
                items: liveMapItems,
                showsUserLocation: true,
                selection: $mapSelection,
                command: mapCommand)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            mapSelectionDetail

            Text("Nearby networks are grouped into numbered clusters. Tap a marker to show only that network's uncertainty ring; its estimate improves as you move around it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { mapCommand = .followUser() } label: {
                    Label("Follow me", systemImage: "location.fill")
                }
                Spacer()
                Button { mapCommand = .fitAll() } label: {
                    Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var liveMapItems: [WiFiNetworkMapItem] {
        vm.estimates.map(WiFiNetworkMapItem.estimate)
    }

    @ViewBuilder
    private var mapSelectionDetail: some View {
        switch mapSelection {
        case let .item(itemID):
            if let estimate = estimate(for: itemID) {
                selectedEstimateCard(estimate)
            } else {
                mapHint
            }
        case let .cluster(itemIDs):
            let items = liveMapItems.filter { itemIDs.contains($0.id) }
            VStack(alignment: .leading, spacing: 8) {
                Label("\(items.count) networks overlap here", systemImage: "square.3.layers.3d")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Choose one to inspect its estimated position and uncertainty.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            Button {
                                mapSelection = .item(item.id)
                            } label: {
                                Label(item.title, systemImage: "wifi")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(item.tone.color)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case nil:
            mapHint
        }
    }

    private var mapHint: some View {
        Label("Tap a marker or numbered cluster for network details.", systemImage: "hand.tap")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedEstimateCard(_ estimate: WiFiMapperAPEstimate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.circle.fill")
                .font(.title2)
                .foregroundStyle(confidenceColor(estimate))
            VStack(alignment: .leading, spacing: 3) {
                Text(estimate.displaySSID)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(estimate.bssid)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    Label("±\(Int(estimate.radiusMeters.rounded())) m", systemImage: "circle.dashed")
                    Label("\(estimate.averageRSSI) dBm", systemImage: "wave.3.right")
                    if let channel = estimate.channel {
                        Text("ch \(channel)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text("\(estimate.observationCount)x")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func estimate(for mapItemID: String) -> WiFiMapperAPEstimate? {
        vm.estimates.first { WiFiNetworkMapItem.estimate($0).id == mapItemID }
    }

    private var estimatesCard: some View {
        CollapsibleCard(title: "Estimated APs", systemImage: "location.circle",
                        accessory: AnyView(StatusPill(text: "\(vm.estimates.count)", color: .secondary))) {
            VStack(spacing: 8) {
                ForEach(Array(vm.estimates.prefix(80))) { estimate in
                    Button {
                        mapSelection = .item(WiFiNetworkMapItem.estimate(estimate).id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "location.circle")
                                .foregroundStyle(confidenceColor(estimate)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(estimate.displaySSID).font(.subheadline).fontWeight(.medium).lineLimit(1)
                                Text(estimate.bssid).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("±\(Int(estimate.radiusMeters.rounded())) m").font(.caption).monospacedDigit()
                                Text("\(estimate.confidence.label) · \(estimate.observationCount)x")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Divider().opacity(0.25)
                }
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).fontWeight(.bold).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func confidenceColor(_ estimate: WiFiMapperAPEstimate) -> Color {
        switch estimate.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}
