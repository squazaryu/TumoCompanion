import Combine
import CoreLocation
import XCTest
@testable import UnleashedCompanion

final class DeviceServiceContractTests: XCTestCase {
    func testURLPolicyAcceptsOnlyExactHTTPSEndpoint() throws {
        let policy = HTTPSURLPolicy.deviceServices
        XCTAssertNoThrow(try policy.validate(URL(string: "https://api.github.com/zen")!))

        XCTAssertThrowsError(try policy.validate(URL(string: "http://api.github.com/zen")!)) {
            XCTAssertEqual($0 as? DeviceServiceError, .invalidURL)
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "https://127.0.0.1/zen")!)) {
            XCTAssertEqual($0 as? DeviceServiceError, .forbiddenHost)
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "https://api.github.com/repos")!)) {
            XCTAssertEqual($0 as? DeviceServiceError, .forbiddenHost)
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "https://api.github.com/zen?token=no")!)) {
            XCTAssertEqual($0 as? DeviceServiceError, .invalidURL)
        }
        XCTAssertThrowsError(try policy.validate(URL(string: "https://user:pass@api.github.com/zen")!)) {
            XCTAssertEqual($0 as? DeviceServiceError, .invalidURL)
        }
    }

    func testGPSPayloadIsBoundedAndContainsCoordinates() {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 55.7558, longitude: 37.6173),
            altitude: 156,
            horizontalAccuracy: 4.5,
            verticalAccuracy: 8,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let payload = DeviceServiceContract.gpsPayload(location)
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertLessThanOrEqual(payload.count, AppBridgeFrame.payloadMaxV2)
        XCTAssertTrue(text.contains("lat=55.755800"))
        XCTAssertTrue(text.contains("lon=37.617300"))
        XCTAssertTrue(text.contains("acc=4.5"))
    }

    func testHTTPSPayloadNeverExceedsFlipperReassemblyLimit() {
        let response = SafeHTTPSResponse(
            statusCode: 200,
            body: Data(repeating: 0x41, count: 2_000),
            truncated: true
        )
        let payload = DeviceServiceContract.httpsPayload(response)
        XCTAssertEqual(payload.count, DeviceServiceContract.maximumResponseBytes)
        XCTAssertTrue(String(decoding: payload.prefix(30), as: UTF8.self).contains("status=200"))
    }

    func testHTTPSRequestUsesGitHubCompatibleHeaders() throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/zen"))
        let request = SafeHTTPSRequest.make(for: url)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/vnd.github+json"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-GitHub-Api-Version"),
            SafeHTTPSRequest.githubAPIVersion
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TumoCompanion")
        XCTAssertNil(request.httpBody)
    }

    func testWebhookPolicyRejectsLocalAndCredentialURLs() throws {
        XCTAssertNoThrow(try WebhookURLPolicy.validate(URL(string: "https://example.com/tumoflip")!))
        XCTAssertThrowsError(try WebhookURLPolicy.validate(URL(string: "https://127.0.0.1/hook")!))
        XCTAssertThrowsError(try WebhookURLPolicy.validate(URL(string: "https://192.168.1.10/hook")!))
        XCTAssertThrowsError(try WebhookURLPolicy.validate(URL(string: "https://host.local/hook")!))
        XCTAssertThrowsError(try WebhookURLPolicy.validate(URL(string: "https://user:pass@example.com/hook")!))
        XCTAssertThrowsError(try WebhookURLPolicy.validate(URL(string: "https://example.com/hook?token=x")!))
    }

    func testNamedPayloadsStayBoundedAndWireSafe() {
        let place = DeviceServiceContract.placePayload(FieldPlaceResult(
            locality: String(repeating: "City;bad=value", count: 8),
            region: String(repeating: "Region", count: 12),
            country: String(repeating: "Country", count: 12)
        ))
        XCTAssertLessThanOrEqual(place.count, AppBridgeFrame.payloadMaxV2)
        let text = String(decoding: place, as: UTF8.self)
        XCTAssertFalse(text.contains("bad=value"))
        XCTAssertTrue(text.contains("place=City bad value"))
    }
}

@MainActor
final class DeviceServiceCoordinatorTests: XCTestCase {
    private final class FakeTransport: DeviceServiceTransport {
        let frames = PassthroughSubject<AppBridgeFrame, Never>()
        let states = CurrentValueSubject<FlipperConnectionState, Never>(.ready)
        var ready = true
        var supported = true
        var buddy = false
        var name = "Test Flipper"
        var responses: [(String, UInt32, Data, Bool)] = []

        var deviceServiceFrames: AnyPublisher<AppBridgeFrame, Never> {
            frames.eraseToAnyPublisher()
        }
        var deviceServiceConnectionStates: AnyPublisher<FlipperConnectionState, Never> {
            states.eraseToAnyPublisher()
        }
        var deviceServiceReady: Bool { ready }
        var deviceServicesSupported: Bool { supported }
        var deviceServiceBuddyMode: Bool { buddy }
        var deviceServiceConnectionState: FlipperConnectionState { states.value }
        var deviceServiceDeviceName: String { name }
        func ensureDeviceServiceSession() async throws {}

        func sendDeviceServiceResponse(
            command: String,
            requestID: UInt32,
            payload: Data,
            error: Bool
        ) -> Bool {
            responses.append((command, requestID, payload, error))
            return true
        }
    }

    private final class FakeLocation: DeviceLocationProviding {
        var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
        var backgroundAuthorized = false
        var backgroundAuthorizationRequests = 0
        var result = CLLocation(latitude: 55.75, longitude: 37.62)
        var requestCount = 0
        func requestBackgroundAuthorization() { backgroundAuthorizationRequests += 1 }
        func requestLocation() async throws -> CLLocation { requestCount += 1; return result }
        func cancel() {}
    }

    private final class FakeBackground: DeviceBackgroundExecutionProviding {
        var isInBackground = false
        var beginCount = 0
        var endCount = 0
        var expirationHandler: (() -> Void)?

        func begin(
            expirationHandler: @escaping @MainActor () -> Void
        ) -> UIBackgroundTaskIdentifier {
            beginCount += 1
            self.expirationHandler = { Task { @MainActor in expirationHandler() } }
            return UIBackgroundTaskIdentifier(rawValue: beginCount)
        }

        func end(_ identifier: UIBackgroundTaskIdentifier) {
            if identifier != .invalid { endCount += 1 }
        }
    }

    private final class FakeHTTPS: DeviceHTTPSProviding {
        var response = SafeHTTPSResponse(statusCode: 200, body: Data("ok".utf8), truncated: false)
        func get(_ url: URL) async throws -> SafeHTTPSResponse { response }
    }

    private final class FakeFieldNetwork: FieldServiceNetworkProviding {
        var weatherResult = FieldWeatherResult(
            temperatureCelsius: 21.5,
            apparentCelsius: 20.0,
            windKPH: 7.2,
            weatherCode: 1,
            observedAt: "2026-07-31T12:00"
        )
        var placeResult = FieldPlaceResult(locality: "Moscow", region: "Moscow", country: "Russia")
        var releaseResult = FieldReleaseResult(tag: "v1.0.3", name: "Tumoflip", publishedAt: "2026-07-30")
        var delivered: [UUID] = []

        func weather(at location: CLLocation) async throws -> FieldWeatherResult { weatherResult }
        func place(at location: CLLocation) async throws -> FieldPlaceResult { placeResult }
        func latestRelease() async throws -> FieldReleaseResult { releaseResult }
        func deliver(_ entry: FieldJournalEntry, to webhook: FieldWebhookConfiguration) async throws {
            delivered.append(entry.id)
        }
    }

    private final class FakeSecrets: FieldSecretStoring {
        var values: [String: String] = [:]
        func read(account: String) -> String? { values[account] }
        func write(_ value: String?, account: String) throws { values[account] = value }
    }

    private func request(command: String, id: UInt32, payload: Data) -> AppBridgeFrame {
        let encoded = AppBridgeFrame.encodeV2(
            appID: DeviceServiceContract.appID,
            command: command,
            payload: payload,
            requestID: id,
            flags: AppBridgeFrame.flagAckRequested
        )!
        return AppBridgeFrame(decoding: encoded[0])!
    }

    private func defaults() -> UserDefaults {
        let suite = "DeviceServiceCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func fieldStore(_ defaults: UserDefaults) -> FieldServicesStore {
        FieldServicesStore(defaults: defaults, secrets: FakeSecrets())
    }

    func testDisabledLocationFailsClosed() async {
        let transport = FakeTransport()
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: defaults()
        )
        XCTAssertFalse(coordinator.locationEnabled)

        transport.frames.send(request(command: "gps_once", id: 10, payload: Data("schema=1".utf8)))
        await Task.yield()

        XCTAssertEqual(transport.responses.count, 1)
        XCTAssertEqual(String(decoding: transport.responses[0].2, as: UTF8.self), "disabled")
        XCTAssertTrue(transport.responses[0].3)
    }

    func testLocationSuccessUsesCorrelatedResponse() async {
        let transport = FakeTransport()
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: defaults()
        )
        coordinator.locationEnabled = true

        transport.frames.send(request(command: "gps_once", id: 77, payload: Data("schema=1".utf8)))
        for _ in 0..<20 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(transport.responses.first?.0, "gps_once")
        XCTAssertEqual(transport.responses.first?.1, 77)
        XCTAssertEqual(transport.responses.first?.3, false)
        XCTAssertTrue(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self).contains("lat=55.750000"))
    }

    func testBuddyModeReturnsBusy() async {
        let transport = FakeTransport()
        transport.buddy = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: defaults()
        )
        coordinator.networkEnabled = true

        transport.frames.send(request(
            command: "https_get",
            id: 88,
            payload: Data("https://api.github.com/zen".utf8)
        ))
        await Task.yield()

        XCTAssertEqual(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self), "busy")
        XCTAssertEqual(transport.responses.first?.3, true)
    }

    func testBackgroundLocationRequiresAlwaysAuthorization() async {
        let transport = FakeTransport()
        let location = FakeLocation()
        let background = FakeBackground()
        background.isInBackground = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: location,
            https: FakeHTTPS(),
            background: background,
            defaults: defaults()
        )
        coordinator.locationEnabled = true

        transport.frames.send(request(command: "gps_once", id: 91, payload: Data("schema=1".utf8)))
        for _ in 0..<20 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self), "permission")
        XCTAssertEqual(transport.responses.first?.3, true)
        XCTAssertEqual(background.beginCount, 1)
        XCTAssertEqual(background.endCount, 1)
    }

    func testBackgroundLocationSucceedsWithAlwaysAuthorization() async {
        let transport = FakeTransport()
        let location = FakeLocation()
        location.authorizationStatus = .authorizedAlways
        location.backgroundAuthorized = true
        let background = FakeBackground()
        background.isInBackground = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: location,
            https: FakeHTTPS(),
            background: background,
            defaults: defaults()
        )
        coordinator.locationEnabled = true

        transport.frames.send(request(command: "gps_once", id: 93, payload: Data("schema=1".utf8)))
        for _ in 0..<20 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(transport.responses.first?.3, false)
        XCTAssertTrue(
            String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self)
                .contains("lat=55.750000")
        )
        XCTAssertEqual(background.beginCount, 1)
        XCTAssertEqual(background.endCount, 1)
    }

    func testForegroundOnlyStateRequestsBackgroundPermission() {
        let location = FakeLocation()
        let coordinator = DeviceServiceCoordinator(
            transport: FakeTransport(),
            location: location,
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: defaults()
        )
        coordinator.locationEnabled = true

        XCTAssertEqual(coordinator.locationState, .foregroundOnly)
        coordinator.prepareBackgroundLocationAuthorization()
        XCTAssertEqual(location.backgroundAuthorizationRequests, 1)
    }

    func testBackgroundHTTPSGetsAndReleasesExecutionTime() async {
        let transport = FakeTransport()
        let background = FakeBackground()
        background.isInBackground = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: background,
            defaults: defaults()
        )
        coordinator.networkEnabled = true

        transport.frames.send(request(
            command: "https_get",
            id: 92,
            payload: Data("https://api.github.com/zen".utf8)
        ))
        for _ in 0..<20 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(transport.responses.first?.3, false)
        XCTAssertEqual(background.beginCount, 1)
        XCTAssertEqual(background.endCount, 1)
    }

    func testWeatherUsesLocationAndNamedProvider() async {
        let transport = FakeTransport()
        let location = FakeLocation()
        let suite = defaults()
        let fields = fieldStore(suite)
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: location,
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: suite,
            fieldServices: fields,
            fieldNetwork: FakeFieldNetwork()
        )
        coordinator.locationEnabled = true
        coordinator.networkEnabled = true

        transport.frames.send(request(
            command: DeviceServiceContract.weatherCommand,
            id: 101,
            payload: Data("schema=1".utf8)
        ))
        for _ in 0..<30 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(location.requestCount, 1)
        XCTAssertEqual(transport.responses.first?.3, false)
        XCTAssertTrue(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self)
            .contains("temp=21.5"))
    }

    func testNamedServiceRejectsMissingSchema() async {
        let transport = FakeTransport()
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: defaults(),
            fieldNetwork: FakeFieldNetwork()
        )
        coordinator.locationEnabled = true
        coordinator.networkEnabled = true

        transport.frames.send(request(
            command: DeviceServiceContract.weatherCommand,
            id: 103,
            payload: Data("purpose=service".utf8)
        ))
        await Task.yield()

        XCTAssertEqual(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self), "invalid_payload")
        XCTAssertEqual(transport.responses.first?.3, true)
    }

    func testWebhookTokenRejectsOversizedValue() {
        let fields = fieldStore(defaults())
        XCTAssertThrowsError(try fields.saveWebhookToken(String(repeating: "x", count: 513))) {
            XCTAssertEqual($0 as? DeviceServiceError, .invalidPayload)
        }
        XCTAssertThrowsError(try fields.saveWebhookToken("secret\n")) {
            XCTAssertEqual($0 as? DeviceServiceError, .invalidPayload)
        }
    }

    func testJournalStoresLocationAndReturnsAcknowledgement() async {
        let transport = FakeTransport()
        let suite = defaults()
        let fields = fieldStore(suite)
        fields.journalEnabled = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: FakeLocation(),
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: suite,
            fieldServices: fields,
            fieldNetwork: FakeFieldNetwork()
        )
        coordinator.locationEnabled = true

        transport.frames.send(request(
            command: DeviceServiceContract.journalCommand,
            id: 102,
            payload: Data("schema=1;kind=field;note=Gate check".utf8)
        ))
        for _ in 0..<30 where transport.responses.isEmpty { await Task.yield() }

        XCTAssertEqual(fields.journalEntries.count, 1)
        XCTAssertEqual(fields.journalEntries.first?.note, "Gate check")
        XCTAssertEqual(fields.journalEntries.first?.location.deviceName, "Test Flipper")
        XCTAssertTrue(String(decoding: transport.responses.first?.2 ?? Data(), as: UTF8.self)
            .contains("stored=1"))
    }

    func testConnectionCaptureStoresOnlyOneOptInLocation() async {
        let transport = FakeTransport()
        transport.states.value = .disconnected
        let location = FakeLocation()
        let suite = defaults()
        let fields = fieldStore(suite)
        fields.rememberLastLocation = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: location,
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: suite,
            fieldServices: fields,
            fieldNetwork: FakeFieldNetwork()
        )
        coordinator.locationEnabled = true

        transport.states.send(.ready)
        for _ in 0..<30 where fields.lastLocation == nil { await Task.yield() }

        XCTAssertEqual(fields.lastLocation?.reason, .connection)
        XCTAssertEqual(location.requestCount, 1)
    }

    func testDisconnectCaptureKeepsLastReadyDeviceName() async {
        let transport = FakeTransport()
        transport.states.value = .disconnected
        transport.name = "Field Flipper"
        let location = FakeLocation()
        let suite = defaults()
        let fields = fieldStore(suite)
        fields.rememberLastLocation = true
        let coordinator = DeviceServiceCoordinator(
            transport: transport,
            location: location,
            https: FakeHTTPS(),
            background: FakeBackground(),
            defaults: suite,
            fieldServices: fields,
            fieldNetwork: FakeFieldNetwork()
        )
        coordinator.locationEnabled = true

        transport.states.send(.ready)
        for _ in 0..<30 where fields.lastLocation?.reason != .connection { await Task.yield() }
        transport.name = "Flipper Zero"
        transport.states.send(.disconnected)
        for _ in 0..<30 where fields.lastLocation?.reason != .disconnection { await Task.yield() }

        XCTAssertEqual(fields.lastLocation?.reason, .disconnection)
        XCTAssertEqual(fields.lastLocation?.deviceName, "Field Flipper")
    }
}
