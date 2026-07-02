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
///
/// ## Why this shells out to `/usr/bin/security` instead of `SecItemCopyMatching`
///
/// Claude Code restricts the item's decrypt ACL to a trusted-application list and a
/// code-partition list. A non-trusted app that calls `SecItemCopyMatching` directly
/// triggers the "… wants to use confidential information" prompt; clicking *Always
/// Allow* pins the requesting app by its **cdhash**, which changes on every rebuild —
/// so each new build of this app re-prompts. That is the "asks every time" symptom.
///
/// `/usr/bin/security` is Apple-signed and lives in the stable `apple-tool:` partition;
/// once it is in the item's trusted list it stays authorized regardless of how often
/// *this* app is rebuilt. Reading through it therefore decouples our access from our
/// own (per-build) code identity and stops the repeated prompts. The secret is returned
/// on `security`'s stdout, never via argv, so it is not exposed in the process list.
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
        let data = try copySecret(account: account)

        guard
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            let token = stored.claudeAiOauth?.accessToken,
            !token.isEmpty
        else {
            throw ClaudeKeychainError.malformedSecret
        }

        return Token(accessToken: token, expiresAtMillis: stored.claudeAiOauth?.expiresAt)
    }

    /// Invokes `/usr/bin/security find-generic-password -w` and returns the raw secret bytes.
    /// Maps the tool's exit code back onto the same error space the direct API used so callers
    /// (and their UI strings) are unchanged.
    private static func copySecret(account: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w", // print only the password (secret) to stdout
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ClaudeKeychainError.keychainStatus(errSecInternalComponent)
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        stderr.fileHandleForReading.readDataToEndOfFile() // drain to avoid a full-pipe stall
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            // `security -w` appends a trailing newline; trim it before JSON decoding.
            let trimmed = String(data: outData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, let bytes = trimmed.data(using: .utf8) else {
                throw ClaudeKeychainError.malformedSecret
            }
            return bytes
        case 44: // errSecItemNotFound — no credential item exists
            throw ClaudeKeychainError.notSignedIn
        case let code:
            throw ClaudeKeychainError.keychainStatus(OSStatus(code))
        }
    }
}
