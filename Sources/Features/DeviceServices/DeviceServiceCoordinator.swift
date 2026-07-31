import Combine
import CoreLocation
import Foundation

enum DeviceServiceKind: Equatable {
    case location
    case network
}

enum DeviceServiceState: Equatable {
    case off
    case unavailable
    case available
    case inUse
    case denied

    var label: String {
        switch self {
        case .off: return "Off"
        case .unavailable: return "Unavailable"
        case .available: return "Available"
        case .inUse: return "In use"
        case .denied: return "Permission denied"
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
        }
    }
}

protocol DeviceServiceTransport: AnyObject {
    var deviceServiceFrames: AnyPublisher<AppBridgeFrame, Never> { get }
    var deviceServiceConnectionStates: AnyPublisher<FlipperConnectionState, Never> { get }
    var deviceServiceReady: Bool { get }
    var deviceServicesSupported: Bool { get }
    var deviceServiceBuddyMode: Bool { get }
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
    func requestLocation() async throws -> CLLocation
    func cancel()
}

protocol DeviceHTTPSProviding: AnyObject {
    func get(_ url: URL) async throws -> SafeHTTPSResponse
}

enum DeviceServiceContract {
    static let appID = "device_services"
    static let gpsCommand = "gps_once"
    static let httpsCommand = "https_get"
    static let maximumRequestBytes = 160
    static let maximumResponseBytes = 512

    static func gpsPayload(_ location: CLLocation) -> Data {
        let timestamp = Int(location.timestamp.timeIntervalSince1970)
        let text = String(
            format: "schema=1;lat=%.6f;lon=%.6f;alt=%.1f;acc=%.1f;ts=%d",
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
}

@MainActor
final class DeviceServiceCoordinator: ObservableObject {
    @Published var locationEnabled: Bool {
        didSet { defaults.set(locationEnabled, forKey: Self.locationEnabledKey) }
    }
    @Published var networkEnabled: Bool {
        didSet { defaults.set(networkEnabled, forKey: Self.networkEnabledKey) }
    }
    @Published private(set) var activeService: DeviceServiceKind?
    @Published private(set) var lastError: String?

    private static let locationEnabledKey = "deviceServices.locationEnabled.v1"
    private static let networkEnabledKey = "deviceServices.networkEnabled.v1"

    private let transport: DeviceServiceTransport
    private let location: DeviceLocationProviding
    private let https: DeviceHTTPSProviding
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UInt32?

    convenience init() {
        self.init(
            transport: FlipperBLE.shared,
            location: SystemDeviceLocationProvider(),
            https: SafeHTTPSClient(),
            defaults: .standard
        )
    }

    init(
        transport: DeviceServiceTransport,
        location: DeviceLocationProviding,
        https: DeviceHTTPSProviding,
        defaults: UserDefaults
    ) {
        self.transport = transport
        self.location = location
        self.https = https
        self.defaults = defaults
        locationEnabled = defaults.bool(forKey: Self.locationEnabledKey)
        networkEnabled = defaults.bool(forKey: Self.networkEnabledKey)

        transport.deviceServiceFrames
            .sink { [weak self] frame in
                Task { @MainActor in self?.receive(frame) }
            }
            .store(in: &cancellables)

        transport.deviceServiceConnectionStates
            .sink { [weak self] state in
                guard state != .ready else { return }
                Task { @MainActor in self?.cancelActiveRequest() }
            }
            .store(in: &cancellables)
    }

    var locationState: DeviceServiceState {
        guard locationEnabled else { return .off }
        if activeService == .location { return .inUse }
        switch location.authorizationStatus {
        case .denied, .restricted: return .denied
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
            start(frame, kind: .location) { [transport, location] in
                try await transport.ensureDeviceServiceSession()
                return DeviceServiceContract.gpsPayload(try await location.requestLocation())
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

        default:
            respondError(.unsupported, command: frame.command, requestID: frame.requestID)
        }
    }

    private func start(
        _ frame: AppBridgeFrame,
        kind: DeviceServiceKind,
        operation: @escaping @MainActor () async throws -> Data
    ) {
        activeRequestID = frame.requestID
        activeService = kind
        lastError = nil
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
    }
}

@MainActor
final class SystemDeviceLocationProvider: NSObject, DeviceLocationProviding, CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<CLLocation, Error>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

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
                case .authorizedAlways, .authorizedWhenInUse:
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
        guard let location = locations.last else { return }
        Task { @MainActor in self.resolve(.success(location)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            switch status {
            case .authorizedAlways, .authorizedWhenInUse:
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

    private func resolve(_ result: Result<CLLocation, Error>) {
        guard let continuation else { return }
        self.continuation = nil
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
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
