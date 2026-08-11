import Foundation
import Security

enum GitHubCredentialError: LocalizedError, Equatable {
    case invalidToken
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "GitHub returned an invalid credential."
        case .keychain:
            return "The GitHub credential could not be stored securely."
        }
    }
}

protocol GitHubCredentialStoring: Sendable {
    func readToken() throws -> String?
    func writeToken(_ token: String?) throws
}

/// Stores the OAuth access token only in the device-local iOS Keychain.
///
/// `AfterFirstUnlockThisDeviceOnly` keeps background update checks working after
/// the user has unlocked the phone once, while preventing the item from migrating
/// to another device through a backup.
final class KeychainGitHubCredentialStore: GitHubCredentialStoring, @unchecked Sendable {
    static let shared = KeychainGitHubCredentialStore()

    private let service: String
    private let account: String

    init(
        service: String = "com.tumoflip.unleashedcompanion.github",
        account: String = "oauth-access-token"
    ) {
        self.service = service
        self.account = account
    }

    func readToken() throws -> String? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw GitHubCredentialError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              Self.isValid(token: token) else {
            throw GitHubCredentialError.invalidToken
        }
        return token
    }

    func writeToken(_ token: String?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard let token else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw GitHubCredentialError.keychain(status)
            }
            return
        }
        guard Self.isValid(token: token) else {
            throw GitHubCredentialError.invalidToken
        }

        let value = Data(token.utf8)
        let update: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GitHubCredentialError.keychain(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GitHubCredentialError.keychain(addStatus)
        }
    }

    static func isValid(token: String) -> Bool {
        let bytes = token.utf8
        guard !bytes.isEmpty, bytes.count <= 512 else { return false }
        return bytes.allSatisfy { $0 > 0x20 && $0 < 0x7f }
    }
}

extension Notification.Name {
    static let githubCredentialInvalidated = Notification.Name(
        "com.tumoflip.unleashedcompanion.github-credential-invalidated"
    )
}
