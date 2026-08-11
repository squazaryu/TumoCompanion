import Foundation
import XCTest
@testable import UnleashedCompanion

final class GitHubOAuthClientTests: XCTestCase {
    private let clientID = "Iv1TumoCompanion123"

    func testCredentialValidationRejectsWhitespaceControlBytesAndOversizedValues() {
        XCTAssertTrue(KeychainGitHubCredentialStore.isValid(token: "gho_valid-token_123"))
        XCTAssertFalse(KeychainGitHubCredentialStore.isValid(token: ""))
        XCTAssertFalse(KeychainGitHubCredentialStore.isValid(token: "gho token"))
        XCTAssertFalse(KeychainGitHubCredentialStore.isValid(token: "gho_token\n"))
        XCTAssertFalse(KeychainGitHubCredentialStore.isValid(token: String(repeating: "a", count: 513)))
    }

    func testRequestsDeviceCodeWithoutRepositoryScopesOrSecret() async throws {
        let clock = Date(timeIntervalSince1970: 1_000)
        let transport = OAuthStubTransport([
            .success(response(200, json: [
                "device_code": "device-code-123",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://github.com/login/device",
                "expires_in": 900,
                "interval": 5,
            ])),
        ])
        let client = makeClient(transport: transport, now: clock)

        let authorization = try await client.requestDeviceAuthorization(clientID: clientID)

        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.expiresAt, clock.addingTimeInterval(900))
        XCTAssertEqual(authorization.interval, 5)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "TumoCompanion")
        let form = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertEqual(form, "client_id=Iv1TumoCompanion123")
        XCTAssertFalse(form?.contains("scope") == true)
        XCTAssertFalse(form?.contains("secret") == true)
    }

    func testRejectsDeviceResponseThatLeavesOfficialGitHubVerificationPage() async throws {
        let transport = OAuthStubTransport([
            .success(response(200, json: [
                "device_code": "device-code-123",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://example.com/login/device",
                "expires_in": 900,
                "interval": 5,
            ])),
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsOAuthError(.invalidResponse) {
            _ = try await client.requestDeviceAuthorization(clientID: self.clientID)
        }
    }

    func testPollHandlesPendingSlowDownAndAuthorization() async throws {
        let transport = OAuthStubTransport([
            .success(response(200, json: ["error": "authorization_pending"])),
            .success(response(200, json: ["error": "slow_down"])),
            .success(response(200, json: [
                "access_token": "gho_authorized_token",
                "token_type": "bearer",
                "scope": "",
            ])),
        ])
        let client = makeClient(transport: transport)

        let pending = try await client.poll(clientID: clientID, deviceCode: "device-code-123")
        let slowDown = try await client.poll(clientID: clientID, deviceCode: "device-code-123")
        let authorized = try await client.poll(clientID: clientID, deviceCode: "device-code-123")
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(slowDown, .slowDown)
        XCTAssertEqual(authorized, .authorized(token: "gho_authorized_token"))

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        let form = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        var components = URLComponents()
        components.query = form
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(fields["client_id"], "Iv1TumoCompanion123")
        XCTAssertEqual(fields["device_code"], "device-code-123")
        XCTAssertEqual(
            fields["grant_type"],
            "urn:ietf:params:oauth:grant-type:device_code"
        )
    }

    func testPollRejectsUnexpectedScopes() async throws {
        let transport = OAuthStubTransport([
            .success(response(200, json: [
                "access_token": "gho_overprivileged",
                "token_type": "bearer",
                "scope": "repo",
            ])),
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsOAuthError(.invalidResponse) {
            _ = try await client.poll(clientID: self.clientID, deviceCode: "device-code-123")
        }
    }

    func testPollMapsDenialAndExpiryToActionableErrors() async throws {
        let transport = OAuthStubTransport([
            .success(response(200, json: ["error": "access_denied"])),
            .success(response(200, json: ["error": "expired_token"])),
        ])
        let client = makeClient(transport: transport)

        await XCTAssertThrowsOAuthError(.authorizationDenied) {
            _ = try await client.poll(clientID: self.clientID, deviceCode: "device-code-123")
        }
        await XCTAssertThrowsOAuthError(.authorizationExpired) {
            _ = try await client.poll(clientID: self.clientID, deviceCode: "device-code-123")
        }
    }

    func testValidatesIdentityAndAuthenticatedRateLimit() async throws {
        let transport = OAuthStubTransport([
            .success(response(200, json: [
                "login": "squazaryu",
                "html_url": "https://github.com/squazaryu",
            ])),
            .success(response(200, json: [
                "resources": [
                    "core": ["limit": 5_000, "remaining": 4_998, "reset": 2_000],
                ],
            ])),
        ])
        let client = makeClient(transport: transport)

        let session = try await client.validate(token: "gho_valid_token")

        XCTAssertEqual(session.account.login, "squazaryu")
        XCTAssertEqual(session.rateLimit.limit, 5_000)
        XCTAssertEqual(session.rateLimit.remaining, 4_998)
        XCTAssertEqual(session.rateLimit.resetAt, Date(timeIntervalSince1970: 2_000))
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.url?.path), ["/user", "/rate_limit"])
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer gho_valid_token"
        })
    }

    func testValidationRejectsUnauthorizedTokenWithoutExposingIt() async throws {
        let token = "gho_do_not_log_this"
        let transport = OAuthStubTransport([
            .success(response(401, json: ["message": "Bad credentials"])),
        ])
        let client = makeClient(transport: transport)

        do {
            _ = try await client.validate(token: token)
            XCTFail("Expected invalid credential")
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, .invalidCredential)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    private func makeClient(
        transport: OAuthStubTransport,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> GitHubOAuthClient {
        GitHubOAuthClient(
            now: { now },
            sender: { request in try await transport.send(request) }
        )
    }

    private func response(_ status: Int, json: [String: Any]) -> GitHubOAuthHTTPResponse {
        GitHubOAuthHTTPResponse(
            statusCode: status,
            data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }

    private func XCTAssertThrowsOAuthError(
        _ expected: GitHubOAuthError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as GitHubOAuthError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor OAuthStubTransport {
    private var responses: [Result<GitHubOAuthHTTPResponse, Error>]
    private var requests: [URLRequest] = []

    init(_ responses: [Result<GitHubOAuthHTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> GitHubOAuthHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] { requests }
}
