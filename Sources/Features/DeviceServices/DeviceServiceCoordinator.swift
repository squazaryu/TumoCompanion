import Combine
import CoreLocation
import Foundation
import UIKit

enum DeviceServiceKind: Equatable {
    case location
    case network
    case journal
}

enum DeviceServiceState: Equatable {
    case off
    case unavailable
    case available
    case inUse
    case denied
    case foregroundOnly

    var label: String {
        switch self {
        case .off: return "Off"
        case .unavailable: return "Unavailable"
        case .available: return "Available"
        case .inUse: return "In use"
        case .denied: return "Permission denied"
        case .foregroundOnly: return "Foreground only"
        }
    }
}

enum DeviceServiceError: Error, Equatable {
    case disabled
    case unsupported
    case busy
    case permission
    case invalidURL
    case forbiddenHost
    case timeout
    case responseTooLarge
    case network
    case invalidPayload
    case notConfigured

    var token: String {
        switch self {
        case .disabled: return "disabled"
        case .unsupported: return "unsupported"
        case .busy: return "busy"
        case .permission: return "permission"
        case .invalidURL: return "invalid_url"
        case .forbiddenHost: return "forbidden_host"
        case .timeout: return "timeout"
        case .responseTooLarge: return "too_large"
        case .network: return "network"
        case .invalidPayload: return "invalid_payload"
        case .notConfigured: return "not_configured"
        }
    }
}

protocol DeviceServiceTransport: AnyObject {
    var deviceServiceFrames: AnyPublisher<AppBridgeFrame, Never> { get }
    var deviceServiceConnectionStates: AnyPublisher<FlipperConnectionState, Never> { get }
    var deviceServiceReady: Bool { get }
    var deviceServicesSupported: Bool { get }
    var deviceServiceBuddyMode: Bool { get }
    var deviceServiceConnectionState: FlipperConnectionState { get }
    var deviceServiceDeviceName: String { get }
    func ensureDeviceServiceSession() async throws

    @discardableResult
    func sendDeviceServiceResponse(
        command: String,
        requestID: UInt32,
        payload: Data,
        error: Bool
    ) -> Bool
}

extension FlipperBLE: DeviceServiceTransport {
    var deviceServiceFrames: AnyPublisher<AppBridgeFrame, Never> {
        appBridgeIn.eraseToAnyPublisher()
    }

    var deviceServiceConnectionStates: AnyPublisher<FlipperConnectionState, Never> {
        $state.eraseToAnyPublisher()
    }

    var deviceServiceReady: Bool { state == .ready && appBridgeV2 }
    var deviceServicesSupported: Bool {
        let capabilities = RuntimeCapabilities(appBridgeCapabilities)
        return capabilities.supportsGPS && capabilities.supportsNetwork
    }
    var deviceServiceBuddyMode: Bool { buddyMode }
    var deviceServiceConnectionState: FlipperConnectionState { state }
    var deviceServiceDeviceName: String { connectedName ?? "Flipper Zero" }

    func ensureDeviceServiceSession() async throws {
        let response = try await appBridgeRequest(
            appID: "runtime",
            command: "hello",
            payload: Data("owner=iphone".utf8),
            timeout: 3
        )
        let fields = String(decoding: response, as: UTF8.self)
            .split(separator: ";")
            .reduce(into: [String: String]()) { result, pair in
                let values = pair.split(separator: "=", maxSplits: 1)
                if values.count == 2 {
                    result[String(values[0])] = String(values[1])
                }
            }
        guard let session = fields["sid"], session != "00000000", !session.isEmpty else {
            throw DeviceServiceError.unsupported
        }
    }

    @discardableResult
    func sendDeviceServiceResponse(
        command: String,
        requestID: UInt32,
        payload: Data,
        error: Bool
    ) -> Bool {
        sendAppBridgeResponse(
            appID: DeviceServiceContract.appID,
            command: command,
            requestID: requestID,
            payload: payload,
            error: error
        )
    }
}

@MainActor
protocol DeviceLocationProviding: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var backgroundAuthorized: Bool { get }
    func requestBackgroundAuthorization()
    func requestLocation() async throws -> CLLocation
    func cancel()
}

@MainActor
protocol DeviceBackgroundExecutionProviding: AnyObject {
    var isInBackground: Bool { get }
    func begin(expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

protocol DeviceHTTPSProviding: AnyObject {
    func get(_ url: URL) async throws -> SafeHTTPSResponse
}

enum DeviceServiceContract {
    static let appID = "device_services"
    static let gpsCommand = "gps_once"
    static let httpsCommand = "https_get"
    static let weatherCommand = "weather_now"
    static let placeCommand = "place_once"
    static let releaseCommand = "release_latest"
    static let journalCommand = "journal_append"
    static let maximumRequestBytes = 160
    static let maximumResponseBytes = 512

    static func gpsPayload(_ location: CLLocation) -> Data {
        let timestamp = Int(location.timestamp.timeIntervalSince1970)
        let text = String(
            format: "schema=1;lat=%.6f;lon=%.6f;alt=%.1f;acc=%.1f;ts=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.altitude,
            location.horizontalAccuracy,
            timestamp
        )
        return Data(text.utf8)
    }

    static func httpsPayload(_ response: SafeHTTPSResponse) -> Data {
        let header = Data("status=\(response.statusCode);truncated=\(response.truncated ? 1 : 0)\n".utf8)
        let available = max(0, maximumResponseBytes - header.count)
        var payload = header
        payload.append(response.body.prefix(available))
        return payload
    }

    static func gpsReason(_ payload: Data) -> FieldLocationReason? {
        let fields = fields(payload)
        guard fields["schema"] == "1" else { return nil }
        switch fields["purpose"] {
        case nil, "manual": return .explicitRequest
        case "survey": return .survey
        case "sidecar": return .sidecar
        case "service": return .service
        case "journal": return .journal
        default: return nil
        }
    }

    static func journalRequest(_ payload: Data) -> (kind: String, note: String)? {
        let values = fields(payload)
        guard values["schema"] == "1" else { return nil }
        return (values["kind"] ?? "field", values["note"] ?? "Field event")
    }

    static func namedRequestIsValid(_ payload: Data) -> Bool {
        fields(payload)["schema"] == "1"
    }

    static func weatherPayload(_ result: FieldWeatherResult) -> Data {
        Data(String(
            format: "schema=1;temp=%.1f;feels=%.1f;wind=%.1f;code=%d;at=%@",
            locale: Locale(identifier: "en_US_POSIX"),
            result.temperatureCelsius,
            result.apparentCelsius,
            result.windKPH,
            result.weatherCode,
            safeWire(result.observedAt, maximum: 24)
        ).utf8)
    }

    static func placePayload(_ result: FieldPlaceResult) -> Data {
        Data("schema=1;place=\(safeWire(result.locality, maximum: 40));region=\(safeWire(result.region, maximum: 40));country=\(safeWire(result.country, maximum: 40))".utf8)
    }

    static func releasePayload(_ result: FieldReleaseResult) -> Data {
        Data("schema=1;tag=\(safeWire(result.tag, maximum: 32));name=\(safeWire(result.name, maximum: 48));at=\(safeWire(result.publishedAt, maximum: 32))".utf8)
    }

    static func journalPayload(_ entry: FieldJournalEntry) -> Data {
        let sent = entry.delivery == .sent ? 1 : 0
        return Data("schema=1;stored=1;sent=\(sent);delivery=\(entry.delivery.rawValue);id=\(entry.id.uuidString.prefix(8))".utf8)
    }

    private static func fields(_ payload: Data) -> [String: String] {
        guard let text = String(data: payload, encoding: .utf8) else { return [:] }
        return text.split(separator: ";").reduce(into: [:]) { result, component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return }
            result[String(pair[0])] = String(pair[1])
        }
    }

    private static func safeWire(_ input: String, maximum: Int) -> String {
        let filtered = input.unicodeScalars.map { scalar -> Character in
            guard scalar.isASCII, scalar.value >= 0x20, scalar.value != 0x7F,
                  scalar != ";", scalar != "=" else { return " " }
            return Character(scalar)
        }
        let normalized = String(filtered)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(normalized.prefix(maximum))
    }
}

@MainActor
final class DeviceServiceCoordinator: ObservableObject {
    @Published var locationEnabled: Bool {
        didSet {
            defaults.set(locationEnabled, forKey: Self.locationEnabledKey)
            if !locationEnabled {
                cancelActiveRequest()
                cancelConnectionCapture()
            }
        }
    }
    @Published var networkEnabled: Bool {
        didSet {
            defaults.set(networkEnabled, forKey: Self.networkEnabledKey)
            if !networkEnabled, activeService == .network { cancelActiveRequest() }
        }
    }
    @Published private(set) var activeService: DeviceServiceKind?
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: String?

    private static let locationEnabledKey = "deviceServices.locationEnabled.v1"
    private static let networkEnabledKey = "deviceServices.networkEnabled.v1"

    private let transport: DeviceServiceTransport
    private let location: DeviceLocationProviding
    private let https: DeviceHTTPSProviding
    private let background: DeviceBackgroundExecutionProviding
    private let fieldServices: FieldServicesStore
    private let fieldNetwork: FieldServiceNetworkProviding
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UInt32?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var connectionCaptureTask: Task<Void, Never>?
    private var connectionBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var previousConnectionState: FlipperConnectionState
    private var lastReadyDeviceName: String

    convenience init() {
        self.init(
            transport: FlipperBLE.shared,
            location: SystemDeviceLocationProvider(),
            https: SafeHTTPSClient(),
            background: SystemDeviceBackgroundExecutionProvider(),
            defaults: .standard,
            fieldServices: .shared,
            fieldNetwork: FieldServiceNetworkClient()
        )
    }

    init(
        transport: DeviceServiceTransport,
        location: DeviceLocationProviding,
        https: DeviceHTTPSProviding,
        background: DeviceBackgroundExecutionProviding,
        defaults: UserDefaults,
        fieldServices: FieldServicesStore? = nil,
        fieldNetwork: FieldServiceNetworkProviding = FieldServiceNetworkClient()
    ) {
        self.transport = transport
        self.location = location
        self.https = https
        self.background = background
        self.defaults = defaults
        self.fieldServices = fieldServices ?? .shared
        self.fieldNetwork = fieldNetwork
        previousConnectionState = transport.deviceServiceConnectionState
        lastReadyDeviceName = transport.deviceServiceDeviceName
        locationEnabled = defaults.bool(forKey: Self.locationEnabledKey)
        networkEnabled = defaults.bool(forKey: Self.networkEnabledKey)

        transport.deviceServiceFrames
            .sink { [weak self] frame in
                Task { @MainActor in self?.receive(frame) }
            }
            .store(in: &cancellables)

        transport.deviceServiceConnectionStates
            .sink { [weak self] state in
                Task { @MainActor in self?.handleConnectionState(state) }
            }
            .store(in: &cancellables)
    }

    var locationState: DeviceServiceState {
        guard locationEnabled else { return .off }
        if activeService == .location { return .inUse }
        switch location.authorizationStatus {
        case .denied, .restricted: return .denied
        case .authorizedWhenInUse: return .foregroundOnly
        default:
            return transport.deviceServiceReady && transport.deviceServicesSupported
                ? .available : .unavailable
        }
    }

    var networkState: DeviceServiceState {
        guard networkEnabled else { return .off }
        if activeService == .network { return .inUse }
        return transport.deviceServiceReady && transport.deviceServicesSupported
            ? .available : .unavailable
    }

    func prepareBackgroundLocationAuthorization() {
        guard locationEnabled else { return }
        location.requestBackgroundAuthorization()
    }

    private func receive(_ frame: AppBridgeFrame) {
        guard frame.version == 2,
              frame.appID == DeviceServiceContract.appID,
              !frame.isResponse,
              frame.requestID != 0 else { return }

        guard frame.chunkCount == 1, frame.chunkIndex == 0,
              frame.payload.count <= DeviceServiceContract.maximumRequestBytes else {
            respondError(.unsupported, command: frame.command, requestID: frame.requestID)
            return
        }
        guard transport.deviceServiceReady, transport.deviceServicesSupported else {
            respondError(.unsupported, command: frame.command, requestID: frame.requestID)
            return
        }
        guard !transport.deviceServiceBuddyMode, activeRequestID == nil else {
            respondError(.busy, command: frame.command, requestID: frame.requestID)
            return
        }

        switch frame.command {
        case DeviceServiceContract.gpsCommand:
            guard locationEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard let reason = DeviceServiceContract.gpsReason(frame.payload) else {
                respondError(.invalidPayload, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .location) { [weak self, transport] in
                guard let self else { throw CancellationError() }
                try await transport.ensureDeviceServiceSession()
                let fix = try await self.requestLocation(reason: reason)
                return DeviceServiceContract.gpsPayload(fix)
            }

        case DeviceServiceContract.httpsCommand:
            guard networkEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard let text = String(data: frame.payload, encoding: .utf8),
                  let url = URL(string: text) else {
                respondError(.invalidURL, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .network) { [transport, https] in
                try await transport.ensureDeviceServiceSession()
                return DeviceServiceContract.httpsPayload(try await https.get(url))
            }

        case DeviceServiceContract.weatherCommand:
            guard locationEnabled, networkEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard DeviceServiceContract.namedRequestIsValid(frame.payload) else {
                respondError(.invalidPayload, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .network) { [weak self, transport, fieldNetwork] in
                guard let self else { throw CancellationError() }
                try await transport.ensureDeviceServiceSession()
                let fix = try await self.requestLocation(reason: .service)
                return DeviceServiceContract.weatherPayload(try await fieldNetwork.weather(at: fix))
            }

        case DeviceServiceContract.placeCommand:
            guard locationEnabled, networkEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard DeviceServiceContract.namedRequestIsValid(frame.payload) else {
                respondError(.invalidPayload, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .network) { [weak self, transport, fieldNetwork] in
                guard let self else { throw CancellationError() }
                try await transport.ensureDeviceServiceSession()
                let fix = try await self.requestLocation(reason: .service)
                return DeviceServiceContract.placePayload(try await fieldNetwork.place(at: fix))
            }

        case DeviceServiceContract.releaseCommand:
            guard networkEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard DeviceServiceContract.namedRequestIsValid(frame.payload) else {
                respondError(.invalidPayload, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .network) { [transport, fieldNetwork] in
                try await transport.ensureDeviceServiceSession()
                return DeviceServiceContract.releasePayload(try await fieldNetwork.latestRelease())
            }

        case DeviceServiceContract.journalCommand:
            guard locationEnabled, fieldServices.journalEnabled else {
                respondError(.disabled, command: frame.command, requestID: frame.requestID)
                return
            }
            guard let journal = DeviceServiceContract.journalRequest(frame.payload) else {
                respondError(.invalidPayload, command: frame.command, requestID: frame.requestID)
                return
            }
            start(frame, kind: .journal) { [weak self, transport, fieldServices, fieldNetwork] in
                guard let self else { throw CancellationError() }
                try await transport.ensureDeviceServiceSession()
                let fix = try await self.requestLocation(reason: .journal)
                var entry = try fieldServices.appendJournal(
                    kind: journal.kind,
                    note: journal.note,
                    location: fix,
                    deviceName: transport.deviceServiceDeviceName
                )
                if fieldServices.webhookEnabled {
                    do {
                        guard self.networkEnabled else { throw DeviceServiceError.disabled }
                        let configuration = try fieldServices.webhookConfiguration()
                        try await fieldNetwork.deliver(entry, to: configuration)
                        fieldServices.markDelivery(id: entry.id, as: .sent)
                        entry.delivery = .sent
                    } catch {
                        fieldServices.markDelivery(id: entry.id, as: .failed)
                        entry.delivery = .failed
                    }
                }
                return DeviceServiceContract.journalPayload(entry)
            }

        default:
            respondError(.unsupported, command: frame.command, requestID: frame.requestID)
        }
    }

    private func start(
        _ frame: AppBridgeFrame,
        kind: DeviceServiceKind,
        operation: @escaping @MainActor () async throws -> Data
    ) {
        cancelConnectionCapture()
        activeRequestID = frame.requestID
        activeService = kind
        lastError = nil
        lastResult = nil
        backgroundTaskID = background.begin { [weak self] in
            self?.cancelActiveRequest()
        }
        requestTask = Task { [weak self] in
            do {
                let payload = try await operation()
                guard !Task.isCancelled else { return }
                self?.finish(
                    command: frame.command,
                    requestID: frame.requestID,
                    payload: payload,
                    error: nil
                )
            } catch is CancellationError {
                return
            } catch let error as DeviceServiceError {
                self?.finish(
                    command: frame.command,
                    requestID: frame.requestID,
                    payload: Data(),
                    error: error
                )
            } catch {
                self?.finish(
                    command: frame.command,
                    requestID: frame.requestID,
                    payload: Data(),
                    error: .network
                )
            }
        }
    }

    private func finish(
        command: String,
        requestID: UInt32,
        payload: Data,
        error: DeviceServiceError?
    ) {
        guard activeRequestID == requestID else { return }
        if let error {
            lastError = error.token
            respondError(error, command: command, requestID: requestID)
        } else {
            lastResult = String(decoding: payload.prefix(160), as: UTF8.self)
            _ = transport.sendDeviceServiceResponse(
                command: command,
                requestID: requestID,
                payload: payload,
                error: false
            )
        }
        clearActiveRequest()
    }

    private func respondError(
        _ error: DeviceServiceError,
        command: String,
        requestID: UInt32
    ) {
        _ = transport.sendDeviceServiceResponse(
            command: command,
            requestID: requestID,
            payload: Data(error.token.utf8),
            error: true
        )
    }

    private func cancelActiveRequest() {
        requestTask?.cancel()
        location.cancel()
        clearActiveRequest()
    }

    private func clearActiveRequest() {
        requestTask = nil
        activeRequestID = nil
        activeService = nil
        if backgroundTaskID != .invalid {
            background.end(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func requestLocation(reason: FieldLocationReason) async throws -> CLLocation {
        guard !background.isInBackground || location.backgroundAuthorized else {
            throw DeviceServiceError.permission
        }
        let fix = try await location.requestLocation()
        if reason != .journal {
            fieldServices.record(
                fix,
                reason: reason,
                deviceName: transport.deviceServiceDeviceName
            )
        }
        return fix
    }

    private func handleConnectionState(_ state: FlipperConnectionState) {
        let previous = previousConnectionState
        previousConnectionState = state

        if state != .ready { cancelActiveRequest() }
        if state == .ready, previous != .ready {
            lastReadyDeviceName = transport.deviceServiceDeviceName
            captureConnectionLocation(reason: .connection, deviceName: lastReadyDeviceName)
        } else if previous == .ready, state != .ready {
            captureConnectionLocation(reason: .disconnection, deviceName: lastReadyDeviceName)
        }
    }

    private func captureConnectionLocation(
        reason: FieldLocationReason,
        deviceName: String
    ) {
        guard fieldServices.rememberLastLocation, locationEnabled else { return }
        cancelConnectionCapture()
        connectionBackgroundTaskID = background.begin { [weak self] in
            self?.cancelConnectionCapture()
        }
        connectionCaptureTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishConnectionCapture() }
            do {
                guard !self.background.isInBackground || self.location.backgroundAuthorized else {
                    return
                }
                let fix = try await self.location.requestLocation()
                guard !Task.isCancelled else { return }
                self.fieldServices.record(fix, reason: reason, deviceName: deviceName)
            } catch {
                return
            }
        }
    }

    private func cancelConnectionCapture() {
        guard connectionCaptureTask != nil || connectionBackgroundTaskID != .invalid else { return }
        connectionCaptureTask?.cancel()
        location.cancel()
        finishConnectionCapture()
    }

    private func finishConnectionCapture() {
        connectionCaptureTask = nil
        if connectionBackgroundTaskID != .invalid {
            background.end(connectionBackgroundTaskID)
            connectionBackgroundTaskID = .invalid
        }
    }
}

@MainActor
final class SystemDeviceBackgroundExecutionProvider: DeviceBackgroundExecutionProviding {
    var isInBackground: Bool { UIApplication.shared.applicationState != .active }

    func begin(
        expirationHandler: @escaping @MainActor () -> Void
    ) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: "Phone Services") {
            Task { @MainActor in expirationHandler() }
        }
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

@MainActor
final class SystemDeviceLocationProvider: NSObject, DeviceLocationProviding, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var wantsBackgroundAuthorization = false
    private var requestedAlwaysAuthorization = false

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var backgroundAuthorized: Bool { manager.authorizationStatus == .authorizedAlways }

    func requestBackgroundAuthorization() {
        wantsBackgroundAuthorization = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse where !requestedAlwaysAuthorization:
            requestedAlwaysAuthorization = true
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    func requestLocation() async throws -> CLLocation {
        guard continuation == nil else { throw DeviceServiceError.busy }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    self?.resolve(.failure(DeviceServiceError.timeout))
                }

                switch manager.authorizationStatus {
                case .authorizedAlways:
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = true
                    manager.requestLocation()
                case .authorizedWhenInUse:
                    manager.requestLocation()
                case .notDetermined:
                    manager.requestWhenInUseAuthorization()
                case .denied, .restricted:
                    resolve(.failure(DeviceServiceError.permission))
                @unknown default:
                    resolve(.failure(DeviceServiceError.permission))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(.failure(CancellationError()))
            }
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last(where: Self.isUsableFix) else { return }
        Task { @MainActor in self.resolve(.success(location)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways:
                if self.continuation != nil {
                    manager.allowsBackgroundLocationUpdates = true
                    manager.showsBackgroundLocationIndicator = true
                    manager.requestLocation()
                }
            case .authorizedWhenInUse:
                if self.wantsBackgroundAuthorization && !self.requestedAlwaysAuthorization {
                    self.requestedAlwaysAuthorization = true
                    manager.requestAlwaysAuthorization()
                }
                if self.continuation != nil { manager.requestLocation() }
            case .denied, .restricted:
                self.resolve(.failure(DeviceServiceError.permission))
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(.failure(DeviceServiceError.network)) }
    }

    nonisolated private static func isUsableFix(_ location: CLLocation) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate) &&
            location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy <= 10_000 &&
            abs(location.timestamp.timeIntervalSinceNow) <= 30
    }

    private func resolve(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }
}

struct HTTPSURLPolicy: Equatable {
    let allowedHosts: Set<String>
    let allowedPaths: Set<String>

    static let deviceServices = HTTPSURLPolicy(
        allowedHosts: ["api.github.com"],
        allowedPaths: ["/zen"]
    )

    func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw DeviceServiceError.invalidURL
        }
        guard allowedHosts.contains(host), allowedPaths.contains(url.path) else {
            throw DeviceServiceError.forbiddenHost
        }
    }
}

struct SafeHTTPSResponse: Equatable {
    let statusCode: Int
    let body: Data
    let truncated: Bool
}

enum SafeHTTPSRequest {
    static let githubAPIVersion = "2026-03-10"

    static func make(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(githubAPIVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TumoCompanion", forHTTPHeaderField: "User-Agent")
        return request
    }
}

final class SafeHTTPSClient: DeviceHTTPSProviding {
    private let policy: HTTPSURLPolicy
    private let maximumDownloadBytes: Int

    init(
        policy: HTTPSURLPolicy = .deviceServices,
        maximumDownloadBytes: Int = 4 * 1024
    ) {
        self.policy = policy
        self.maximumDownloadBytes = maximumDownloadBytes
    }

    func get(_ url: URL) async throws -> SafeHTTPSResponse {
        try policy.validate(url)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12

        let redirect = RejectRedirectDelegate()
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = SafeHTTPSRequest.make(for: url)
        let (bytes, response) = try await session.bytes(for: request, delegate: redirect)

        guard let response = response as? HTTPURLResponse else {
            throw DeviceServiceError.network
        }

        var data = Data()
        data.reserveCapacity(min(maximumDownloadBytes, DeviceServiceContract.maximumResponseBytes))
        for try await byte in bytes {
            guard data.count < maximumDownloadBytes else {
                throw DeviceServiceError.responseTooLarge
            }
            data.append(byte)
        }

        let bodyLimit = DeviceServiceContract.maximumResponseBytes
        return SafeHTTPSResponse(
            statusCode: response.statusCode,
            body: data.prefix(bodyLimit),
            truncated: data.count > bodyLimit
        )
    }
}

private final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
