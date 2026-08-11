import Foundation
import XCTest
@testable import UnleashedCompanion

@MainActor
final class GitHubAuthStoreTests: XCTestCase {
    private let clientID = "Iv1TumoCompanion123"

    func testDeviceFlowStoresTokenOnlyAfterIdentityValidation() async throws {
        let credentials = AuthMemoryCredentialStore()
        let transport = AuthStubTransport([
            .success(response(200, json: deviceAuthorizationJSON)),
            .success(response(200, json: ["error": "authorization_pending"])),
            .success(response(200, json: ["error": "slow_down"])),
            .success(response(200, json: [
                "access_token": "gho_new_token",
                "token_type": "bearer",
                "scope": "",
            ])),
            .success(response(200, json: accountJSON)),
            .success(response(200, json: rateLimitJSON)),
        ])
        let store = makeStore(credentials: credentials, transport: transport)

        await store.startSignIn()

        XCTAssertNotNil(store.pendingAuthorization)
        XCTAssertNil(try credentials.readToken())
        try await waitUntil { store.account?.login == "squazaryu" }
        XCTAssertEqual(try credentials.readToken(), "gho_new_token")
        XCTAssertEqual(store.rateLimit?.limit, 5_000)
        XCTAssertNil(store.pendingAuthorization)
        XCTAssertNil(store.errorMessage)
    }

    func testRestoreDeletesRejectedStoredCredential() async throws {
        let credentials = AuthMemoryCredentialStore(token: "gho_expired")
        let transport = AuthStubTransport([
            .success(response(401, json: ["message": "Bad credentials"])),
        ])
        let store = makeStore(credentials: credentials, transport: transport)

        await store.restoreSession()

        XCTAssertNil(try credentials.readToken())
        XCTAssertFalse(store.hasStoredCredential)
        XCTAssertNil(store.account)
        XCTAssertEqual(store.errorMessage, GitHubOAuthError.invalidCredential.localizedDescription)
    }

    func testTransientRestoreFailureKeepsStoredCredential() async throws {
        let credentials = AuthMemoryCredentialStore(token: "gho_still_valid")
        let transport = AuthStubTransport([
            .failure(URLError(.notConnectedToInternet)),
        ])
        let store = makeStore(credentials: credentials, transport: transport)

        await store.restoreSession()

        XCTAssertEqual(try credentials.readToken(), "gho_still_valid")
        XCTAssertTrue(store.hasStoredCredential)
        XCTAssertEqual(store.errorMessage, GitHubOAuthError.transportFailure.localizedDescription)
    }

    func testSignOutDeletesKeychainCredentialAndAccountState() async throws {
        let credentials = AuthMemoryCredentialStore(token: "gho_valid")
        let transport = AuthStubTransport([
            .success(response(200, json: accountJSON)),
            .success(response(200, json: rateLimitJSON)),
        ])
        let store = makeStore(credentials: credentials, transport: transport)
        await store.restoreSession()
        XCTAssertEqual(store.account?.login, "squazaryu")

        store.signOut()

        XCTAssertNil(try credentials.readToken())
        XCTAssertNil(store.account)
        XCTAssertNil(store.rateLimit)
        XCTAssertFalse(store.hasStoredCredential)
    }

    func testMissingClientIDFailsWithoutNetworkRequest() async throws {
        let credentials = AuthMemoryCredentialStore()
        let transport = AuthStubTransport([])
        let store = GitHubAuthStore(
            clientID: nil,
            credentials: credentials,
            oauth: oauth(transport),
            sleeper: { _ in }
        )

        await store.startSignIn()

        XCTAssertFalse(store.isConfigured)
        XCTAssertEqual(store.errorMessage, GitHubOAuthError.notConfigured.localizedDescription)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private func makeStore(
        credentials: AuthMemoryCredentialStore,
        transport: AuthStubTransport
    ) -> GitHubAuthStore {
        GitHubAuthStore(
            clientID: clientID,
            credentials: credentials,
            oauth: oauth(transport),
            now: { Date(timeIntervalSince1970: 1_000) },
            sleeper: { _ in await Task.yield() }
        )
    }

    private func oauth(_ transport: AuthStubTransport) -> GitHubOAuthClient {
        GitHubOAuthClient(
            now: { Date(timeIntervalSince1970: 1_000) },
            sender: { request in try await transport.send(request) }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { throw WaitError.timedOut }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private var deviceAuthorizationJSON: [String: Any] {
        [
            "device_code": "device-code-123",
            "user_code": "ABCD-EFGH",
            "verification_uri": "https://github.com/login/device",
            "expires_in": 900,
            "interval": 5,
        ]
    }

    private var accountJSON: [String: Any] {
        ["login": "squazaryu", "html_url": "https://github.com/squazaryu"]
    }

    private var rateLimitJSON: [String: Any] {
        [
            "resources": [
                "core": ["limit": 5_000, "remaining": 4_999, "reset": 2_000],
            ],
        ]
    }

    private func response(_ status: Int, json: [String: Any]) -> GitHubOAuthHTTPResponse {
        GitHubOAuthHTTPResponse(
            statusCode: status,
            data: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        )
    }

    private enum WaitError: Error { case timedOut }
}

private final class AuthMemoryCredentialStore: GitHubCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func readToken() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func writeToken(_ token: String?) throws {
        lock.lock()
        self.token = token
        lock.unlock()
    }
}

private actor AuthStubTransport {
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

    func requestCount() -> Int { requests.count }
}
