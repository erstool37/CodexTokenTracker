import Foundation
import Security

public enum ClaudeKeychainError: Error, LocalizedError, Sendable {
    /// No credential item in the keychain — the user has not signed in to Claude Code.
    case notSignedIn
    /// An item exists but the stored JSON had no usable access token.
    case malformedSecret
    /// Any other Keychain failure (including a user-denied access prompt).
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Claude Code"
        case .malformedSecret:
            return "Claude credentials are unreadable"
        case let .keychainStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

/// Reads the Claude Code OAuth access token from the macOS Keychain.
///
/// Claude Code stores its credentials as a generic password whose service is
/// `"Claude Code-credentials"` and whose account is the macOS short username. The
/// secret is a JSON blob of the shape `{"claudeAiOauth":{"accessToken":"…","expiresAt":<ms>,…}}`.
public enum ClaudeKeychain {
    private static let service = "Claude Code-credentials"

    private struct Stored: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
        }
        let claudeAiOauth: OAuth?
    }

    public struct Token: Sendable {
        public let accessToken: String
        public let expiresAtMillis: Double?
    }

    public static func readAccessToken(account: String = NSUserName()) throws -> Token {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw ClaudeKeychainError.notSignedIn
        default:
            throw ClaudeKeychainError.keychainStatus(status)
        }

        guard
            let data = item as? Data,
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            let token = stored.claudeAiOauth?.accessToken,
            !token.isEmpty
        else {
            throw ClaudeKeychainError.malformedSecret
        }

        return Token(accessToken: token, expiresAtMillis: stored.claudeAiOauth?.expiresAt)
    }
}
