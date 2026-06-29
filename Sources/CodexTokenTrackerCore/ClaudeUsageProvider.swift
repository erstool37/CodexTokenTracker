import Foundation
import os

public enum ClaudeUsageError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case emptyShape(body: String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, _):
            if status == 401 || status == 403 {
                return "Claude session expired — open Claude Code to refresh."
            }
            return "Anthropic API error (HTTP \(status))"
        case .emptyShape:
            return "Unrecognized usage response"
        }
    }
}

/// Fetches live Claude usage from the Anthropic OAuth usage endpoint and maps it onto the
/// shared `CodexStatusSnapshot` model so the popover can render it with the same views the
/// Codex pane uses. There is no local fallback — this is API-only by design.
public final class ClaudeUsageProvider: StatusProviding, @unchecked Sendable {
    private static let log = Logger(
        subsystem: "com.erstool37.CodexTokenTracker",
        category: "ClaudeUsage"
    )
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchStatus() async throws -> CodexStatusSnapshot {
        let token = try ClaudeKeychain.readAccessToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        // Headers sent defensively; the exact set is verified against a live response.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("CodexTokenTracker/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        // Log the raw payload at debug level (stream-only) for future troubleshooting; visible via
        // `log stream --predicate 'subsystem == "com.erstool37.CodexTokenTracker"' --level debug`
        // or Console.app with debug messages enabled.
        Self.log.debug("claude usage raw: \(body, privacy: .public)")

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClaudeUsageError.http(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ClaudeUsageDTO.self, from: data)
        let now = Date()
        var snapshot = ClaudeUsageMapper.snapshot(from: decoded, now: now)

        // Aggregate local Claude Code transcripts and surface as the usage card.
        let claudeLocalStats = ClaudeTokenUsageProvider.load(now: now)
        snapshot.onlineTokenStats = claudeLocalStats

        if snapshot.limits.isEmpty {
            throw ClaudeUsageError.emptyShape(body: body)
        }
        return snapshot
    }
}

// MARK: - Defensive DTOs

/// Every field is optional so a renamed/missing key yields `nil` rather than a decode failure.
struct ClaudeUsageDTO: Decodable {
    let five_hour: ClaudeWindowDTO?
    let seven_day: ClaudeWindowDTO?
    let seven_day_opus: ClaudeWindowDTO?
    let seven_day_sonnet: ClaudeWindowDTO?
    let used_credits: Double?
    let monthly_credit_limit: Double?
    let balance: Double?
}

struct ClaudeWindowDTO: Decodable {
    let utilization: Double?
    let used_percentage: Double?
    let resets_at: ResetsAt?
}

/// `resets_at` may arrive as an ISO-8601 string or as an epoch number (seconds or ms).
enum ResetsAt: Decodable {
    case string(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    func secondsSince1970() -> TimeInterval? {
        switch self {
        case let .number(value):
            // Numbers above ~year 2255 in seconds are really milliseconds.
            return value > 9_000_000_000 ? value / 1000 : value
        case let .string(value):
            let formatter = ISO8601DateFormatter()
            // Try 3-digit millisecond fractional formatter first.
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date.timeIntervalSince1970
            }
            // The API returns 6-digit microseconds (e.g. "...59.913692+00:00") which
            // ISO8601DateFormatter does not handle. Strip the fractional part and retry.
            let stripped = value.replacingOccurrences(
                of: #"\.\d+"#,
                with: "",
                options: .regularExpression
            )
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: stripped)?.timeIntervalSince1970
        }
    }
}

// MARK: - Mapping to the shared display model

enum ClaudeUsageMapper {
    static func snapshot(from dto: ClaudeUsageDTO, now: Date) -> CodexStatusSnapshot {
        var windows: [LimitWindowDisplay] = []

        func add(_ window: ClaudeWindowDTO?, id: String, label: String) {
            guard let window else { return }
            // Prefer an explicit 0–100 percentage; otherwise use utilization directly (0–100 scale).
            let usedPercent: Double
            if let percentage = window.used_percentage {
                usedPercent = percentage
            } else if let utilization = window.utilization {
                usedPercent = utilization
            } else {
                return
            }

            windows.append(
                LimitWindowDisplay(
                    id: id,
                    label: label,
                    percentUsed: usedPercent,
                    percentLeft: StatusFormatter.percentLeft(from: usedPercent),
                    resetsAtText: StatusFormatter.resetText(
                        secondsSince1970: window.resets_at?.secondsSince1970(),
                        now: now
                    ),
                    showsNumericUsage: true
                )
            )
        }

        add(dto.five_hour, id: "claude-5h", label: "5h limit")
        add(dto.seven_day, id: "claude-7d", label: "Weekly limit")
        add(dto.seven_day_opus, id: "claude-7d-opus", label: "7d Opus")
        add(dto.seven_day_sonnet, id: "claude-7d-sonnet", label: "7d Sonnet")

        let creditsText: String?
        if let used = dto.used_credits, let limit = dto.monthly_credit_limit, limit > 0 {
            creditsText = "\(Int(used.rounded()))/\(Int(limit.rounded())) credits"
        } else if let balance = dto.balance {
            creditsText = "\(Int(balance.rounded())) credits"
        } else {
            creditsText = nil
        }

        let limits: [LimitBucketDisplay]
        if windows.isEmpty && creditsText == nil {
            limits = []
        } else {
            limits = [
                LimitBucketDisplay(
                    id: "claude",
                    label: "Claude",
                    windows: windows,
                    creditsText: creditsText
                )
            ]
        }

        return CodexStatusSnapshot(
            account: AccountDisplay(
                kind: "Claude",
                email: nil,
                plan: nil,
                requiresOpenAIAuth: false
            ),
            limits: limits,
            refreshedAt: now,
            source: "anthropic oauth usage"
        )
    }
}
