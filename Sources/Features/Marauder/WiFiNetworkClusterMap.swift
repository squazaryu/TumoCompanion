import MapKit
import SwiftUI
import UIKit

enum WiFiNetworkMapTone: Equatable {
    case green
    case orange
    case red
    case blue

    var color: Color {
        switch self {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .blue: return .blue
        }
    }

    var uiColor: UIColor {
        switch self {
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .blue: return .systemBlue
        }
    }
}

struct WiFiNetworkMapItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case estimate
        case observation
    }

    let id: String
    let sourceID: String
    let kind: Kind
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let tone: WiFiNetworkMapTone
    let uncertaintyRadiusMeters: Double?

    static func estimate(_ estimate: WiFiMapperAPEstimate) -> WiFiNetworkMapItem {
        WiFiNetworkMapItem(
            id: "estimate|\(estimate.id)",
            sourceID: estimate.id,
            kind: .estimate,
            title: estimate.displaySSID,
            subtitle: "\(estimate.bssid) · ±\(Int(estimate.radiusMeters.rounded())) m",
            coordinate: estimate.coordinate,
            tone: tone(for: estimate.confidence),
            uncertaintyRadiusMeters: estimate.radiusMeters)
    }

    static func observation(_ point: WiFiMapperPoint) -> WiFiNetworkMapItem {
        let detail = [
            point.bssid.isEmpty ? nil : point.bssid,
            point.primaryRSSI.map { "\($0) dBm" },
        ].compactMap { $0 }.joined(separator: " · ")

        return WiFiNetworkMapItem(
            id: "observation|\(point.id)",
            sourceID: point.id,
            kind: .observation,
            title: point.displaySSID,
            subtitle: detail,
            coordinate: point.coordinate,
            tone: tone(for: point.primaryRSSI),
            uncertaintyRadiusMeters: nil)
    }

    private static func tone(for confidence: WiFiMapperAPConfidence) -> WiFiNetworkMapTone {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }

    private static func tone(for rssi: Int?) -> WiFiNetworkMapTone {
        guard let rssi else { return .blue }
        if rssi >= -55 { return .green }
        if rssi >= -70 { return .orange }
        return .red
    }

    static func == (lhs: WiFiNetworkMapItem, rhs: WiFiNetworkMapItem) -> Bool {
        lhs.id == rhs.id &&
            lhs.sourceID == rhs.sourceID &&
            lhs.kind == rhs.kind &&
            lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.tone == rhs.tone &&
            lhs.uncertaintyRadiusMeters == rhs.uncertaintyRadiusMeters
    }
}

enum WiFiNetworkMapSelection: Equatable {
    case item(String)
    case cluster([String])
}

struct WiFiNetworkMapCommand: Equatable {
    enum Action: Equatable {
        case fitAll
        case followUser
        case focus(String)
    }

    let id = UUID()
    let action: Action

    static func fitAll() -> WiFiNetworkMapCommand {
        WiFiNetworkMapCommand(action: .fitAll)
    }

    static func followUser() -> WiFiNetworkMapCommand {
        WiFiNetworkMapCommand(action: .followUser)
    }

    static func focus(_ itemID: String) -> WiFiNetworkMapCommand {
        WiFiNetworkMapCommand(action: .focus(itemID))
    }
}

enum WiFiNetworkMapPresentation {
    static func selectedUncertaintyItem(
        selection: WiFiNetworkMapSelection?,
        items: [WiFiNetworkMapItem]
    ) -> WiFiNetworkMapItem? {
        guard case let .item(id) = selection,
              let item = items.first(where: { $0.id == id }),
              item.kind == .estimate,
              let radius = item.uncertaintyRadiusMeters,
              radius > 0
        else { return nil }

        return item
    }
}

struct WiFiNetworkClusterMap: UIViewRepresentable {
    let items: [WiFiNetworkMapItem]
    let showsUserLocation: Bool
    var detailItemIDs: [String] = []
    @Binding var selection: WiFiNetworkMapSelection?
    let command: WiFiNetworkMapCommand

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = showsUserLocation
        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.networkReuseIdentifier)
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.clusterReuseIdentifier)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.selection = $selection
        mapView.showsUserLocation = showsUserLocation
        context.coordinator.update(
            items: items,
            detailItemIDs: detailItemIDs,
            on: mapView)
        context.coordinator.apply(selection: selection, on: mapView)
        context.coordinator.apply(command: command, on: mapView)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let networkReuseIdentifier = "TumoSurveyNetwork"
        static let clusterReuseIdentifier = "TumoSurveyCluster"

        var selection: Binding<WiFiNetworkMapSelection?>
        private var annotations: [String: WiFiNetworkAnnotation] = [:]
        private var selectedCircle: MKCircle?
        private var selectedCircleTone: WiFiNetworkMapTone = .orange
        private var lastCommandID: UUID?
        private var hasFittedInitialItems = false
        private var detailItemIDs: Set<String> = []

        init(selection: Binding<WiFiNetworkMapSelection?>) {
            self.selection = selection
        }

        func update(items: [WiFiNetworkMapItem], on mapView: MKMapView) {
            update(items: items, detailItemIDs: [], on: mapView)
        }

        func update(
            items: [WiFiNetworkMapItem],
            detailItemIDs requestedDetailIDs: [String],
            on mapView: MKMapView
        ) {
            let desired = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let nextDetailIDs = Set(requestedDetailIDs).intersection(desired.keys)
            let detailChanged = nextDetailIDs != detailItemIDs
            detailItemIDs = nextDetailIDs
            let removed = annotations.keys.filter { desired[$0] == nil }
            let removedAnnotations = removed.compactMap { annotations.removeValue(forKey: $0) }
            if !removedAnnotations.isEmpty {
                mapView.removeAnnotations(removedAnnotations)
            }

            var additions: [WiFiNetworkAnnotation] = []
            for item in items {
                if let annotation = annotations[item.id] {
                    if annotation.item != item {
                        annotation.update(with: item)
                        if let view = mapView.view(for: annotation) {
                            configure(view, for: item)
                        }
                    }
                } else {
                    let annotation = WiFiNetworkAnnotation(item: item)
                    annotations[item.id] = annotation
                    additions.append(annotation)
                }
            }
            if detailChanged {
                // MapKit calculates clusters when annotations are inserted.
                // Reinsert them only when entering/leaving a detail group so
                // its members can render at their true coordinates without
                // disabling clustering for the rest of the map.
                let current = Array(annotations.values)
                mapView.removeAnnotations(current)
                mapView.addAnnotations(current)
            } else if !additions.isEmpty {
                mapView.addAnnotations(additions)
            }

            if items.isEmpty {
                hasFittedInitialItems = false
            } else if detailChanged, !detailItemIDs.isEmpty {
                fitDetail(on: mapView, animated: true)
            } else if !hasFittedInitialItems {
                hasFittedInitialItems = true
                fitAll(on: mapView, animated: false)
            }
        }

        func apply(selection newSelection: WiFiNetworkMapSelection?, on mapView: MKMapView) {
            updateSelectedCircle(selection: newSelection, on: mapView)
            refreshVisibleStyles(on: mapView)

            guard newSelection != nil else {
                for annotation in mapView.selectedAnnotations {
                    mapView.deselectAnnotation(annotation, animated: true)
                }
                return
            }

            guard case let .item(id) = newSelection,
                  let annotation = annotations[id],
                  !mapView.selectedAnnotations.contains(where: { ($0 as? WiFiNetworkAnnotation)?.id == id })
            else { return }

            mapView.selectAnnotation(annotation, animated: true)
        }

        func apply(command: WiFiNetworkMapCommand, on mapView: MKMapView) {
            guard lastCommandID != command.id else { return }
            lastCommandID = command.id

            switch command.action {
            case .fitAll:
                mapView.setUserTrackingMode(.none, animated: false)
                fitAll(on: mapView, animated: true)
            case .followUser:
                mapView.setUserTrackingMode(.follow, animated: true)
            case let .focus(itemID):
                focus(itemID: itemID, on: mapView, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: Self.clusterReuseIdentifier,
                    for: cluster) as! MKMarkerAnnotationView
                view.annotation = cluster
                view.markerTintColor = .systemIndigo
                view.glyphTintColor = .white
                view.glyphImage = nil
                view.glyphText = cluster.memberAnnotations.count > 99 ? "99+" : "\(cluster.memberAnnotations.count)"
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.displayPriority = .required
                view.collisionMode = .circle
                view.canShowCallout = false
                view.clusteringIdentifier = nil
                view.alpha = detailItemIDs.isEmpty ? 1 : 0.38
                return view
            }

            guard let network = annotation as? WiFiNetworkAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.networkReuseIdentifier,
                for: network)
            view.annotation = network
            configure(view, for: network.item)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let network = view.annotation as? WiFiNetworkAnnotation {
                selection.wrappedValue = .item(network.id)
                updateSelectedCircle(selection: .item(network.id), on: mapView)
                return
            }

            guard let cluster = view.annotation as? MKClusterAnnotation else { return }
            let members = cluster.memberAnnotations.compactMap { $0 as? WiFiNetworkAnnotation }
            let ids = members.map(\.id).sorted()
            selection.wrappedValue = .cluster(ids)
            updateSelectedCircle(selection: nil, on: mapView)

            let distinctCoordinates = Set(members.map {
                CoordinateKey(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            })
            if distinctCoordinates.count > 1 {
                mapView.showAnnotations(members, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            let deselectedIDs: Set<String>
            if let network = view.annotation as? WiFiNetworkAnnotation {
                deselectedIDs = [network.id]
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                deselectedIDs = Set(cluster.memberAnnotations.compactMap {
                    ($0 as? WiFiNetworkAnnotation)?.id
                })
            } else {
                return
            }

            // Expanding a selected MapKit cluster reinserts its members with
            // clustering disabled. MapKit consequently deselects the cluster
            // annotation that it just removed. Keep the logical cluster
            // selection alive during that transition; a user deselecting an
            // individual detailed marker is still handled below.
            if case let .cluster(ids) = selection.wrappedValue,
               !detailItemIDs.isEmpty,
               !deselectedIDs.isDisjoint(with: ids) {
                return
            }

            switch selection.wrappedValue {
            case let .item(id) where deselectedIDs.contains(id):
                selection.wrappedValue = nil
            case let .cluster(ids) where !deselectedIDs.isDisjoint(with: ids):
                selection.wrappedValue = nil
            default:
                return
            }
            updateSelectedCircle(selection: nil, on: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.fillColor = selectedCircleTone.uiColor.withAlphaComponent(0.06)
            renderer.strokeColor = selectedCircleTone.uiColor.withAlphaComponent(0.85)
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [6, 4]
            return renderer
        }

        private func configure(_ view: MKAnnotationView, for item: WiFiNetworkMapItem) {
            let isDetailed = detailItemIDs.contains(item.id)
            let isSelected: Bool = {
                guard case let .item(id) = selection.wrappedValue else { return false }
                return id == item.id
            }()
            let symbol = isSelected ? "scope" :
                (item.kind == .estimate ? "wifi" : "dot.radiowaves.left.and.right")
            view.image = WiFiNetworkMarkerImage.image(
                tone: item.tone,
                symbol: symbol,
                selected: isSelected)
            view.centerOffset = .zero
            view.canShowCallout = false
            view.collisionMode = .circle
            view.clusteringIdentifier = isDetailed ? nil : "tumoflip.wifi.\(item.kind.rawValue)"
            view.displayPriority = isDetailed || isSelected ? .required :
                (item.kind == .estimate ? .defaultHigh : .defaultLow)
            view.alpha = detailItemIDs.isEmpty || isDetailed ? 1 : 0.38
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = isSelected ? 0.28 : 0.18
            view.layer.shadowRadius = isSelected ? 4 : 2
            view.layer.shadowOffset = CGSize(width: 0, height: 1)
            view.accessibilityLabel = item.title
        }

        private func refreshVisibleStyles(on mapView: MKMapView) {
            for annotation in annotations.values {
                guard let view = mapView.view(for: annotation) else { continue }
                configure(view, for: annotation.item)
            }
            for cluster in mapView.annotations.compactMap({ $0 as? MKClusterAnnotation }) {
                mapView.view(for: cluster)?.alpha = detailItemIDs.isEmpty ? 1 : 0.38
            }
        }

        private func updateSelectedCircle(
            selection: WiFiNetworkMapSelection?,
            on mapView: MKMapView
        ) {
            let items = annotations.values.map(\.item)
            let item = WiFiNetworkMapPresentation.selectedUncertaintyItem(
                selection: selection,
                items: items)

            if let item,
               let radius = item.uncertaintyRadiusMeters,
               let selectedCircle,
               selectedCircleTone == item.tone,
               abs(selectedCircle.coordinate.latitude - item.coordinate.latitude) < 0.0000001,
               abs(selectedCircle.coordinate.longitude - item.coordinate.longitude) < 0.0000001,
               abs(selectedCircle.radius - max(radius, 5)) < 0.1 {
                return
            }

            if let selectedCircle {
                mapView.removeOverlay(selectedCircle)
                self.selectedCircle = nil
            }

            guard let item, let radius = item.uncertaintyRadiusMeters else { return }

            selectedCircleTone = item.tone
            let circle = MKCircle(center: item.coordinate, radius: max(radius, 5))
            selectedCircle = circle
            mapView.addOverlay(circle, level: .aboveRoads)
        }

        private func fitAll(on mapView: MKMapView, animated: Bool) {
            let values = Array(annotations.values)
            guard !values.isEmpty else { return }

            if values.count == 1, let item = values.first?.item {
                let diameter = max((item.uncertaintyRadiusMeters ?? 100) * 3, 350)
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: item.coordinate,
                        latitudinalMeters: diameter,
                        longitudinalMeters: diameter),
                    animated: animated)
            } else {
                mapView.showAnnotations(values, animated: animated)
            }
        }

        private func fitDetail(on mapView: MKMapView, animated: Bool) {
            let values = detailItemIDs.compactMap { annotations[$0] }
            guard !values.isEmpty else { return }
            mapView.setUserTrackingMode(.none, animated: false)

            let distinct = Set(values.map {
                CoordinateKey(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)
            })
            if values.count == 1 || distinct.count == 1, let first = values.first {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: first.coordinate,
                        latitudinalMeters: 320,
                        longitudinalMeters: 320),
                    animated: animated)
            } else {
                mapView.showAnnotations(values, animated: animated)
            }
        }

        private func focus(itemID: String, on mapView: MKMapView, animated: Bool) {
            guard let annotation = annotations[itemID] else { return }
            mapView.setUserTrackingMode(.none, animated: false)
            let diameter = max((annotation.item.uncertaintyRadiusMeters ?? 80) * 4, 240)
            mapView.setRegion(
                MKCoordinateRegion(
                    center: annotation.coordinate,
                    latitudinalMeters: diameter,
                    longitudinalMeters: diameter),
                animated: animated)
        }
    }
}

private final class WiFiNetworkAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?
    var item: WiFiNetworkMapItem

    init(item: WiFiNetworkMapItem) {
        id = item.id
        coordinate = item.coordinate
        title = item.title
        subtitle = item.subtitle
        self.item = item
        super.init()
    }

    func update(with item: WiFiNetworkMapItem) {
        coordinate = item.coordinate
        title = item.title
        subtitle = item.subtitle
        self.item = item
    }
}

private struct CoordinateKey: Hashable {
    let latitude: Double
    let longitude: Double
}

private enum WiFiNetworkMarkerImage {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(
        tone: WiFiNetworkMapTone,
        symbol: String,
        selected: Bool
    ) -> UIImage {
        let key = "\(tone)-\(symbol)-\(selected)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let diameter: CGFloat = selected ? 38 : 30
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: diameter, height: diameter),
            format: format
        ).image { context in
            let bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            let inset: CGFloat = selected ? 2 : 1
            let circle = UIBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
            tone.uiColor.setFill()
            circle.fill()

            UIColor.white.withAlphaComponent(selected ? 0.95 : 0.75).setStroke()
            circle.lineWidth = selected ? 2.5 : 1
            circle.stroke()

            let configuration = UIImage.SymbolConfiguration(
                pointSize: selected ? 18 : 14,
                weight: .semibold)
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            else { return }
            let glyphRect = CGRect(
                x: (diameter - glyph.size.width) / 2,
                y: (diameter - glyph.size.height) / 2,
                width: glyph.size.width,
                height: glyph.size.height)
            glyph.draw(in: glyphRect)
            context.cgContext.setBlendMode(.normal)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

#if DEBUG
struct WiFiNetworkMapDensityQAView: View {
    private static let center = CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173)
    private static let sampleItems: [WiFiNetworkMapItem] = (0..<24).map { index in
        let closeGroup = index < 8
        let row = Double(index / 4)
        let column = Double(index % 4)
        let coordinate = closeGroup ?
            CLLocationCoordinate2D(
                latitude: center.latitude + row * 0.00001,
                longitude: center.longitude + column * 0.00001) :
            CLLocationCoordinate2D(
                latitude: center.latitude + (row - 2) * 0.00035,
                longitude: center.longitude + (column - 1.5) * 0.00045)
        let tone: WiFiNetworkMapTone = switch index % 3 {
        case 0: .green
        case 1: .orange
        default: .red
        }

        return WiFiNetworkMapItem(
            id: "estimate|QA-\(index)",
            sourceID: "QA-\(index)",
            kind: .estimate,
            title: "Network \(index + 1)",
            subtitle: "02:00:00:00:00:\(String(format: "%02X", index)) · ±\(20 + index * 3) m",
            coordinate: coordinate,
            tone: tone,
            uncertaintyRadiusMeters: Double(20 + index * 3))
    }

    @State private var selection: WiFiNetworkMapSelection?
    @State private var command = WiFiNetworkMapCommand.fitAll()

    init() {
        _selection = State(initialValue: .item(Self.sampleItems[12].id))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("24 networks · dense area")
                        .font(.headline)
                    WiFiNetworkClusterMap(
                        items: Self.sampleItems,
                        showsUserLocation: false,
                        selection: $selection,
                        command: command)
                        .frame(height: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Label(
                        "Numbered markers are clusters. Only Network 13 has a visible uncertainty ring.",
                        systemImage: "circle.dashed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { command = .fitAll() } label: {
                        Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Map density QA")
        }
        .tint(.orange)
    }
}
#endif
