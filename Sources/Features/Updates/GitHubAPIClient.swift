import CryptoKit
import Foundation

struct GitHubAPIResult: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case network
        case freshCache
        case revalidatedCache
        case staleCache
    }

    let data: Data
    let source: Source
}

enum GitHubAPIError: LocalizedError, Equatable {
    case invalidResponse
    case invalidJSON
    case responseTooLarge
    case transportFailure
    case authenticationExpired
    case rateLimited(resetAt: Date?)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .invalidJSON:
            return "GitHub returned an invalid catalog."
        case .responseTooLarge:
            return "GitHub returned a catalog that is too large."
        case .transportFailure:
            return "GitHub is unavailable. Check your connection and try again."
        case .authenticationExpired:
            return "GitHub sign-in expired. Reconnect your account in Settings."
        case .rateLimited(let resetAt):
            if let resetAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "GitHub request limit reached. Try again after \(formatter.string(from: resetAt))."
            }
            return "GitHub request limit reached. Try again later."
        case .httpStatus(let status):
            return "GitHub request failed (HTTP \(status))."
        }
    }
}

struct GitHubHTTPResponse: @unchecked Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Shared, quota-conscious access to GitHub's REST API.
///
/// Successful JSON responses are cached on disk and revalidated with ETag. Calls for
/// the same URL share one in-flight request, so opening Updates cannot make Firmware,
/// FW Packages and background monitors consume duplicate quota. When the user connects
/// GitHub, the OAuth token is read from Keychain and applied to every request. A previously
/// validated response remains usable during a transient outage or a rate-limit response.
actor GitHubAPIClient {
    typealias Sender = @Sendable (URLRequest) async throws -> GitHubHTTPResponse

    static let shared = GitHubAPIClient()

    private struct CacheEntry: Codable, Sendable {
        let data: Data
        let etag: String?
        let storedAt: Date
    }

    private static let maximumResponseBytes = 8 * 1024 * 1024
    private static let apiVersion = "2022-11-28"
    private static let userAgent = "TumoCompanion"

    private let cacheDirectory: URL
    private let defaultMaxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let sender: Sender
    private let credentials: any GitHubCredentialStoring
    private var memoryCache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<GitHubAPIResult, Error>] = [:]

    init(
        cacheDirectory: URL = GitHubAPIClient.defaultCacheDirectory(),
        defaultMaxAge: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        credentials: any GitHubCredentialStoring = KeychainGitHubCredentialStore.shared,
        sender: @escaping Sender = GitHubAPIClient.liveSender
    ) {
        self.cacheDirectory = cacheDirectory
        self.defaultMaxAge = defaultMaxAge
        self.now = now
        self.credentials = credentials
        self.sender = sender
    }

    func data(
        from url: URL,
        maxAge: TimeInterval? = nil,
        allowStaleOnError: Bool = true
    ) async throws -> GitHubAPIResult {
        guard url.scheme == "https", url.host?.caseInsensitiveCompare("api.github.com") == .orderedSame else {
            throw GitHubAPIError.invalidResponse
        }

        let cacheKey = url.absoluteString
        let cached = loadCache(for: cacheKey)
        let freshness = max(0, maxAge ?? defaultMaxAge)
        if let cached, now().timeIntervalSince(cached.storedAt) < freshness {
            return GitHubAPIResult(data: cached.data, source: .freshCache)
        }
        // A security-sensitive recheck must never share an in-flight request that is
        // allowed to turn a transport failure into stale catalog data.
        let requestKey = "\(cacheKey)\u{001F}stale=\(allowStaleOnError)"
        if let task = inFlight[requestKey] {
            return try await task.value
        }

        let task = Task { [self] in
            try await fetch(
                url: url,
                key: cacheKey,
                cached: cached,
                allowStaleOnError: allowStaleOnError
            )
        }
        inFlight[requestKey] = task
        defer { inFlight[requestKey] = nil }
        return try await task.value
    }

    private func fetch(
        url: URL,
        key: String,
        cached: CacheEntry?,
        allowStaleOnError: Bool
    ) async throws -> GitHubAPIResult {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let token = try? credentials.readToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let etag = cached?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let response: GitHubHTTPResponse
        do {
            response = try await sender(request)
        } catch {
            if UpdateTaskCancellation.isCancellation(error) { throw error }
            if allowStaleOnError, let cached {
                return GitHubAPIResult(data: cached.data, source: .staleCache)
            }
            throw GitHubAPIError.transportFailure
        }

        switch response.statusCode {
        case 200:
            guard response.data.count <= Self.maximumResponseBytes else {
                if allowStaleOnError, let cached {
                    return GitHubAPIResult(data: cached.data, source: .staleCache)
                }
                throw GitHubAPIError.responseTooLarge
            }
            guard (try? JSONSerialization.jsonObject(with: response.data)) != nil else {
                if allowStaleOnError, let cached {
                    return GitHubAPIResult(data: cached.data, source: .staleCache)
                }
                throw GitHubAPIError.invalidJSON
            }
            let entry = CacheEntry(
                data: response.data,
                etag: response.header("ETag"),
                storedAt: now()
            )
            saveCache(entry, for: key)
            return GitHubAPIResult(data: response.data, source: .network)

        case 304:
            guard let cached else { throw GitHubAPIError.invalidResponse }
            let refreshed = CacheEntry(data: cached.data, etag: cached.etag, storedAt: now())
            saveCache(refreshed, for: key)
            return GitHubAPIResult(data: cached.data, source: .revalidatedCache)

        case 401:
            try? credentials.writeToken(nil)
            NotificationCenter.default.post(name: .githubCredentialInvalidated, object: nil)
            if allowStaleOnError, let cached {
                return GitHubAPIResult(data: cached.data, source: .staleCache)
            }
            throw GitHubAPIError.authenticationExpired

        case 403, 429:
            if allowStaleOnError, let cached {
                return GitHubAPIResult(data: cached.data, source: .staleCache)
            }
            let resetAt = response.header("X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map { Date(timeIntervalSince1970: $0) }
                ?? response.header("Retry-After")
                    .flatMap(TimeInterval.init)
                    .map { now().addingTimeInterval($0) }
            let rateLimited = response.statusCode == 429
                || response.header("X-RateLimit-Remaining") == "0"
                || response.header("Retry-After") != nil
                || resetAt != nil
            if rateLimited {
                throw GitHubAPIError.rateLimited(resetAt: resetAt)
            }
            throw GitHubAPIError.httpStatus(response.statusCode)

        case 500...599:
            if allowStaleOnError, let cached {
                return GitHubAPIResult(data: cached.data, source: .staleCache)
            }
            throw GitHubAPIError.httpStatus(response.statusCode)

        default:
            throw GitHubAPIError.httpStatus(response.statusCode)
        }
    }

    private func loadCache(for key: String) -> CacheEntry? {
        if let entry = memoryCache[key] { return entry }
        let url = cacheURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let entry = try? PropertyListDecoder().decode(CacheEntry.self, from: data) else {
            return nil
        }
        memoryCache[key] = entry
        return entry
    }

    private func saveCache(_ entry: CacheEntry, for key: String) {
        memoryCache[key] = entry
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(entry)
            try data.write(to: cacheURL(for: key), options: .atomic)
        } catch {
            // The in-memory cache is still safe to use for this app session.
        }
    }

    private func cacheURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(digest).plist", isDirectory: false)
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("GitHubAPI", isDirectory: true)
    }

    private static let liveSender: Sender = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let key = item.key as? String else { return }
            result[key] = String(describing: item.value)
        }
        return GitHubHTTPResponse(statusCode: http.statusCode, headers: headers, data: data)
    }
}
