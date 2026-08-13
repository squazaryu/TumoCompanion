import Foundation
import XCTest
@testable import UnleashedCompanion

final class GitHubAPIClientTests: XCTestCase {
    private let url = URL(string: "https://api.github.com/repos/squazaryu/tumoflip/releases?per_page=100")!

    func testFreshCacheAvoidsDuplicateRequestAndPersistsAcrossClients() async throws {
        let directory = temporaryDirectory()
        let transport = StubTransport([
            .success(response(200, data: json("v1"), headers: ["ETag": "\"one\""])),
        ])
        let firstClient = client(directory: directory, transport: transport)

        let first = try await firstClient.data(from: url)
        let second = try await firstClient.data(from: url)
        let secondClient = client(directory: directory, transport: transport)
        let restored = try await secondClient.data(from: url)

        XCTAssertEqual(first.source, .network)
        XCTAssertEqual(second.source, .freshCache)
        XCTAssertEqual(restored.source, .freshCache)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.data, restored.data)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testExpiredCacheRevalidatesWithETagAndAccepts304() async throws {
        let directory = temporaryDirectory()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let transport = StubTransport([
            .success(response(200, data: json("v1"), headers: ["ETag": "\"catalog-v1\""])),
            .success(response(304, data: Data())),
        ])
        let client = client(directory: directory, clock: clock, transport: transport)

        let first = try await client.data(from: url)
        clock.advance(by: 61)
        let second = try await client.data(from: url)

        XCTAssertEqual(first.source, .network)
        XCTAssertEqual(second.source, .revalidatedCache)
        XCTAssertEqual(first.data, second.data)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"catalog-v1\"")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "User-Agent"), "TumoCompanion")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    }

    func testConnectedAccountAddsBearerToken() async throws {
        let credentials = MemoryGitHubCredentialStore(token: "gho_test_token")
        let transport = StubTransport([
            .success(response(200, data: json("v1"))),
        ])
        let client = client(
            directory: temporaryDirectory(),
            credentials: credentials,
            transport: transport
        )

        _ = try await client.data(from: url)

        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_test_token")
    }

    func testUnauthorizedResponseDeletesCredentialAndFailsClosed() async throws {
        let credentials = MemoryGitHubCredentialStore(token: "gho_expired")
        let transport = StubTransport([
            .success(response(401)),
        ])
        let client = client(
            directory: temporaryDirectory(),
            credentials: credentials,
            transport: transport
        )

        do {
            _ = try await client.data(from: url)
            XCTFail("Expected authentication failure")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .authenticationExpired)
        }
        XCTAssertNil(try credentials.readToken())
    }

    func testRateLimitReturnsLastValidatedCatalog() async throws {
        let directory = temporaryDirectory()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let transport = StubTransport([
            .success(response(200, data: json("v1"))),
            .success(response(403, headers: ["X-RateLimit-Reset": "2000"])),
        ])
        let client = client(directory: directory, clock: clock, transport: transport)

        let first = try await client.data(from: url)
        clock.advance(by: 61)
        let fallback = try await client.data(from: url)

        XCTAssertEqual(fallback.source, .staleCache)
        XCTAssertEqual(fallback.data, first.data)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 2)
    }

    func testTransportFailureReturnsLastValidatedCatalog() async throws {
        let directory = temporaryDirectory()
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let transport = StubTransport([
            .success(response(200, data: json("v1"))),
            .failure(URLError(.timedOut)),
        ])
        let client = client(directory: directory, clock: clock, transport: transport)

        _ = try await client.data(from: url)
        clock.advance(by: 61)
        let fallback = try await client.data(from: url)

        XCTAssertEqual(fallback.source, .staleCache)
        XCTAssertEqual(fallback.data, json("v1"))
    }

    func testSecuritySensitiveRecheckRejectsStaleCatalogOnTransportFailure() async throws {
        let directory = temporaryDirectory()
        let transport = StubTransport([
            .success(response(200, data: json("v1"))),
            .failure(URLError(.timedOut)),
        ])
        let client = client(directory: directory, transport: transport)

        _ = try await client.data(from: url)
        do {
            _ = try await client.data(
                from: url,
                maxAge: 0,
                allowStaleOnError: false
            )
            XCTFail("A pre-install recheck must not use stale catalog bytes")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .transportFailure)
        }
    }

    func testTransportFailureWithoutCacheIsActionable() async throws {
        let transport = StubTransport([
            .failure(URLError(.notConnectedToInternet)),
        ])
        let client = client(directory: temporaryDirectory(), transport: transport)

        do {
            _ = try await client.data(from: url)
            XCTFail("Expected transport failure")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .transportFailure)
            XCTAssertFalse(error.localizedDescription.contains("NSURLError"))
        }
    }

    func testRateLimitWithoutCacheReportsResetTime() async throws {
        let transport = StubTransport([
            .success(response(429, headers: ["X-RateLimit-Reset": "2000"])),
        ])
        let client = client(directory: temporaryDirectory(), transport: transport)

        do {
            _ = try await client.data(from: url)
            XCTFail("Expected rate-limit failure")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .rateLimited(resetAt: Date(timeIntervalSince1970: 2_000)))
            XCTAssertFalse(error.localizedDescription.contains("NSURLError"))
        }
    }

    func testNonRateLimit403IsReportedAsHTTPFailure() async throws {
        let transport = StubTransport([
            .success(response(403, data: Data("forbidden".utf8))),
        ])
        let client = client(directory: temporaryDirectory(), transport: transport)

        do {
            _ = try await client.data(from: url)
            XCTFail("Expected HTTP failure")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .httpStatus(403))
        }
    }

    func testConcurrentIdenticalRequestsAreCoalesced() async throws {
        let transport = StubTransport(
            [.success(response(200, data: json("v1")))],
            delayNanoseconds: 100_000_000
        )
        let client = client(directory: temporaryDirectory(), transport: transport)

        async let first = client.data(from: url)
        async let second = client.data(from: url)
        let firstValue = try await first
        let secondValue = try await second

        XCTAssertEqual(firstValue.data, secondValue.data)
        let count = await transport.requestCount()
        XCTAssertEqual(count, 1)
    }

    func testRejectsNonGitHubAPIHostBeforeTransport() async throws {
        let transport = StubTransport([])
        let client = client(directory: temporaryDirectory(), transport: transport)

        do {
            _ = try await client.data(from: URL(string: "https://example.com/releases")!)
            XCTFail("Expected invalid response")
        } catch let error as GitHubAPIError {
            XCTAssertEqual(error, .invalidResponse)
        }
        let count = await transport.requestCount()
        XCTAssertEqual(count, 0)
    }

    private func client(
        directory: URL,
        clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_000)),
        credentials: any GitHubCredentialStoring = MemoryGitHubCredentialStore(),
        transport: StubTransport
    ) -> GitHubAPIClient {
        GitHubAPIClient(
            cacheDirectory: directory,
            defaultMaxAge: 60,
            now: { clock.now },
            credentials: credentials,
            sender: { request in try await transport.send(request) }
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAPIClientTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func json(_ value: String) -> Data {
        Data("{\"tag_name\":\"\(value)\"}".utf8)
    }

    private func response(
        _ status: Int,
        data: Data = Data(),
        headers: [String: String] = [:]
    ) -> GitHubHTTPResponse {
        GitHubHTTPResponse(statusCode: status, headers: headers, data: data)
    }
}

private final class MemoryGitHubCredentialStore: GitHubCredentialStoring, @unchecked Sendable {
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

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor StubTransport {
    private var responses: [Result<GitHubHTTPResponse, Error>]
    private var requests: [URLRequest] = []
    private let delayNanoseconds: UInt64

    init(
        _ responses: [Result<GitHubHTTPResponse, Error>],
        delayNanoseconds: UInt64 = 0
    ) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func send(_ request: URLRequest) async throws -> GitHubHTTPResponse {
        requests.append(request)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !responses.isEmpty else {
            throw URLError(.resourceUnavailable)
        }
        return try responses.removeFirst().get()
    }

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [URLRequest] { requests }
}
