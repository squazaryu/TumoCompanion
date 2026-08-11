import Foundation

struct GitHubDeviceAuthorization: Sendable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
}

struct GitHubAccount: Sendable, Equatable {
    let login: String
    let profileURL: URL
}

struct GitHubRateLimit: Sendable, Equatable {
    let limit: Int
    let remaining: Int
    let resetAt: Date
}

struct GitHubAuthenticatedSession: Sendable, Equatable {
    let account: GitHubAccount
    let rateLimit: GitHubRateLimit
}

enum GitHubDevicePollResult: Sendable, Equatable {
    case pending
    case slowDown
    case authorized(token: String)
}

enum GitHubOAuthError: LocalizedError, Equatable {
    case notConfigured
    case invalidClientID
    case invalidResponse
    case responseTooLarge
    case transportFailure
    case authorizationDenied
    case authorizationExpired
    case deviceFlowDisabled
    case invalidCredential
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "GitHub sign-in is not configured in this build."
        case .invalidClientID:
            return "The GitHub sign-in configuration is invalid."
        case .invalidResponse:
            return "GitHub returned an invalid sign-in response."
        case .responseTooLarge:
            return "GitHub returned an oversized sign-in response."
        case .transportFailure:
            return "GitHub sign-in is unavailable. Check your connection and try again."
        case .authorizationDenied:
            return "GitHub sign-in was declined."
        case .authorizationExpired:
            return "The GitHub sign-in code expired. Start again."
        case .deviceFlowDisabled:
            return "GitHub Device Flow is not enabled for TumoCompanion."
        case .invalidCredential:
            return "The GitHub credential is no longer valid. Sign in again."
        case .httpStatus(let status):
            return "GitHub sign-in failed (HTTP \(status))."
        }
    }
}

struct GitHubOAuthHTTPResponse: @unchecked Sendable {
    let statusCode: Int
    let data: Data
}

struct GitHubOAuthClient: Sendable {
    typealias Sender = @Sendable (URLRequest) async throws -> GitHubOAuthHTTPResponse

    private static let maximumResponseBytes = 64 * 1024
    private static let apiVersion = "2022-11-28"
    private static let userAgent = "TumoCompanion"

    private let sender: Sender
    private let now: @Sendable () -> Date

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        sender: @escaping Sender = GitHubOAuthClient.liveSender
    ) {
        self.now = now
        self.sender = sender
    }

    func requestDeviceAuthorization(clientID: String) async throws -> GitHubDeviceAuthorization {
        try Self.validate(clientID: clientID)
        let response = try await sendForm(
            url: URL(string: "https://github.com/login/device/code")!,
            values: [("client_id", clientID)]
        )
        guard response.statusCode == 200 else {
            throw GitHubOAuthError.httpStatus(response.statusCode)
        }
        let payload = try decode(DeviceAuthorizationResponse.self, from: response.data)
        guard Self.isOpaqueValue(payload.deviceCode, maximumBytes: 256),
              Self.isUserCode(payload.userCode),
              (1...1_800).contains(payload.expiresIn),
              (1...60).contains(payload.interval),
              payload.verificationURI.scheme == "https",
              payload.verificationURI.host?.caseInsensitiveCompare("github.com") == .orderedSame,
              payload.verificationURI.path == "/login/device" else {
            throw GitHubOAuthError.invalidResponse
        }
        return GitHubDeviceAuthorization(
            deviceCode: payload.deviceCode,
            userCode: payload.userCode,
            verificationURL: payload.verificationURI,
            expiresAt: now().addingTimeInterval(TimeInterval(payload.expiresIn)),
            interval: TimeInterval(payload.interval)
        )
    }

    func poll(clientID: String, deviceCode: String) async throws -> GitHubDevicePollResult {
        try Self.validate(clientID: clientID)
        guard Self.isOpaqueValue(deviceCode, maximumBytes: 256) else {
            throw GitHubOAuthError.invalidResponse
        }
        let response = try await sendForm(
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            values: [
                ("client_id", clientID),
                ("device_code", deviceCode),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ]
        )
        guard response.statusCode == 200 else {
            throw GitHubOAuthError.httpStatus(response.statusCode)
        }
        let payload = try decode(TokenResponse.self, from: response.data)
        if let token = payload.accessToken {
            guard KeychainGitHubCredentialStore.isValid(token: token),
                  payload.tokenType?.caseInsensitiveCompare("bearer") == .orderedSame,
                  (payload.scope ?? "").isEmpty else {
                throw GitHubOAuthError.invalidResponse
            }
            return .authorized(token: token)
        }
        switch payload.error {
        case "authorization_pending":
            return .pending
        case "slow_down":
            return .slowDown
        case "expired_token":
            throw GitHubOAuthError.authorizationExpired
        case "access_denied":
            throw GitHubOAuthError.authorizationDenied
        case "device_flow_disabled":
            throw GitHubOAuthError.deviceFlowDisabled
        default:
            throw GitHubOAuthError.invalidResponse
        }
    }

    func validate(token: String) async throws -> GitHubAuthenticatedSession {
        guard KeychainGitHubCredentialStore.isValid(token: token) else {
            throw GitHubOAuthError.invalidCredential
        }
        let accountResponse = try await sendAPI(
            url: URL(string: "https://api.github.com/user")!,
            token: token
        )
        if accountResponse.statusCode == 401 { throw GitHubOAuthError.invalidCredential }
        guard accountResponse.statusCode == 200 else {
            throw GitHubOAuthError.httpStatus(accountResponse.statusCode)
        }
        let accountPayload = try decode(AccountResponse.self, from: accountResponse.data)
        guard Self.isLogin(accountPayload.login),
              accountPayload.htmlURL.scheme == "https",
              accountPayload.htmlURL.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
            throw GitHubOAuthError.invalidResponse
        }

        let rateResponse = try await sendAPI(
            url: URL(string: "https://api.github.com/rate_limit")!,
            token: token
        )
        if rateResponse.statusCode == 401 { throw GitHubOAuthError.invalidCredential }
        guard rateResponse.statusCode == 200 else {
            throw GitHubOAuthError.httpStatus(rateResponse.statusCode)
        }
        let ratePayload = try decode(RateLimitResponse.self, from: rateResponse.data).resources.core
        guard ratePayload.limit > 0,
              (0...ratePayload.limit).contains(ratePayload.remaining),
              ratePayload.reset > 0 else {
            throw GitHubOAuthError.invalidResponse
        }

        return GitHubAuthenticatedSession(
            account: GitHubAccount(login: accountPayload.login, profileURL: accountPayload.htmlURL),
            rateLimit: GitHubRateLimit(
                limit: ratePayload.limit,
                remaining: ratePayload.remaining,
                resetAt: Date(timeIntervalSince1970: TimeInterval(ratePayload.reset))
            )
        )
    }

    private func sendForm(
        url: URL,
        values: [(String, String)]
    ) async throws -> GitHubOAuthHTTPResponse {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "POST"
        request.httpBody = Self.formBody(values)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return try await send(request)
    }

    private func sendAPI(url: URL, token: String) async throws -> GitHubOAuthHTTPResponse {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> GitHubOAuthHTTPResponse {
        do {
            let response = try await sender(request)
            guard response.data.count <= Self.maximumResponseBytes else {
                throw GitHubOAuthError.responseTooLarge
            }
            return response
        } catch let error as GitHubOAuthError {
            throw error
        } catch {
            if UpdateTaskCancellation.isCancellation(error) { throw error }
            throw GitHubOAuthError.transportFailure
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubOAuthError.invalidResponse
        }
    }

    private static func formBody(_ values: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func validate(clientID: String) throws {
        let bytes = clientID.utf8
        guard !bytes.isEmpty, bytes.count <= 128,
              bytes.allSatisfy({
                  ($0 >= 0x30 && $0 <= 0x39) ||
                      ($0 >= 0x41 && $0 <= 0x5a) ||
                      ($0 >= 0x61 && $0 <= 0x7a)
              }) else {
            throw GitHubOAuthError.invalidClientID
        }
    }

    private static func isOpaqueValue(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumBytes && bytes.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }

    private static func isUserCode(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (8...16).contains(bytes.count) else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || $0 == 0x2d
        }
    }

    private static func isLogin(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        return bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) ||
                ($0 >= 0x41 && $0 <= 0x5a) ||
                ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2d
        }
    }

    private static let liveSender: Sender = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubOAuthError.invalidResponse
        }
        return GitHubOAuthHTTPResponse(statusCode: http.statusCode, data: data)
    }
}

private struct DeviceAuthorizationResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
    }
}

private struct AccountResponse: Decodable {
    let login: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case login
        case htmlURL = "html_url"
    }
}

private struct RateLimitResponse: Decodable {
    struct Resources: Decodable {
        let core: Core
    }

    struct Core: Decodable {
        let limit: Int
        let remaining: Int
        let reset: Int
    }

    let resources: Resources
}
