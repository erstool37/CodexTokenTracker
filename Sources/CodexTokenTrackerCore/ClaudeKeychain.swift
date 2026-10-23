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
/// A Claude Code started with `CLAUDE_CONFIG_DIR` keeps a separate login under
/// `"Claude Code-credentials-<first 8 hex of sha256(config dir)>"`, so one Mac can hold a team
/// and a personal login at once. `credentialServices()` finds all of them.
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
    public static let defaultService = "Claude Code-credentials"

    private struct Stored: Decodable {
        struct OAuth: Decodable {
            let accessToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth?
    }

    public struct Token: Sendable {
        public let accessToken: String
        public let expiresAtMillis: Double?
        /// Plan of the signed-in organization as Claude Code records it ("team", "max", "pro", …).
        public let subscriptionType: String?
    }

    public static func readAccessToken(
        service: String = defaultService,
        account: String = NSUserName()
    ) throws -> Token {
        let data = try copySecret(service: service, account: account)

        guard
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            let token = stored.claudeAiOauth?.accessToken,
            !token.isEmpty
        else {
            throw ClaudeKeychainError.malformedSecret
        }

        return Token(
            accessToken: token,
            expiresAtMillis: stored.claudeAiOauth?.expiresAt,
            subscriptionType: stored.claudeAiOauth?.subscriptionType
        )
    }

    /// Every Claude Code login on this Mac: the default item plus one per `CLAUDE_CONFIG_DIR`.
    /// Reads only item attributes (`security dump-keychain` without `-d`), never secrets, so it
    /// does not prompt. Falls back to the default service when the listing fails.
    public static func credentialServices() -> [String] {
        guard let output = runSecurity(["dump-keychain"]).flatMap({ String(data: $0.stdout, encoding: .utf8) }) else {
            return [defaultService]
        }
        let services = parseCredentialServices(fromKeychainDump: output)
        return services.isEmpty ? [defaultService] : services
    }

    /// Pull Claude Code credential service names out of `security dump-keychain` output.
    public static func parseCredentialServices(fromKeychainDump dump: String) -> [String] {
        let pattern = #""svce"<blob>="(Claude Code-credentials(?:-[0-9a-f]{8})?)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(dump.startIndex..., in: dump)
        var seen = Set<String>()
        var services: [String] = []
        for match in regex.matches(in: dump, range: range) {
            guard let serviceRange = Range(match.range(at: 1), in: dump) else { continue }
            let service = String(dump[serviceRange])
            if seen.insert(service).inserted {
                services.append(service)
            }
        }
        // Default login first, then the per-config-dir ones in a stable order.
        return services.sorted { lhs, rhs in
            if lhs == defaultService { return true }
            if rhs == defaultService { return false }
            return lhs < rhs
        }
    }

    /// Invokes `/usr/bin/security find-generic-password -w` and returns the raw secret bytes.
    /// Maps the tool's exit code back onto the same error space the direct API used so callers
    /// (and their UI strings) are unchanged.
    private static func copySecret(service: String, account: String) throws -> Data {
        guard let result = runSecurity([
            "find-generic-password",
            "-s", service,
            "-a", account,
            "-w", // print only the password (secret) to stdout
        ]) else {
            throw ClaudeKeychainError.keychainStatus(errSecInternalComponent)
        }

        switch result.status {
        case 0:
            // `security -w` appends a trailing newline; trim it before JSON decoding.
            let trimmed = String(data: result.stdout, encoding: .utf8)?
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

    private static func runSecurity(_ arguments: [String]) -> (stdout: Data, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        stderr.fileHandleForReading.readDataToEndOfFile() // drain to avoid a full-pipe stall
        process.waitUntilExit()
        return (outData, process.terminationStatus)
    }
}
