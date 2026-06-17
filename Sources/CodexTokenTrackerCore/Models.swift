import Foundation

public struct CodexStatusSnapshot: Equatable, Sendable {
    public var account: AccountDisplay
    public var limits: [LimitBucketDisplay]
    public var onlineTokenStats: TokenUsageStats?
    public var onlineTokenStatsError: String?
    public var tokenStats: TokenUsageStats?
    public var refreshedAt: Date
    public var source: String

    public init(
        account: AccountDisplay,
        limits: [LimitBucketDisplay],
        onlineTokenStats: TokenUsageStats? = nil,
        onlineTokenStatsError: String? = nil,
        tokenStats: TokenUsageStats? = nil,
        refreshedAt: Date,
        source: String = "codex app-server"
    ) {
        self.account = account
        self.limits = limits
        self.onlineTokenStats = onlineTokenStats
        self.onlineTokenStatsError = onlineTokenStatsError
        self.tokenStats = tokenStats
        self.refreshedAt = refreshedAt
        self.source = source
    }

    public var bestRemainingPercent: Int? {
        limits.flatMap(\.windows)
            .filter(\.showsNumericUsage)
            .map(\.percentLeft)
            .min()
    }

    public var mostSevereLimitWarningLevel: LimitWarningLevel {
        limits.flatMap(\.windows)
            .filter(\.showsNumericUsage)
            .map(\.warningLevel)
            .max() ?? .normal
    }

    public var hasCredits: Bool {
        limits.contains { $0.creditsText != nil }
    }
}

public struct AccountDisplay: Equatable, Sendable {
    public var kind: String
    public var email: String?
    public var plan: String?
    public var requiresOpenAIAuth: Bool

    public init(kind: String, email: String?, plan: String?, requiresOpenAIAuth: Bool) {
        self.kind = kind
        self.email = email
        self.plan = plan
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }

    public var title: String {
        if let email, !email.isEmpty {
            return email
        }
        return kind
    }

    public var subtitle: String {
        if let plan, !plan.isEmpty {
            return plan
        }
        return requiresOpenAIAuth ? "Sign in required" : "Plan unavailable"
    }
}

public struct LimitBucketDisplay: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var windows: [LimitWindowDisplay]
    public var creditsText: String?
    public var statusText: String?

    public init(id: String, label: String, windows: [LimitWindowDisplay], creditsText: String?, statusText: String? = nil) {
        self.id = id
        self.label = label
        self.windows = windows
        self.creditsText = creditsText
        self.statusText = statusText
    }
}

public struct LimitWindowDisplay: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var percentUsed: Double
    public var percentLeft: Int
    public var resetsAtText: String?
    public var showsNumericUsage: Bool

    public init(
        id: String,
        label: String,
        percentUsed: Double,
        percentLeft: Int,
        resetsAtText: String?,
        showsNumericUsage: Bool = true
    ) {
        self.id = id
        self.label = label
        self.percentUsed = percentUsed
        self.percentLeft = percentLeft
        self.resetsAtText = resetsAtText
        self.showsNumericUsage = showsNumericUsage
    }

    public var warningLevel: LimitWarningLevel {
        LimitWarningLevel(percentLeft: percentLeft)
    }
}

public enum LimitWarningLevel: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(percentLeft: Int) {
        if percentLeft <= 5 {
            self = .critical
        } else if percentLeft <= 10 {
            self = .warning
        } else {
            self = .normal
        }
    }

    public static func < (lhs: LimitWarningLevel, rhs: LimitWarningLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum TrackerLoadState: Equatable, Sendable {
    case idle
    case refreshing
    case loaded(CodexStatusSnapshot)
    case failed(previous: CodexStatusSnapshot?, message: String)
}

public struct TokenUsageStats: Equatable, Sendable {
    public var today: TokenUsagePeriodStats
    public var weekly: TokenUsagePeriodStats
    public var monthly: TokenUsagePeriodStats
    public var source: String
    public var showsBreakdown: Bool
    public var note: String?

    public init(
        today: TokenUsagePeriodStats,
        weekly: TokenUsagePeriodStats,
        monthly: TokenUsagePeriodStats,
        source: String,
        showsBreakdown: Bool = true,
        note: String? = nil
    ) {
        self.today = today
        self.weekly = weekly
        self.monthly = monthly
        self.source = source
        self.showsBreakdown = showsBreakdown
        self.note = note
    }

    public var periods: [TokenUsagePeriodStats] {
        [today, weekly, monthly]
    }

    public var maxPeriodTotalTokens: Int {
        periods.map(\.usage.totalTokens).max() ?? 0
    }
}

public struct TokenUsagePeriodStats: Equatable, Sendable {
    public var label: String
    public var sessionCount: Int
    public var countLabel: String
    public var usage: TokenUsageBreakdownDisplay

    public init(label: String, sessionCount: Int, usage: TokenUsageBreakdownDisplay, countLabel: String? = nil) {
        self.label = label
        self.sessionCount = sessionCount
        self.countLabel = countLabel ?? "\(sessionCount) events"
        self.usage = usage
    }
}

public struct TokenUsageBreakdownDisplay: Equatable, Sendable {
    public var totalTokens: Int
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int

    public init(
        totalTokens: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0
    ) {
        self.totalTokens = totalTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    public static let zero = TokenUsageBreakdownDisplay()

    public static func + (lhs: TokenUsageBreakdownDisplay, rhs: TokenUsageBreakdownDisplay) -> TokenUsageBreakdownDisplay {
        TokenUsageBreakdownDisplay(
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            reasoningOutputTokens: lhs.reasoningOutputTokens + rhs.reasoningOutputTokens
        )
    }
}
