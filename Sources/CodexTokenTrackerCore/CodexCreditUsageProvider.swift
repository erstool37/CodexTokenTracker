import Foundation
import os

/// Codex credit spend for today, the last 7 days, and the calendar month.
///
/// The allowance (`CodexMonthlyCreditsProvider`) answers "how much of the 7,000 is left". This
/// answers "how fast am I spending it", from the endpoint the Codex desktop app's usage history
/// calls:
///
///     GET /backend-api/wham/usage/daily-workspace-user-token-usage-breakdown
///         ?start_date=…&end_date=…&group_by=day&modes=codex
///
/// `modes=codex` is what restricts this to Codex; dropping it folds in Work and other surfaces
/// (measured 2026-09: 1,755.7 credits Codex-only vs 1,760.2 including Work).
///
/// ## Freshness
///
/// The response carries `data_freshness_ts` and lags the live spend-control figure by hours — on
/// 2026-09-20 this totalled 1,755.7 credits against a live 1,780.2. Today's row is therefore a
/// partial count, which is why the card labels the source rather than presenting these as the
/// authoritative month total; the allowance window above it is the live number.
public enum CodexCreditUsageError: Error, LocalizedError, Sendable {
    case unrecognizedResponse

    public var errorDescription: String? {
        switch self {
        case .unrecognizedResponse:
            return "Codex credit usage unavailable — unrecognized response."
        }
    }
}

public struct CodexCreditUsage: Equatable, Sendable {
    public var today: Double
    public var sevenDays: Double
    public var thisMonth: Double
    /// When the server last recomputed these figures, if it said.
    public var dataFreshness: Date?
    public var fetchedAt: Date

    public init(
        today: Double,
        sevenDays: Double,
        thisMonth: Double,
        dataFreshness: Date?,
        fetchedAt: Date
    ) {
        self.today = today
        self.sevenDays = sevenDays
        self.thisMonth = thisMonth
        self.dataFreshness = dataFreshness
        self.fetchedAt = fetchedAt
    }

    /// The three rows in display order.
    public var periods: [(label: String, credits: Double)] {
        [("Today", today), ("7 days", sevenDays), ("This month", thisMonth)]
    }
}

public final class CodexCreditUsageProvider: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.erstool37.CodexTokenTracker", category: "codex-credit-usage")

    private let session: URLSession
    private let authFileURL: URL
    private let stateLock = NSLock()
    private var cached: CodexCreditUsage?

    /// The server recomputes this only every few hours, so refetching on every tracker refresh
    /// would spend a round trip to receive the same bytes.
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

    /// Returns the usage, serving the cache when it is recent enough or when a refresh fails.
    public func fetchSync(now: Date = Date(), timeout: TimeInterval = 20) -> CodexCreditUsage? {
        if let cached = stateLock.withLock({ cached }),
           now.timeIntervalSince(cached.fetchedAt) < minFetchInterval {
            return cached
        }

        do {
            let fresh = try performFetchSync(now: now, timeout: timeout)
            stateLock.withLock { cached = fresh }
            return fresh
        } catch {
            Self.log.debug("credit usage fetch failed: \(error.localizedDescription, privacy: .public)")
            let fallback = stateLock.withLock { cached }
            if let fallback, now.timeIntervalSince(fallback.fetchedAt) <= cacheGrace {
                return fallback
            }
            return nil
        }
    }

    private func performFetchSync(now: Date, timeout: TimeInterval) throws -> CodexCreditUsage {
        let auth = try CodexAuthFile.read(from: authFileURL)
        let request = CodexBackendRequest.make(url: Self.endpoint(now: now), auth: auth, timeout: timeout)
        let data = try CodexBackendRequest.performSync(request, session: session)
        guard let parsed = CodexCreditUsageMapper.parse(json: data, now: now) else {
            throw CodexCreditUsageError.unrecognizedResponse
        }
        return parsed
    }

    /// The window must cover both reported periods. Month-to-date alone is not enough: on the 2nd
    /// of a month the trailing 7 days reach back into the previous one, and a month-start window
    /// would silently report those days as zero.
    static func endpoint(now: Date) -> URL {
        let calendar = CodexCreditUsageMapper.serverCalendar
        let today = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let start = min(monthStart, weekStart)

        var components = URLComponents(string: "https://chatgpt.com/backend-api/wham/usage/daily-workspace-user-token-usage-breakdown")!
        components.queryItems = [
            URLQueryItem(name: "start_date", value: CodexCreditUsageMapper.dateFormatter.string(from: start)),
            URLQueryItem(name: "end_date", value: CodexCreditUsageMapper.dateFormatter.string(from: today)),
            URLQueryItem(name: "group_by", value: "day"),
            URLQueryItem(name: "modes", value: "codex"),
        ]
        return components.url!
    }

    /// Testing seam.
    public static func endpointForTesting(now: Date) -> URL {
        endpoint(now: now)
    }
}

// MARK: - Mapping

public enum CodexCreditUsageMapper {
    /// Defensive DTO: every field optional so a renamed key degrades to "unavailable".
    ///
    /// A day's credits are read from `groups[]` when the response is broken down, and otherwise
    /// from the flat `product_surface_usage_values` map — the endpoint returns one or the other
    /// depending on whether `breakdown_by` was requested, and this asks for neither shape
    /// specifically.
    private struct DTO: Decodable {
        struct Day: Decodable {
            struct Group: Decodable {
                let credits: Double?
            }
            let date: String?
            let groups: [Group]?
            let product_surface_usage_values: [String: Double]?
            let premium_usage_values: [String: [String: Double]]?
        }
        let data: [Day]?
        let data_freshness_ts: String?
    }

    public static func parse(json data: Data, now: Date) -> CodexCreditUsage? {
        guard let dto = try? JSONDecoder().decode(DTO.self, from: data), let days = dto.data else {
            return nil
        }

        var creditsByDate: [String: Double] = [:]
        for day in days {
            guard let date = day.date else { continue }
            creditsByDate[date, default: 0] += credits(in: day)
        }
        guard !creditsByDate.isEmpty else {
            return nil
        }

        let calendar = serverCalendar
        // Anchor on the latest day the server actually published, not on the local or UTC
        // "today". The server buckets by its own day and lags by hours, and a KST clock is
        // already on the next date for most of the UTC day — anchoring on a local today would
        // report 0 every evening. `AccountUsageStatsProvider` anchors its daily buckets the same
        // way, so the two cards agree about which day is the last one.
        let dates = creditsByDate.keys.compactMap(dateFormatter.date(from:))
        guard let anchor = dates.max() else {
            return nil
        }
        let anchorKey = dateFormatter.string(from: anchor)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? anchor
        let weekStart = calendar.date(byAdding: .day, value: -6, to: anchor) ?? anchor

        var sevenDays = 0.0
        var thisMonth = 0.0
        for (key, value) in creditsByDate {
            guard let date = dateFormatter.date(from: key) else { continue }
            if date >= weekStart && date <= anchor {
                sevenDays += value
            }
            if date >= monthStart && date <= anchor {
                thisMonth += value
            }
        }

        return CodexCreditUsage(
            today: creditsByDate[anchorKey] ?? 0,
            sevenDays: sevenDays,
            thisMonth: thisMonth,
            dataFreshness: dto.data_freshness_ts.flatMap(parseTimestamp),
            fetchedAt: now
        )
    }

    /// One day's credits, from whichever shape the response used.
    private static func credits(in day: DTO.Day) -> Double {
        if let groups = day.groups, !groups.isEmpty {
            return groups.reduce(0) { $0 + ($1.credits ?? 0) }
        }
        // `premium_usage_values.total_usage_credits` is a surface -> credits map.
        if let total = day.premium_usage_values?["total_usage_credits"] {
            return total.values.reduce(0, +)
        }
        if let surfaces = day.product_surface_usage_values {
            return surfaces.values.reduce(0, +)
        }
        return 0
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Credits carry fractions but the popover has no room for them; whole credits above 10,
    /// one decimal below so a small day does not read as zero.
    public static func creditsText(_ credits: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = credits < 10 ? 1 : 0
        return formatter.string(from: NSNumber(value: credits)) ?? "\(Int(credits.rounded()))"
    }

    /// The server buckets by UTC day, so the date strings are matched in UTC rather than local
    /// time — the same convention `AccountUsageStatsProvider` uses for its daily buckets.
    static let serverCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
