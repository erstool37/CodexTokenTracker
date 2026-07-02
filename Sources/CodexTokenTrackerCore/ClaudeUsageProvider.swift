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
///
/// The Anthropic OAuth usage endpoint is self-describing via the `limits[]` array: each entry
/// carries its own `kind`/`group`/`scope`, so newly introduced windows (e.g. a per-model weekly
/// "Fable" limit) appear automatically without an app change. We prefer that array and keep the
/// legacy top-level named fields (`five_hour`, `seven_day`, …) only as a fallback for older
/// API/app versions that still emit them.
struct ClaudeUsageDTO: Decodable {
    // Adaptive, forward-looking source of truth.
    let limits: [ClaudeLimitDTO]?
    let spend: ClaudeSpendDTO?
    let extra_usage: ClaudeExtraUsageDTO?

    // Legacy fallback (deprecated by the `limits[]` array).
    let five_hour: ClaudeWindowDTO?
    let seven_day: ClaudeWindowDTO?
    let seven_day_opus: ClaudeWindowDTO?
    let seven_day_sonnet: ClaudeWindowDTO?
    let used_credits: Double?
    let monthly_credit_limit: Double?
    let balance: Double?
}

/// One entry of the adaptive `limits[]` array. All optional so an unknown shape degrades to nil.
struct ClaudeLimitDTO: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let utilization: Double?
    let used_percentage: Double?
    let severity: String?
    let is_active: Bool?
    let resets_at: ResetsAt?
    let scope: ClaudeScopeDTO?

    /// Best available 0–100 used-percentage, normalizing a 0–1 `utilization` if that's all we get.
    var usedPercent: Double? {
        if let percent { return percent }
        if let used_percentage { return used_percentage }
        if let utilization { return utilization <= 1 ? utilization * 100 : utilization }
        return nil
    }
}

/// `scope` narrows a limit to a specific model (and possibly surface). We only need the model's
/// display name for labeling; other keys are ignored so their shape can change freely.
struct ClaudeScopeDTO: Decodable {
    let model: ClaudeModelRefDTO?
}

struct ClaudeModelRefDTO: Decodable {
    let id: String?
    let display_name: String?
}

/// Pay-as-you-go usage credits that cover overage past plan limits.
struct ClaudeExtraUsageDTO: Decodable {
    let is_enabled: Bool?
    let monthly_limit: Double?
    let used_credits: Double?
    let utilization: Double?
    let currency: String?
}

/// Money spend against an optional cap. Amounts arrive as minor units with an exponent.
struct ClaudeSpendDTO: Decodable {
    let used: ClaudeMoneyDTO?
    let limit: ClaudeMoneyDTO?
    let balance: ClaudeMoneyDTO?
    let enabled: Bool?
}

struct ClaudeMoneyDTO: Decodable {
    let amount_minor: Double?
    let currency: String?
    let exponent: Int?

    /// Major-unit value (e.g. dollars) derived from minor units and the exponent.
    var majorAmount: Double? {
        guard let amount_minor else { return nil }
        let exp = exponent ?? 2
        return amount_minor / pow(10, Double(exp))
    }
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

public enum ClaudeUsageMapper {
    /// Decode a raw Anthropic usage payload and map it to the shared snapshot. Exposed so the
    /// check suite can exercise the adaptive mapping end-to-end against real payloads.
    public static func snapshot(fromJSON data: Data, now: Date) throws -> CodexStatusSnapshot {
        let dto = try JSONDecoder().decode(ClaudeUsageDTO.self, from: data)
        return snapshot(from: dto, now: now)
    }

    static func snapshot(from dto: ClaudeUsageDTO, now: Date) -> CodexStatusSnapshot {
        // Prefer the adaptive `limits[]` array; only fall back to legacy named fields when it's
        // absent or empty. This is what lets new windows (e.g. Fable) appear with no code change.
        var windows = adaptiveWindows(from: dto.limits, now: now)
        if windows.isEmpty {
            windows = legacyWindows(from: dto, now: now)
        }

        let creditsText = creditsText(from: dto)

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

    // MARK: Adaptive windows (preferred)

    /// Map every entry of the self-describing `limits[]` array to a display window. Entries with
    /// no usable percentage are skipped; everything else renders, including limits this build has
    /// never seen before. Order is preserved so the API's own ordering drives the UI.
    private static func adaptiveWindows(from limits: [ClaudeLimitDTO]?, now: Date) -> [LimitWindowDisplay] {
        guard let limits else { return [] }
        return limits.enumerated().compactMap { index, limit in
            guard let usedPercent = limit.usedPercent else { return nil }
            let model = limit.scope?.model?.display_name
            let idParts = ["claude", limit.kind ?? limit.group, model]
                .compactMap { $0 }
                .map { $0.replacingOccurrences(of: " ", with: "-").lowercased() }
            let id = (idParts + ["\(index)"]).joined(separator: "-")
            return LimitWindowDisplay(
                id: id,
                label: AdaptiveLabel.claudeWindowLabel(kind: limit.kind, group: limit.group, model: model),
                percentUsed: usedPercent,
                percentLeft: StatusFormatter.percentLeft(from: usedPercent),
                resetsAtText: StatusFormatter.resetText(
                    secondsSince1970: limit.resets_at?.secondsSince1970(),
                    now: now
                ),
                showsNumericUsage: true
            )
        }
    }

    // MARK: Legacy windows (fallback)

    /// Fallback for older API/app versions that still emit the fixed top-level window fields.
    private static func legacyWindows(from dto: ClaudeUsageDTO, now: Date) -> [LimitWindowDisplay] {
        var windows: [LimitWindowDisplay] = []

        func add(_ window: ClaudeWindowDTO?, id: String, label: String) {
            guard let window else { return }
            let usedPercent: Double
            if let percentage = window.used_percentage {
                usedPercent = percentage
            } else if let utilization = window.utilization {
                usedPercent = utilization <= 1 ? utilization * 100 : utilization
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
        return windows
    }

    // MARK: Credits

    /// A single credits/spend line, preferring the current shapes (`extra_usage`, then `spend`)
    /// and falling back to the legacy flat fields.
    private static func creditsText(from dto: ClaudeUsageDTO) -> String? {
        if let extra = dto.extra_usage, extra.is_enabled == true {
            if let used = extra.used_credits, let limit = extra.monthly_limit, limit > 0 {
                return "\(Int(used.rounded()))/\(Int(limit.rounded())) credits"
            }
        }

        if let spend = dto.spend, spend.enabled == true {
            if let limit = spend.limit?.majorAmount, limit > 0 {
                let used = spend.used?.majorAmount ?? 0
                return String(format: "$%.2f/$%.2f", used, limit)
            }
            if let balance = spend.balance?.majorAmount {
                return String(format: "$%.2f left", balance)
            }
        }

        if let used = dto.used_credits, let limit = dto.monthly_credit_limit, limit > 0 {
            return "\(Int(used.rounded()))/\(Int(limit.rounded())) credits"
        }
        if let balance = dto.balance {
            return "\(Int(balance.rounded())) credits"
        }
        return nil
    }
}
