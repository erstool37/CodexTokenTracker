import Foundation

/// Usage expressed in each vendor's billing currency instead of rate-limit windows.
///
/// - Codex: OpenAI's Codex credit rate card (credits per 1M tokens), learn.chatgpt.com/docs/pricing,
///   read 2026-10-22. Included-plan speed multipliers apply (Fast = 2.5x).
/// - Claude: Anthropic usage credits are billed at standard API rates, so a Claude "credit" is a
///   US dollar at the per-model API price (support.claude.com/articles/12429409). Fable models are
///   excluded by the Claude loader, not here.
///
/// Credits are computed from this Mac's local session logs; usage on other machines is not seen.
public enum CreditUnit: String, Equatable, Sendable {
    case codexCredits
    case usd

    public func format(_ value: Double) -> String {
        switch self {
        case .codexCredits:
            if value >= 10_000 {
                return String(format: "%.1fk cr", value / 1000)
            }
            return value >= 100 ? String(format: "%.0f cr", value) : String(format: "%.1f cr", value)
        case .usd:
            return value >= 1000 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
        }
    }
}

/// Price per 1M tokens for each token class, in the provider's credit unit.
public struct CreditRate: Equatable, Sendable {
    public var input: Double
    public var cachedInput: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var output: Double

    public init(input: Double, cachedInput: Double, cacheWrite5m: Double? = nil, cacheWrite1h: Double? = nil, output: Double) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite5m = cacheWrite5m ?? input
        self.cacheWrite1h = cacheWrite1h ?? input
        self.output = output
    }
}

/// Token counts for one billed request, split by price class. `uncachedInput` excludes cache
/// reads and cache writes.
public struct CreditTokenCounts: Equatable, Sendable {
    public var uncachedInput: Int
    public var cachedInput: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var output: Int

    public init(uncachedInput: Int = 0, cachedInput: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0, output: Int = 0) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.output = output
    }

    public var total: Int {
        uncachedInput + cachedInput + cacheWrite5m + cacheWrite1h + output
    }

    public func cost(at rate: CreditRate, multiplier: Double = 1) -> Double {
        let perToken = (Double(uncachedInput) * rate.input
            + Double(cachedInput) * rate.cachedInput
            + Double(cacheWrite5m) * rate.cacheWrite5m
            + Double(cacheWrite1h) * rate.cacheWrite1h
            + Double(output) * rate.output) / 1_000_000
        return perToken * multiplier
    }
}

/// One priced (or unpriceable) request from a local log.
public struct CreditUsageRecord: Equatable, Sendable {
    public var timestamp: Date
    public var model: String
    /// nil when the model has no known rate.
    public var credits: Double?
    public var tokens: Int

    public init(timestamp: Date, model: String, credits: Double?, tokens: Int) {
        self.timestamp = timestamp
        self.model = model
        self.credits = credits
        self.tokens = tokens
    }
}

public struct CreditPeriod: Equatable, Sendable {
    public var label: String
    public var credits: Double

    public init(label: String, credits: Double) {
        self.label = label
        self.credits = credits
    }
}

public struct CreditModelShare: Equatable, Sendable {
    public var model: String
    public var credits: Double

    public init(model: String, credits: Double) {
        self.model = model
        self.credits = credits
    }
}

public struct CreditUsageStats: Equatable, Sendable {
    public var unit: CreditUnit
    public var periods: [CreditPeriod]
    /// Per-model credits over the last 7 days, largest first.
    public var weeklyByModel: [CreditModelShare]
    /// Tokens in the last 28 days whose model has no rate, by model name.
    public var unpricedModels: [String]
    public var unpricedTokens: Int
    public var note: String

    public init(
        unit: CreditUnit,
        periods: [CreditPeriod],
        weeklyByModel: [CreditModelShare],
        unpricedModels: [String] = [],
        unpricedTokens: Int = 0,
        note: String
    ) {
        self.unit = unit
        self.periods = periods
        self.weeklyByModel = weeklyByModel
        self.unpricedModels = unpricedModels
        self.unpricedTokens = unpricedTokens
        self.note = note
    }

    public static func aggregate(
        _ records: [CreditUsageRecord],
        unit: CreditUnit,
        note: String,
        now: Date,
        calendar: Calendar = .current
    ) -> CreditUsageStats {
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let inMonth = records.filter { $0.timestamp >= monthStart && $0.timestamp <= now }

        func sum(since start: Date) -> Double {
            inMonth.lazy.filter { $0.timestamp >= start }.compactMap(\.credits).reduce(0, +)
        }

        var byModel: [String: Double] = [:]
        for record in inMonth where record.timestamp >= weekStart {
            if let credits = record.credits {
                byModel[record.model, default: 0] += credits
            }
        }
        let unpriced = inMonth.filter { $0.credits == nil }

        return CreditUsageStats(
            unit: unit,
            periods: [
                CreditPeriod(label: "Today", credits: sum(since: todayStart)),
                CreditPeriod(label: "7 days", credits: sum(since: weekStart)),
                CreditPeriod(label: "28 days", credits: sum(since: monthStart))
            ],
            weeklyByModel: byModel
                .map { CreditModelShare(model: $0.key, credits: $0.value) }
                .sorted { $0.credits > $1.credits },
            unpricedModels: Array(Set(unpriced.map(\.model))).sorted(),
            unpricedTokens: unpriced.reduce(0) { $0 + $1.tokens },
            note: note
        )
    }
}

// MARK: - Rate cards

public enum CodexCreditRates {
    /// Credits per 1M tokens, Standard speed. Codex has no cache-write class.
    static let rates: [String: CreditRate] = [
        "gpt-6-astra": CreditRate(input: 250, cachedInput: 25, output: 1250),
        "gpt-6.1-sol": CreditRate(input: 50, cachedInput: 2.5, output: 250),
        "gpt-6-sol": CreditRate(input: 50, cachedInput: 5, output: 250),
        "gpt-6-luna": CreditRate(input: 2.5, cachedInput: 0.25, output: 12.5),
        "gpt-5.6-sol": CreditRate(input: 100, cachedInput: 10, output: 500),
        "gpt-5.6-terra": CreditRate(input: 50, cachedInput: 5, output: 300),
        "gpt-5.6-luna": CreditRate(input: 5, cachedInput: 0.5, output: 30),
        "daybreak-blue": CreditRate(input: 100, cachedInput: 10, output: 500),
        "daybreak-red": CreditRate(input: 312.5, cachedInput: 31.25, output: 1875),
        "gpt-rosalind-research": CreditRate(input: 125, cachedInput: 12.5, output: 625)
    ]

    public static func rate(forModel model: String) -> CreditRate? {
        rates[model.lowercased()]
    }

    /// Included-plan usage multiplier for a Codex `service_tier`. Fast ("priority") is 2.5x;
    /// Ultrafast is 8x on GPT-6 Astra / GPT-6.1 Sol.
    public static func multiplier(serviceTier: String?, model: String) -> Double {
        switch serviceTier?.lowercased() {
        case "priority", "fast":
            return 2.5
        case "ultrafast":
            return ["gpt-6-astra", "gpt-6.1-sol"].contains(model.lowercased()) ? 8 : 2.5
        default:
            return 1
        }
    }
}

public enum ClaudeCreditRates {
    /// USD per 1M tokens at standard API rates: input, cache read, 5m write, 1h write, output.
    static let rates: [(prefix: String, rate: CreditRate)] = [
        ("claude-opus-5-5", CreditRate(input: 4, cachedInput: 0.20, cacheWrite5m: 5, cacheWrite1h: 8, output: 20)),
        ("claude-opus-5", CreditRate(input: 5, cachedInput: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25)),
        ("claude-opus-4-5", CreditRate(input: 5, cachedInput: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25)),
        ("claude-opus-4-6", CreditRate(input: 5, cachedInput: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25)),
        ("claude-opus-4-7", CreditRate(input: 5, cachedInput: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25)),
        ("claude-opus-4-8", CreditRate(input: 5, cachedInput: 0.50, cacheWrite5m: 6.25, cacheWrite1h: 10, output: 25)),
        // Opus 4 / 4.1.
        ("claude-opus-4", CreditRate(input: 15, cachedInput: 1.50, cacheWrite5m: 18.75, cacheWrite1h: 30, output: 75)),
        ("claude-sonnet-5", CreditRate(input: 2, cachedInput: 0.20, cacheWrite5m: 2.5, cacheWrite1h: 4, output: 10)),
        ("claude-sonnet-4", CreditRate(input: 3, cachedInput: 0.30, cacheWrite5m: 3.75, cacheWrite1h: 6, output: 15)),
        ("claude-haiku-5", CreditRate(input: 0.10, cachedInput: 0.01, cacheWrite5m: 0.125, cacheWrite1h: 0.20, output: 0.50)),
        ("claude-haiku-4", CreditRate(input: 1, cachedInput: 0.10, cacheWrite5m: 1.25, cacheWrite1h: 2, output: 5))
    ]

    /// Strips a context suffix such as `[1m]` so `claude-opus-5-5[1m]` prices as `claude-opus-5-5`.
    public static func normalizedModel(_ model: String) -> String {
        let lower = model.lowercased()
        if let bracket = lower.firstIndex(of: "[") {
            return String(lower[..<bracket])
        }
        return lower
    }

    public static func isFable(_ model: String) -> Bool {
        normalizedModel(model).contains("fable")
    }

    /// Longest matching prefix wins, so `claude-opus-5-5` is not priced as `claude-opus-5`.
    public static func rate(forModel model: String) -> CreditRate? {
        let normalized = normalizedModel(model)
        return rates
            .filter { normalized.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .rate
    }

    /// Fast mode is billed at 2x the standard rate.
    public static func multiplier(speed: String?) -> Double {
        speed?.lowercased() == "fast" ? 2 : 1
    }
}
