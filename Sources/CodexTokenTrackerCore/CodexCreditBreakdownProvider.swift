import Foundation
import os

/// Per-model credit *and* token usage for the current calendar month, Codex only.
///
/// The monthly allowance (`CodexMonthlyCreditsProvider`) answers "how much of the 7,000 is left".
/// This answers "what spent it" — the same breakdown the Codex desktop app's usage history draws,
/// from the endpoint its renderer calls:
///
///     GET /backend-api/wham/usage/daily-workspace-user-token-usage-breakdown
///         ?start_date=…&end_date=…&group_by=day&breakdown_by=model&modes=codex
///
/// Each day carries `groups[]`, one per model, with both `credits` and token counts, so credits
/// and tokens come from a single call and are guaranteed to describe the same population.
///
/// `modes=codex` is what restricts this to Codex; dropping it folds in Work and other surfaces
/// (measured 2026-09: 1,755.7 credits Codex-only vs 1,760.2 including Work).
///
/// ## Freshness
///
/// The response carries `data_freshness_ts` and lags the live spend-control figure by hours — on
/// 2026-09-20 the breakdown totalled 1,755.7 credits against a live 1,780.2. The two are not
/// meant to agree to the credit, so the UI labels this as a breakdown rather than restating it as
/// the month's total, and the lag is surfaced rather than hidden.
public enum CodexCreditBreakdownError: Error, LocalizedError, Sendable {
    case unrecognizedResponse

    public var errorDescription: String? {
        switch self {
        case .unrecognizedResponse:
            return "Codex usage breakdown unavailable — unrecognized response."
        }
    }
}

/// One model's share of the month.
public struct CodexModelCreditUsage: Identifiable, Equatable, Sendable {
    public var model: String
    public var credits: Double
    public var totalTokens: Int

    public var id: String { model }

    public init(model: String, credits: Double, totalTokens: Int) {
        self.model = model
        self.credits = credits
        self.totalTokens = totalTokens
    }

    /// Display name: the `gpt-` prefix is noise when every row carries it, and the popover column
    /// is narrow. `gpt-5.6-sol` renders as `5.6-sol`.
    public var shortModel: String {
        var name = model
        if name.hasPrefix("gpt-") {
            name.removeFirst("gpt-".count)
        }
        return name
    }
}

public struct CodexCreditBreakdown: Equatable, Sendable {
    public var models: [CodexModelCreditUsage]
    public var totalCredits: Double
    public var totalTokens: Int
    /// When the server last recomputed these figures, if it said.
    public var dataFreshness: Date?
    public var fetchedAt: Date

    public init(
        models: [CodexModelCreditUsage],
        totalCredits: Double,
        totalTokens: Int,
        dataFreshness: Date?,
        fetchedAt: Date
    ) {
        self.models = models
        self.totalCredits = totalCredits
        self.totalTokens = totalTokens
        self.dataFreshness = dataFreshness
        self.fetchedAt = fetchedAt
    }

    /// Tokens bought per credit — the one number that ties the two units together, and the only
    /// way to see that a cheap-looking model is actually the expensive one per token.
    public var tokensPerCredit: Double? {
        guard totalCredits > 0 else { return nil }
        return Double(totalTokens) / totalCredits
    }
}

public final class CodexCreditBreakdownProvider: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.erstool37.CodexTokenTracker", category: "codex-credit-breakdown")

    private let session: URLSession
    private let authFileURL: URL
    private let stateLock = NSLock()
    private var cached: CodexCreditBreakdown?

    /// The server recomputes this only every few hours, so refetching on every tracker refresh
    /// would spend a 54 KB round trip to receive the same bytes. Half an hour is well inside the
    /// server's own update cadence.
    private let minFetchInterval: TimeInterval = 30 * 60
    /// How long a stale value keeps being shown once refreshes start failing.
    private let cacheGrace: TimeInterval = 24 * 60 * 60

    public init(
        session: URLSession = .shared,
        authFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    ) {
        self.session = session
        self.authFileURL = authFileURL
    }

    /// Returns the breakdown, serving the cache when it is recent enough or when a refresh fails.
    public func fetchSync(now: Date = Date(), calendar: Calendar = .current, timeout: TimeInterval = 20) -> CodexCreditBreakdown? {
        if let cached = stateLock.withLock({ cached }),
           now.timeIntervalSince(cached.fetchedAt) < minFetchInterval {
            return cached
        }

        do {
            let fresh = try performFetchSync(now: now, calendar: calendar, timeout: timeout)
            stateLock.withLock { cached = fresh }
            return fresh
        } catch {
            Self.log.debug("credit breakdown fetch failed: \(error.localizedDescription, privacy: .public)")
            let fallback = stateLock.withLock { cached }
            if let fallback, now.timeIntervalSince(fallback.fetchedAt) <= cacheGrace {
                return fallback
            }
            return nil
        }
    }

    private func performFetchSync(now: Date, calendar: Calendar, timeout: TimeInterval) throws -> CodexCreditBreakdown {
        let auth = try CodexAuthFile.read(from: authFileURL)
        let url = Self.endpoint(now: now, calendar: calendar)
        let request = CodexBackendRequest.make(url: url, auth: auth, timeout: timeout)
        let data = try CodexBackendRequest.performSync(request, session: session)
        guard let parsed = CodexCreditBreakdownMapper.parse(json: data, now: now) else {
            throw CodexCreditBreakdownError.unrecognizedResponse
        }
        return parsed
    }

    /// Month-to-date, Codex only, grouped by model.
    static func endpoint(now: Date, calendar: Calendar) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var components = URLComponents(string: "https://chatgpt.com/backend-api/wham/usage/daily-workspace-user-token-usage-breakdown")!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: monthStart)),
            URLQueryItem(name: "end_date", value: formatter.string(from: now)),
            URLQueryItem(name: "group_by", value: "day"),
            URLQueryItem(name: "breakdown_by", value: "model"),
            URLQueryItem(name: "modes", value: "codex"),
        ]
        return components.url!
    }

    /// Testing seam.
    public static func endpointForTesting(now: Date, calendar: Calendar) -> URL {
        endpoint(now: now, calendar: calendar)
    }
}

// MARK: - Mapping

public enum CodexCreditBreakdownMapper {
    /// Defensive DTO: every field optional so a renamed key degrades to "unavailable".
    private struct DTO: Decodable {
        struct Day: Decodable {
            struct Group: Decodable {
                struct Dimensions: Decodable {
                    let model: String?
                }
                let dimensions: Dimensions?
                let credits: Double?
                let text_total_tokens: Int?
            }
            let groups: [Group]?
        }
        let data: [Day]?
        let data_freshness_ts: String?
    }

    public static func parse(json data: Data, now: Date) -> CodexCreditBreakdown? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), let days = dto.data else {
            return nil
        }

        var creditsByModel: [String: Double] = [:]
        var tokensByModel: [String: Int] = [:]
        for day in days {
            for group in day.groups ?? [] {
                guard let model = group.dimensions?.model, !model.isEmpty else { continue }
                creditsByModel[model, default: 0] += group.credits ?? 0
                tokensByModel[model, default: 0] += group.text_total_tokens ?? 0
            }
        }

        // Models that neither spent a credit nor moved a token say nothing; drop them so the
        // narrow popover column is spent on rows that mean something.
        let models = Set(creditsByModel.keys).union(tokensByModel.keys)
            .map { model in
                CodexModelCreditUsage(
                    model: model,
                    credits: creditsByModel[model] ?? 0,
                    totalTokens: tokensByModel[model] ?? 0
                )
            }
            .filter { $0.credits > 0 || $0.totalTokens > 0 }
            // Credits are the scarce resource, so they order the list; tokens break ties.
            .sorted { lhs, rhs in
                if lhs.credits != rhs.credits { return lhs.credits > rhs.credits }
                return lhs.totalTokens > rhs.totalTokens
            }

        guard !models.isEmpty else {
            return nil
        }

        return CodexCreditBreakdown(
            models: models,
            totalCredits: models.reduce(0) { $0 + $1.credits },
            totalTokens: models.reduce(0) { $0 + $1.totalTokens },
            dataFreshness: dto.data_freshness_ts.flatMap(parseTimestamp),
            fetchedAt: now
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// "1,756 credits · 266M tokens" — the pair, stated once, under the per-model rows.
    public static func summaryText(_ breakdown: CodexCreditBreakdown) -> String {
        "\(creditsText(breakdown.totalCredits)) credits · \(StatusFormatter.compactTokenCount(breakdown.totalTokens)) tokens"
    }

    /// "151K tokens per credit" — how much a credit buys, across the month.
    public static func efficiencyText(_ breakdown: CodexCreditBreakdown) -> String? {
        guard let perCredit = breakdown.tokensPerCredit, perCredit.isFinite, perCredit > 0 else {
            return nil
        }
        return "\(StatusFormatter.compactTokenCount(Int(perCredit.rounded()))) tokens per credit"
    }

    /// Credits carry fractions but the popover has no room for them; whole credits, grouped.
    public static func creditsText(_ credits: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = credits < 10 ? 1 : 0
        return formatter.string(from: NSNumber(value: credits)) ?? "\(Int(credits.rounded()))"
    }
}
