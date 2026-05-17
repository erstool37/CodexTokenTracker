import Foundation

public struct CodexStatusSnapshot: Equatable, Sendable {
    public var account: AccountDisplay
    public var limits: [LimitBucketDisplay]
    public var refreshedAt: Date
    public var source: String

    public init(
        account: AccountDisplay,
        limits: [LimitBucketDisplay],
        refreshedAt: Date,
        source: String = "codex app-server"
    ) {
        self.account = account
        self.limits = limits
        self.refreshedAt = refreshedAt
        self.source = source
    }

    public var bestRemainingPercent: Int? {
        limits.flatMap(\.windows).map(\.percentLeft).min()
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

    public init(id: String, label: String, percentUsed: Double, percentLeft: Int, resetsAtText: String?) {
        self.id = id
        self.label = label
        self.percentUsed = percentUsed
        self.percentLeft = percentLeft
        self.resetsAtText = resetsAtText
    }
}

public enum TrackerLoadState: Equatable, Sendable {
    case idle
    case refreshing
    case loaded(CodexStatusSnapshot)
    case failed(previous: CodexStatusSnapshot?, message: String)
}
