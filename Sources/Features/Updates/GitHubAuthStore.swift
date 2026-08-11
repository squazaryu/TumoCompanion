import Foundation

enum GitHubOAuthConfiguration {
    static func clientID(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}

@MainActor
final class GitHubAuthStore: ObservableObject {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    static let shared = GitHubAuthStore()

    @Published private(set) var account: GitHubAccount?
    @Published private(set) var rateLimit: GitHubRateLimit?
    @Published private(set) var pendingAuthorization: GitHubDeviceAuthorization?
    @Published private(set) var hasStoredCredential = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    let isConfigured: Bool

    private let clientID: String?
    private let credentials: any GitHubCredentialStoring
    private let oauth: GitHubOAuthClient
    private let now: @Sendable () -> Date
    private let sleeper: Sleeper
    private var pollingTask: Task<Void, Never>?
    private var didRestore = false

    init(
        clientID: String? = GitHubOAuthConfiguration.clientID(),
        credentials: any GitHubCredentialStoring = KeychainGitHubCredentialStore.shared,
        oauth: GitHubOAuthClient = GitHubOAuthClient(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping Sleeper = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        }
    ) {
        let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = trimmed?.isEmpty == false ? trimmed : nil
        isConfigured = self.clientID != nil
        self.credentials = credentials
        self.oauth = oauth
        self.now = now
        self.sleeper = sleeper
    }

    deinit {
        pollingTask?.cancel()
    }

    func restoreSession(force: Bool = false) async {
        guard force || !didRestore else { return }
        didRestore = true
        pollingTask?.cancel()
        pendingAuthorization = nil
        errorMessage = nil

        let token: String
        do {
            guard let stored = try credentials.readToken() else {
                clearSession()
                return
            }
            token = stored
            hasStoredCredential = true
        } catch {
            clearSession()
            errorMessage = safeMessage(for: error)
            return
        }

        isWorking = true
        defer { isWorking = false }
        do {
            let session = try await oauth.validate(token: token)
            account = session.account
            rateLimit = session.rateLimit
            errorMessage = nil
        } catch GitHubOAuthError.invalidCredential {
            try? credentials.writeToken(nil)
            clearSession()
            errorMessage = GitHubOAuthError.invalidCredential.localizedDescription
        } catch {
            // A transient network failure must not destroy a valid stored token.
            account = nil
            rateLimit = nil
            errorMessage = safeMessage(for: error)
        }
    }

    func startSignIn() async {
        guard let clientID else {
            errorMessage = GitHubOAuthError.notConfigured.localizedDescription
            return
        }
        cancelSignIn(clearError: true)
        isWorking = true
        do {
            let authorization = try await oauth.requestDeviceAuthorization(clientID: clientID)
            pendingAuthorization = authorization
            isWorking = false
            pollingTask = Task { [weak self] in
                await self?.poll(authorization: authorization, clientID: clientID)
            }
        } catch {
            isWorking = false
            errorMessage = safeMessage(for: error)
        }
    }

    func cancelSignIn(clearError: Bool = false) {
        pollingTask?.cancel()
        pollingTask = nil
        pendingAuthorization = nil
        isWorking = false
        if clearError { errorMessage = nil }
    }

    func signOut() {
        cancelSignIn(clearError: true)
        do {
            try credentials.writeToken(nil)
            clearSession()
        } catch {
            errorMessage = safeMessage(for: error)
        }
    }

    func credentialWasInvalidated() {
        cancelSignIn(clearError: true)
        clearSession()
        errorMessage = GitHubOAuthError.invalidCredential.localizedDescription
    }

    private func poll(
        authorization: GitHubDeviceAuthorization,
        clientID: String
    ) async {
        var interval = authorization.interval
        while !Task.isCancelled, now() < authorization.expiresAt {
            do {
                try await sleeper(interval)
                try Task.checkCancellation()
                switch try await oauth.poll(clientID: clientID, deviceCode: authorization.deviceCode) {
                case .pending:
                    continue
                case .slowDown:
                    interval = min(interval + 5, 60)
                case .authorized(let token):
                    let session = try await oauth.validate(token: token)
                    try credentials.writeToken(token)
                    hasStoredCredential = true
                    account = session.account
                    rateLimit = session.rateLimit
                    pendingAuthorization = nil
                    isWorking = false
                    errorMessage = nil
                    pollingTask = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                pendingAuthorization = nil
                isWorking = false
                errorMessage = safeMessage(for: error)
                pollingTask = nil
                return
            }
        }
        guard !Task.isCancelled else { return }
        pendingAuthorization = nil
        isWorking = false
        errorMessage = GitHubOAuthError.authorizationExpired.localizedDescription
        pollingTask = nil
    }

    private func clearSession() {
        hasStoredCredential = false
        account = nil
        rateLimit = nil
    }

    private func safeMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "GitHub sign-in could not be completed."
    }
}
