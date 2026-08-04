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
    // Standard Core Location may keep a good stationary fix without refreshing
    // its embedded timestamp every few seconds, especially indoors. A fix
    // delivered by this active provider remains usable while its reported
    // accuracy is bounded; freshness still controls the preferred/approximate
    // UI state and the accuracy is carried into the estimator.
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
        let receivedAt = Date()
        let accessPoints = pendingAccessPoints.compactMap { pending in
            receivedAt.timeIntervalSince(pending.receivedAt) <= Self.maximumAssociationDelay ?
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
            fix.horizontalAccuracy <= maximumHorizontalAccuracy
    }

    private static func isPreferred(_ fix: CLLocation) -> Bool {
        fix.horizontalAccuracy > 0 &&
            fix.horizontalAccuracy <= preferredHorizontalAccuracy &&
            abs(fix.timestamp.timeIntervalSinceNow) <= preferredFixAge
    }

#if DEBUG
    func loadSelectionQA(_ values: [WiFiMapperAPEstimate]) {
        estimates = values
        uniqueNetworks = values.count
        observations = values.reduce(0) { $0 + $1.observationCount }
        points = values.enumerated().map { index, estimate in
            WiFiMapperPoint(
                id: "qa|\(estimate.id)|\(index)",
                sourceName: "qa",
                ssid: estimate.ssid,
                bssid: estimate.bssid,
                auth: "WPA2",
                channel: estimate.channel,
                rssi: estimate.averageRSSI,
                bestRSSI: nil,
                lastRSSI: nil,
                averageRSSI: nil,
                samples: estimate.observationCount,
                tickMS: nil,
                firstTickMS: nil,
                lastTickMS: nil,
                latitude: estimate.coordinate.latitude,
                longitude: estimate.coordinate.longitude,
                altitude: nil,
                accuracy: estimate.averageAccuracyMeters)
        }
        lastObservationAt = Date()
    }
#endif
}

private struct PendingAccessPoint {
    let accessPoint: MarauderAP
    let receivedAt: Date
}

struct WiFiMapperLiveMapView: View {
    @EnvironmentObject var ble: FlipperBLE
    @StateObject private var vm: WiFiMapperLiveMapViewModel
    private let ownsViewModel: Bool
    @State private var mapSelection: WiFiNetworkMapSelection?
    @State private var detailItemIDs: [String] = []
    @State private var mapCommand = WiFiNetworkMapCommand.fitAll()

    @MainActor
    init() {
        _vm = StateObject(wrappedValue: WiFiMapperLiveMapViewModel())
        ownsViewModel = true
    }

    @MainActor
    init(
        viewModel: WiFiMapperLiveMapViewModel,
        initialSelection: WiFiNetworkMapSelection? = nil,
        initialDetailItemIDs: [String] = []
    ) {
        _vm = StateObject(wrappedValue: viewModel)
        _mapSelection = State(initialValue: initialSelection)
        _detailItemIDs = State(initialValue: initialDetailItemIDs)
        ownsViewModel = false
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
                    clearMapSelection()
                } label: {
                    Image(systemName: "trash")
                }
                    .disabled(vm.observations == 0)
            }
        }
        .task {
            // Standalone entry points own their model. The TumoSurvey dashboard
            // passes a workspace-owned model which must keep collecting while
            // navigation swaps the dashboard and map views.
            if ownsViewModel { vm.start() }
        }
        .onDisappear {
            if ownsViewModel { vm.stop() }
        }
        .onChange(of: mapSelection) { _, selection in
            synchronizeDetailState(with: selection)
        }
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
                detailItemIDs: detailItemIDs,
                selection: $mapSelection,
                command: mapCommand)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            mapSelectionDetail

            Text("Clusters keep the overview readable. Open one for exact estimated coordinates, then inspect its networks without moving their map positions.")
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
            let estimates = orderedEstimates(for: itemIDs)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(estimates.count) nearby estimates", systemImage: "square.3.layers.3d")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    clearMapSelectionButton
                }
                Text(clusterDetailDescription(estimates))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(estimates.prefix(5))) { estimate in
                        clusterEstimateRow(estimate)
                        if estimate.id != estimates.prefix(5).last?.id {
                            Divider().opacity(0.25)
                        }
                    }
                }
                if estimates.count > 5 {
                    Menu {
                        ForEach(estimates.dropFirst(5)) { estimate in
                            Button {
                                selectEstimate(estimate, retainingCluster: true)
                            } label: {
                                Text("\(estimate.displaySSID) · \(estimate.bssid)")
                            }
                        }
                    } label: {
                        Label("Show \(estimates.count - 5) more", systemImage: "ellipsis.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "scope")
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
                clearMapSelectionButton
            }

            HStack(spacing: 8) {
                Label(coordinateText(estimate), systemImage: "mappin.and.ellipse")
                    .font(.system(.caption2, design: .monospaced))
                Spacer(minLength: 4)
                if let distance = distanceFromPhone(estimate) {
                    Text(distance)
                        .font(.caption2)
                        .monospacedDigit()
                }
                Text("\(estimate.observationCount)x")
                    .font(.caption2)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            if let position = detailPosition(of: estimate) {
                Divider().opacity(0.3)
                HStack {
                    Button {
                        selectDetailEstimate(at: position - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(position == 0)
                    .accessibilityLabel("Previous network in cluster")
                    Spacer()
                    Text("\(position + 1) of \(detailEstimates.count) in cluster")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        selectDetailEstimate(at: position + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(position + 1 >= detailEstimates.count)
                    .accessibilityLabel("Next network in cluster")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var clearMapSelectionButton: some View {
        Button {
            clearMapSelection()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear network selection")
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
                        selectEstimate(estimate, retainingCluster: false)
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

    private var detailEstimates: [WiFiMapperAPEstimate] {
        orderedEstimates(for: detailItemIDs)
    }

    private func orderedEstimates(for itemIDs: [String]) -> [WiFiMapperAPEstimate] {
        let ids = Set(itemIDs)
        return vm.estimates
            .filter { ids.contains(WiFiNetworkMapItem.estimate($0).id) }
            .sorted {
                if $0.averageRSSI != $1.averageRSSI { return $0.averageRSSI > $1.averageRSSI }
                return $0.displaySSID.localizedCaseInsensitiveCompare($1.displaySSID) == .orderedAscending
            }
    }

    private func synchronizeDetailState(with selection: WiFiNetworkMapSelection?) {
        switch selection {
        case let .cluster(itemIDs):
            detailItemIDs = orderedEstimates(for: itemIDs).map {
                WiFiNetworkMapItem.estimate($0).id
            }
        case let .item(itemID):
            if !detailItemIDs.contains(itemID) { detailItemIDs = [] }
            mapCommand = .focus(itemID)
        case nil:
            detailItemIDs = []
        }
    }

    private func clearMapSelection() {
        detailItemIDs = []
        mapSelection = nil
    }

    private func selectEstimate(
        _ estimate: WiFiMapperAPEstimate,
        retainingCluster: Bool
    ) {
        let itemID = WiFiNetworkMapItem.estimate(estimate).id
        if !retainingCluster { detailItemIDs = [] }
        mapSelection = .item(itemID)
        mapCommand = .focus(itemID)
    }

    private func selectDetailEstimate(at index: Int) {
        guard detailEstimates.indices.contains(index) else { return }
        selectEstimate(detailEstimates[index], retainingCluster: true)
    }

    private func detailPosition(of estimate: WiFiMapperAPEstimate) -> Int? {
        let itemID = WiFiNetworkMapItem.estimate(estimate).id
        return detailEstimates.firstIndex {
            WiFiNetworkMapItem.estimate($0).id == itemID
        }
    }

    private func clusterEstimateRow(_ estimate: WiFiMapperAPEstimate) -> some View {
        Button {
            selectEstimate(estimate, retainingCluster: true)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(confidenceColor(estimate))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimate.displaySSID)
                        .font(.caption)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(estimate.bssid)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(estimate.averageRSSI) dBm")
                    Text("±\(Int(estimate.radiusMeters.rounded())) m")
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func clusterDetailDescription(_ estimates: [WiFiMapperAPEstimate]) -> String {
        guard estimates.count > 1 else {
            return "Select the network to inspect its estimated coordinate and uncertainty."
        }
        let spread = maximumSpread(of: estimates)
        return "Estimated points span \(Int(spread.rounded())) m. Select a network to center its true estimate; markers are not artificially separated."
    }

    private func maximumSpread(of estimates: [WiFiMapperAPEstimate]) -> CLLocationDistance {
        var result: CLLocationDistance = 0
        for firstIndex in estimates.indices {
            for secondIndex in estimates.indices where secondIndex > firstIndex {
                let first = CLLocation(
                    latitude: estimates[firstIndex].coordinate.latitude,
                    longitude: estimates[firstIndex].coordinate.longitude)
                let second = CLLocation(
                    latitude: estimates[secondIndex].coordinate.latitude,
                    longitude: estimates[secondIndex].coordinate.longitude)
                result = max(result, first.distance(from: second))
            }
        }
        return result
    }

    private func coordinateText(_ estimate: WiFiMapperAPEstimate) -> String {
        String(format: "%.5f, %.5f", estimate.coordinate.latitude, estimate.coordinate.longitude)
    }

    private func distanceFromPhone(_ estimate: WiFiMapperAPEstimate) -> String? {
        guard let phoneLocation = vm.location.location else { return nil }
        let estimateLocation = CLLocation(
            latitude: estimate.coordinate.latitude,
            longitude: estimate.coordinate.longitude)
        let distance = estimateLocation.distance(from: phoneLocation)
        if distance < 1_000 { return "\(Int(distance.rounded())) m away" }
        return String(format: "%.1f km away", distance / 1_000)
    }
}

#if DEBUG
struct WiFiLiveMapSelectionQAView: View {
    private static let estimates: [WiFiMapperAPEstimate] = [
        qaEstimate(0, "TUMO LAB", -51, 38, 0.00000, 0.00000, .medium),
        qaEstimate(1, "Studio WiFi", -57, 46, 0.00010, 0.00006, .medium),
        qaEstimate(2, "Workshop", -63, 58, -0.00008, 0.00012, .low),
        qaEstimate(3, "Guest", -68, 72, 0.00014, -0.00009, .low),
        qaEstimate(4, "Office 5G", -48, 29, -0.00011, -0.00007, .high),
        qaEstimate(5, "<hidden>", -71, 81, 0.00004, 0.00016, .low),
    ]

    private static func qaEstimate(
        _ index: Int,
        _ name: String,
        _ rssi: Int,
        _ radius: Double,
        _ latitudeOffset: Double,
        _ longitudeOffset: Double,
        _ confidence: WiFiMapperAPConfidence
    ) -> WiFiMapperAPEstimate {
        let bssid = "AA:BB:CC:DD:EE:\(String(format: "%02X", index))"
        return WiFiMapperAPEstimate(
            id: bssid,
            ssid: name,
            bssid: bssid,
            channel: [1, 6, 11][index % 3],
            coordinate: CLLocationCoordinate2D(
                latitude: 55.7558 + latitudeOffset,
                longitude: 37.6173 + longitudeOffset),
            observationCount: 12 - index,
            strongestRSSI: rssi + 8,
            averageRSSI: rssi,
            radiusMeters: radius,
            maxSpreadMeters: max(radius - 10, 5),
            averageAccuracyMeters: 14 + Double(index),
            confidence: confidence)
    }

    @StateObject private var viewModel: WiFiMapperLiveMapViewModel
    private let showCluster: Bool

    @MainActor
    init(showCluster: Bool = false) {
        let viewModel = WiFiMapperLiveMapViewModel()
        viewModel.loadSelectionQA(Self.estimates)
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showCluster = showCluster
    }

    var body: some View {
        let itemIDs = Self.estimates.map { WiFiNetworkMapItem.estimate($0).id }
        NavigationStack {
            WiFiMapperLiveMapView(
                viewModel: viewModel,
                initialSelection: showCluster ? .cluster(itemIDs) : .item(itemIDs[0]),
                initialDetailItemIDs: itemIDs)
        }
        .environmentObject(FlipperBLE.shared)
    }
}
#endif
