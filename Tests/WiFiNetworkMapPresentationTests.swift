import CoreLocation
import MapKit
import SwiftUI
import XCTest
@testable import UnleashedCompanion

final class WiFiNetworkMapPresentationTests: XCTestCase {
    func testOnlySelectedEstimateProducesUncertaintyOverlay() throws {
        let estimate = makeEstimate()
        let item = WiFiNetworkMapItem.estimate(estimate)

        let selected = WiFiNetworkMapPresentation.selectedUncertaintyItem(
            selection: .item(item.id),
            items: [item])

        XCTAssertEqual(selected, item)
        XCTAssertEqual(selected?.uncertaintyRadiusMeters, 42)
    }

    func testClusterDoesNotProduceCombinedUncertaintyOverlay() {
        let item = WiFiNetworkMapItem.estimate(makeEstimate())

        let selected = WiFiNetworkMapPresentation.selectedUncertaintyItem(
            selection: .cluster([item.id]),
            items: [item])

        XCTAssertNil(selected)
    }

    func testRawObservationDoesNotProduceUncertaintyOverlay() {
        let point = WiFiMapperPoint(
            id: "row-1",
            sourceName: "survey.geojson",
            ssid: "Cafe",
            bssid: "AA:BB:CC:DD:EE:FF",
            auth: "WPA2",
            channel: 6,
            rssi: -58,
            bestRSSI: nil,
            lastRSSI: nil,
            averageRSSI: nil,
            samples: 1,
            tickMS: nil,
            firstTickMS: nil,
            lastTickMS: nil,
            latitude: 55.7558,
            longitude: 37.6173,
            altitude: nil,
            accuracy: 12)
        let item = WiFiNetworkMapItem.observation(point)

        let selected = WiFiNetworkMapPresentation.selectedUncertaintyItem(
            selection: .item(item.id),
            items: [item])

        XCTAssertNil(selected)
    }

    func testEstimateAndObservationIdentifiersCannotCollide() {
        let estimateItem = WiFiNetworkMapItem.estimate(makeEstimate())
        let point = WiFiMapperPoint(
            id: estimateItem.sourceID,
            sourceName: "survey.geojson",
            ssid: "Cafe",
            bssid: estimateItem.sourceID,
            auth: "WPA2",
            channel: 6,
            rssi: -58,
            bestRSSI: nil,
            lastRSSI: nil,
            averageRSSI: nil,
            samples: 1,
            tickMS: nil,
            firstTickMS: nil,
            lastTickMS: nil,
            latitude: 55.7558,
            longitude: 37.6173,
            altitude: nil,
            accuracy: 12)

        XCTAssertNotEqual(estimateItem.id, WiFiNetworkMapItem.observation(point).id)
    }

    @MainActor
    func testEstimateMarkerParticipatesInMapKitClustering() throws {
        let item = WiFiNetworkMapItem.estimate(makeEstimate())
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: .constant(nil))
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        mapView.delegate = coordinator
        registerMapViews(on: mapView)

        coordinator.update(items: [item], on: mapView)

        let annotation = try XCTUnwrap(mapView.annotations.first { !($0 is MKUserLocation) })
        let view = try XCTUnwrap(coordinator.mapView(mapView, viewFor: annotation))
        XCTAssertEqual(view.clusteringIdentifier, "tumoflip.wifi.estimate")
        XCTAssertEqual(view.displayPriority, .defaultHigh)
    }

    @MainActor
    func testDetailMemberLeavesClusterWithoutChangingItsCoordinate() throws {
        let item = WiFiNetworkMapItem.estimate(makeEstimate())
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: .constant(nil))
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        mapView.delegate = coordinator
        registerMapViews(on: mapView)

        coordinator.update(items: [item], detailItemIDs: [item.id], on: mapView)

        let annotation = try XCTUnwrap(mapView.annotations.first { !($0 is MKUserLocation) })
        let view = try XCTUnwrap(coordinator.mapView(mapView, viewFor: annotation))
        XCTAssertNil(view.clusteringIdentifier)
        XCTAssertEqual(view.displayPriority, .required)
        XCTAssertEqual(annotation.coordinate.latitude, item.coordinate.latitude, accuracy: 0.0000001)
        XCTAssertEqual(annotation.coordinate.longitude, item.coordinate.longitude, accuracy: 0.0000001)
    }

    @MainActor
    func testFocusCommandCentersTheRealEstimate() {
        let item = WiFiNetworkMapItem.estimate(makeEstimate())
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: .constant(.item(item.id)))
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        registerMapViews(on: mapView)
        coordinator.update(items: [item], detailItemIDs: [item.id], on: mapView)

        coordinator.apply(command: .focus(item.id), on: mapView)

        XCTAssertEqual(mapView.region.center.latitude, item.coordinate.latitude, accuracy: 0.0001)
        XCTAssertEqual(mapView.region.center.longitude, item.coordinate.longitude, accuracy: 0.0001)
    }

    @MainActor
    func testCoordinatorKeepsOnlySelectedEstimateCircle() {
        let first = WiFiNetworkMapItem.estimate(makeEstimate())
        let second = WiFiNetworkMapItem.estimate(WiFiMapperAPEstimate(
            id: "11:22:33:44:55:66",
            ssid: "Office",
            bssid: "11:22:33:44:55:66",
            channel: 11,
            coordinate: CLLocationCoordinate2D(latitude: 55.7560, longitude: 37.6176),
            observationCount: 5,
            strongestRSSI: -52,
            averageRSSI: -61,
            radiusMeters: 65,
            maxSpreadMeters: 24,
            averageAccuracyMeters: 18,
            confidence: .medium))
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: .constant(nil))
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        registerMapViews(on: mapView)

        coordinator.update(items: [first, second], on: mapView)
        XCTAssertTrue(mapView.overlays.isEmpty)

        coordinator.apply(selection: .item(first.id), on: mapView)
        XCTAssertEqual(mapView.overlays.count, 1)
        XCTAssertEqual((mapView.overlays.first as? MKCircle)?.radius, 42)

        coordinator.apply(selection: .cluster([first.id, second.id]), on: mapView)
        XCTAssertTrue(mapView.overlays.isEmpty)
    }

    @MainActor
    func testCoordinatorClearsSelectionWhenMarkerIsDeselected() throws {
        let item = WiFiNetworkMapItem.estimate(makeEstimate())
        var selection: WiFiNetworkMapSelection? = .item(item.id)
        let binding = Binding<WiFiNetworkMapSelection?>(
            get: { selection },
            set: { selection = $0 })
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: binding)
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        mapView.delegate = coordinator
        registerMapViews(on: mapView)
        coordinator.update(items: [item], on: mapView)

        let annotation = try XCTUnwrap(
            mapView.annotations.first { !($0 is MKUserLocation) })
        let view = try XCTUnwrap(coordinator.mapView(mapView, viewFor: annotation))
        coordinator.mapView(mapView, didDeselect: view)

        XCTAssertNil(selection)
        XCTAssertTrue(mapView.overlays.isEmpty)
    }

    @MainActor
    func testClusterMarkerShowsMemberCount() throws {
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: .constant(nil))
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        registerMapViews(on: mapView)
        let members = (0..<12).map { index -> MKPointAnnotation in
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(
                latitude: 55.7558 + Double(index) * 0.00001,
                longitude: 37.6173)
            return annotation
        }
        let cluster = MKClusterAnnotation(memberAnnotations: members)

        let view = try XCTUnwrap(
            coordinator.mapView(mapView, viewFor: cluster) as? MKMarkerAnnotationView)

        XCTAssertEqual(view.glyphText, "12")
        XCTAssertNil(view.clusteringIdentifier)
    }

    @MainActor
    func testExpandingClusterKeepsSelectionWhenMapKitRemovesClusterView() throws {
        let first = WiFiNetworkMapItem.estimate(makeEstimate())
        let second = WiFiNetworkMapItem.estimate(WiFiMapperAPEstimate(
            id: "11:22:33:44:55:66",
            ssid: "Office",
            bssid: "11:22:33:44:55:66",
            channel: 11,
            coordinate: CLLocationCoordinate2D(latitude: 55.7559, longitude: 37.6174),
            observationCount: 5,
            strongestRSSI: -52,
            averageRSSI: -61,
            radiusMeters: 65,
            maxSpreadMeters: 24,
            averageAccuracyMeters: 18,
            confidence: .medium))
        let ids = [first.id, second.id]
        var selection: WiFiNetworkMapSelection? = .cluster(ids)
        let binding = Binding<WiFiNetworkMapSelection?>(
            get: { selection },
            set: { selection = $0 })
        let coordinator = WiFiNetworkClusterMap.Coordinator(selection: binding)
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        mapView.delegate = coordinator
        registerMapViews(on: mapView)
        coordinator.update(items: [first, second], detailItemIDs: ids, on: mapView)

        let members = mapView.annotations.filter { !($0 is MKUserLocation) }
        let removedCluster = MKClusterAnnotation(memberAnnotations: members)
        let view = try XCTUnwrap(coordinator.mapView(mapView, viewFor: removedCluster))
        coordinator.mapView(mapView, didDeselect: view)

        XCTAssertEqual(selection, .cluster(ids))
    }

    @MainActor
    private func registerMapViews(on mapView: MKMapView) {
        mapView.register(
            MKAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: WiFiNetworkClusterMap.Coordinator.networkReuseIdentifier)
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: WiFiNetworkClusterMap.Coordinator.clusterReuseIdentifier)
    }

    private func makeEstimate() -> WiFiMapperAPEstimate {
        WiFiMapperAPEstimate(
            id: "AA:BB:CC:DD:EE:FF",
            ssid: "Cafe",
            bssid: "AA:BB:CC:DD:EE:FF",
            channel: 6,
            coordinate: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
            observationCount: 7,
            strongestRSSI: -45,
            averageRSSI: -54,
            radiusMeters: 42,
            maxSpreadMeters: 30,
            averageAccuracyMeters: 12,
            confidence: .medium)
    }
}
