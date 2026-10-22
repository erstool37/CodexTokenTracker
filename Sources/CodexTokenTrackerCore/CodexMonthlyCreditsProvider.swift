import Foundation
import os

/// The Codex monthly credit allowance for a workspace (Edu / Business) account.
///
/// ## Where this number comes from
///
/// Neither the app-server (`account/rateLimits/read`) nor `backend-api/codex/usage` reports a
/// credit balance — both return `credits.balance: null` for a workspace member, and every one of
/// 10,362 rate-limit snapshots recorded in local session logs agrees. The figure the Codex
/// desktop app shows under *Settings → Usage → Monthly usage* comes from a different call, found
/// by reading that app's renderer bundle:
///
///     GET /backend-api/accounts/{account_id}/spend-controls/current-user/monthly-usage
///         ?supports_usage_limit_modes=true
///
/// which answers, for this account on 2026-09-20:
///
///     {"balance_unit":"credit",
///      "effective_monthly_limit":{"limit":7000,"enforcement_mode":"HARD_CAP","limit_mode":"amount_credits"},
///      "current_month_usage":1780.1994230747223}
///
/// The desktop app polls it every minute with `Cache-Control: no-store`; this provider is called
/// once per tracker refresh, which is plenty for a menu-bar widget.
///
/// ## Transport
///
/// `chatgpt.com/backend-api` sits behind a Cloudflare check that rejects curl's TLS fingerprint
/// with a 403 but accepts Apple's stack, so `URLSession` works where a shell probe does not. The
/// request is authenticated with the Codex CLI's own OAuth token from `~/.codex/auth.json`; the
/// CLI keeps that file fresh, and a stale token surfaces here as a 401 that is reported, not
/// retried in a loop.
public enum CodexMonthlyCreditsError: Error, LocalizedError, Sendable {
    case notSignedIn
    case http(status: Int)
    case unrecognizedResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Codex monthly credits unavailable — run `codex login`."
        case let .http(status):
            if status == 401 || status == 403 {
                return "Codex monthly credits unavailable — Codex sign-in expired, open codex to refresh."
            }
            return "Codex monthly credits unavailable (HTTP \(status))."
        case .unrecognizedResponse:
            return "Codex monthly credits unavailable — unrecognized response."
        }
    }
}

/// The parsed allowance. `limit` is in `balanceUnit` (credits for every plan seen so far).
public struct CodexMonthlyCredits: Equatable, Sendable {
    public var balanceUnit: String
    public var limit: Double
    public var used: Double
    public var enforcementMode: String?
    public var fetchedAt: Date

    public init(balanceUnit: String, limit: Double, used: Double, enforcementMode: String?, fetchedAt: Date) {
        self.balanceUnit = balanceUnit
        self.limit = limit
        self.used = used
        self.enforcementMode = enforcementMode
        self.fetchedAt = fetchedAt
    }

    public var percentUsed: Double {
        guard limit > 0 else { return 100 }
        return min(max(used / limit * 100, 0), 100)
    }
}

public final class CodexMonthlyCreditsProvider: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.erstool37.CodexTokenTracker", category: "codex-monthly-credits")

    private let session: URLSession
    private let authFileURL: URL
    private let stateLock = NSLock()
    private var cached: CodexMonthlyCredits?

    /// How long a previously fetched value is still shown when a refresh fails. Long enough to
    /// ride out a token refresh or a flaky network; short enough that a genuinely broken sign-in
    /// eventually reads as unavailable rather than as a frozen number.
    private let cacheGrace: TimeInterval = 6 * 60 * 60

    public init(
        session: URLSession = .shared,
        authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) {
        self.session = session
        self.authFileURL = authFileURL
    }

    // MARK: - Fetching

    /// Synchronous fetch for callers that are already off the main thread (the app-server
    /// provider assembles its snapshot inside a detached task). On failure the last good value is
    /// returned while it is inside the grace window, and the error is surfaced alongside it so
    /// the UI can mark the number stale.
    public func fetchSync(now: Date = Date(), timeout: TimeInterval = 15) -> (credits: CodexMonthlyCredits?, error: Error?) {
        do {
            let fresh = try performFetchSync(now: now, timeout: timeout)
            stateLock.withLock { cached = fresh }
            return (fresh, nil)
        } catch {
            Self.log.debug("monthly credits fetch failed: \(error.localizedDescription, privacy: .public)")
            let fallback = stateLock.withLock { cached }
            if let fallback, now.timeIntervalSince(fallback.fetchedAt) <= cacheGrace {
                return (fallback, error)
            }
            return (nil, error)
        }
    }

    private func performFetchSync(now: Date, timeout: TimeInterval) throws -> CodexMonthlyCredits {
        let auth = try CodexAuthFile.read(from: authFileURL)
        let request = CodexBackendRequest.make(
            url: Self.endpoint(accountID: auth.accountID),
            auth: auth,
            timeout: timeout
        )
        let data = try CodexBackendRequest.performSync(request, session: session)
        guard let parsed = CodexMonthlyCreditsMapper.parse(json: data, now: now) else {
            throw CodexMonthlyCreditsError.unrecognizedResponse
        }
        return parsed
    }

    /// Testing seam so the check suite can pin the URL to the one the desktop app calls.
    public static func endpointForTesting(accountID: String) -> URL {
        endpoint(accountID: accountID)
    }

    static func endpoint(accountID: String) -> URL {
        var components = URLComponents(string: "https://chatgpt.com/backend-api/accounts/\(accountID)/spend-controls/current-user/monthly-usage")!
        components.queryItems = [URLQueryItem(name: "supports_usage_limit_modes", value: "true")]
        return components.url!
    }
}

// MARK: - Auth file

/// The Codex CLI's `~/.codex/auth.json`. Only the two fields this provider needs are read; the
/// refresh token is deliberately not touched — refreshing is the CLI's job.
enum CodexAuthFile {
    struct Credentials {
        let accessToken: String
        let accountID: String
    }

    private struct Stored: Decodable {
        struct Tokens: Decodable {
            let access_token: String?
            let account_id: String?
        }
        let tokens: Tokens?
    }

    static func read(from url: URL) throws -> Credentials {
        guard let data = try? Data(contentsOf: url) else {
            throw CodexMonthlyCreditsError.notSignedIn
        }
        guard
            let stored = try? JSONDecoder().decode(Stored.self, from: data),
            let token = stored.tokens?.access_token, !token.isEmpty,
            let account = stored.tokens?.account_id, !account.isEmpty
        else {
            throw CodexMonthlyCreditsError.notSignedIn
        }
        return Credentials(accessToken: token, accountID: account)
    }
}

// MARK: - Mapping

public enum CodexMonthlyCreditsMapper {
    /// Defensive DTO: every field optional, so a renamed key degrades to "unavailable" rather
    /// than a decode failure.
    private struct DTO: Decodable {
        struct Limit: Decodable {
            struct Amount: Decodable {
                let amount: Double?
                let unit: String?
            }
            let limit: Double?
            let limit_amount: Amount?
            let enforcement_mode: String?
            let limit_mode: String?
        }
        let balance_unit: String?
        let effective_monthly_limit: Limit?
        let current_month_usage: Double?
    }

    /// Parse the raw endpoint payload. Returns nil when there is no enforceable monthly limit —
    /// `limit_mode: unlimited_platform_max`, or no limit figure at all — mirroring the desktop
    /// app, which hides its monthly panel in exactly those cases.
    public static func parse(json data: Data, now: Date) -> CodexMonthlyCredits? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return nil
        }
        guard let limitInfo = dto.effective_monthly_limit,
              limitInfo.limit_mode != "unlimited_platform_max" else {
            return nil
        }
        let unit = dto.balance_unit ?? "credit"
        // Prefer a typed amount whose unit matches the account's balance unit, then the plain
        // `limit` — the same precedence the desktop renderer applies.
        let limit: Double?
        if let amount = limitInfo.limit_amount, amount.unit == unit, let value = amount.amount {
            limit = value
        } else {
            limit = limitInfo.limit
        }
        guard let limit, limit >= 0, let used = dto.current_month_usage else {
            return nil
        }
        return CodexMonthlyCredits(
            balanceUnit: unit,
            limit: limit,
            used: used,
            enforcementMode: limitInfo.enforcement_mode,
            fetchedAt: now
        )
    }

    /// The display bucket for the Codex pane: one "Monthly credits" window driving the bar and
    /// the menu-bar warning tint, plus a "used / limit" credits line.
    public static func bucket(
        from credits: CodexMonthlyCredits,
        now: Date,
        calendar: Calendar = .current,
        stale: Bool = false
    ) -> LimitBucketDisplay {
        let percentUsed = credits.percentUsed
        let window = LimitWindowDisplay(
            id: "codex-monthly-credits",
            label: "Monthly credits",
            percentUsed: percentUsed,
            percentLeft: StatusFormatter.percentLeft(from: percentUsed),
            resetsAtText: StatusFormatter.resetText(
                secondsSince1970: startOfNextMonth(after: now, calendar: calendar)?.timeIntervalSince1970,
                now: now,
                calendar: calendar
            ),
            showsNumericUsage: true
        )
        return LimitBucketDisplay(
            id: "codex",
            label: "Codex",
            windows: [window],
            creditsText: creditsText(credits),
            statusText: stale ? "Showing last known credits" : nil
        )
    }

    /// Merge the monthly-credits bucket into the app-server's buckets: if a "codex" bucket
    /// already exists (it does whenever the API reports a visible window or a credit balance),
    /// the monthly window joins it; otherwise the bucket is added at the front.
    public static func merge(_ monthly: LimitBucketDisplay, into buckets: [LimitBucketDisplay]) -> [LimitBucketDisplay] {
        var result = buckets
        if let index = result.firstIndex(where: { $0.id == monthly.id }) {
            var existing = result[index]
            existing.windows = monthly.windows + existing.windows.filter { window in
                !monthly.windows.contains { $0.id == window.id }
            }
            existing.creditsText = monthly.creditsText ?? existing.creditsText
            existing.statusText = existing.statusText ?? monthly.statusText
            result[index] = existing
        } else {
            result.insert(monthly, at: 0)
        }
        return result
    }

    static func creditsText(_ credits: CodexMonthlyCredits) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let used = formatter.string(from: NSNumber(value: credits.used.rounded())) ?? "\(Int(credits.used.rounded()))"
        let limit = formatter.string(from: NSNumber(value: credits.limit.rounded())) ?? "\(Int(credits.limit.rounded()))"
        let unit = credits.balanceUnit == "usd" ? "USD" : "credits"
        return "\(used) / \(limit) \(unit)"
    }

    /// Monthly allowances reset on the 1st; the endpoint does not report a reset time itself.
    static func startOfNextMonth(after date: Date, calendar: Calendar) -> Date? {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else {
            return nil
        }
        return calendar.date(byAdding: .month, value: 1, to: monthStart)
    }
}
