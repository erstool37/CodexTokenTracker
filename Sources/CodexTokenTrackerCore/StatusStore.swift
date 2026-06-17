import Foundation

public struct RefreshRetryPolicy: Equatable, Sendable {
    public var delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    public static let live = RefreshRetryPolicy(delays: [.seconds(5), .seconds(20)])
    public static let disabled = RefreshRetryPolicy(delays: [])
}

@MainActor
public final class StatusStore: ObservableObject {
    @Published public private(set) var state: TrackerLoadState = .idle
    @Published public private(set) var isRefreshing = false

    private let provider: StatusProviding
    private let tokenStatsLoader: @Sendable (Date, AccountDisplay?) -> TokenUsageStats?
    private let refreshRetryPolicy: RefreshRetryPolicy
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var staleTicker: Task<Void, Never>?
    private var refreshTicker: Task<Void, Never>?
    private var retryAttempt = 0

    public init(
        provider: StatusProviding = AppServerStatusProvider(),
        tokenStatsLoader: @escaping @Sendable (Date, AccountDisplay?) -> TokenUsageStats? = { date, account in
            guard let account else {
                return nil
            }
            return TokenUsageStatsProvider.load(for: account, now: date)
        },
        refreshRetryPolicy: RefreshRetryPolicy = .live,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.tokenStatsLoader = tokenStatsLoader
        self.refreshRetryPolicy = refreshRetryPolicy
        self.now = now
        staleTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.refreshLocalTokenStats()
                self?.objectWillChange.send()
            }
        }
        refreshTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        retryTask?.cancel()
        staleTicker?.cancel()
        refreshTicker?.cancel()
    }

    public var currentSnapshot: CodexStatusSnapshot? {
        switch state {
        case let .loaded(snapshot):
            return snapshot
        case let .failed(previous, _):
            return previous
        case .idle, .refreshing:
            return nil
        }
    }

    public var stale: Bool {
        guard let snapshot = currentSnapshot else {
            return false
        }
        return Date().timeIntervalSince(snapshot.refreshedAt) > StatusFormatter.staleInterval
    }

    public var hasError: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    public var errorMessage: String? {
        if case let .failed(_, message) = state {
            return message
        }
        return nil
    }

    public func refresh() {
        refresh(resetRetryAttempts: true)
    }

    private func refresh(resetRetryAttempts: Bool) {
        if resetRetryAttempts {
            resetRetryState()
        }

        let previous = currentSnapshot
        refreshLocalTokenStats(account: previous?.account)
        if isRefreshing {
            return
        }
        isRefreshing = true
        if previous == nil {
            state = .refreshing
        }

        refreshTask = Task { [provider, tokenStatsLoader, now] in
            do {
                let snapshot = try await provider.fetchStatus()
                guard !Task.isCancelled else { return }
                state = .loaded(snapshot)
                isRefreshing = false
                if snapshot.onlineTokenStatsError != nil {
                    scheduleRetryIfAvailable()
                } else {
                    resetRetryState()
                }
            } catch {
                guard !Task.isCancelled else { return }
                let failureDate = now()
                let localTokenStats = tokenStatsLoader(failureDate, previous?.account)
                state = .failed(
                    previous: Self.failureSnapshot(
                        previous: previous,
                        tokenStats: localTokenStats,
                        refreshedAt: failureDate
                    ),
                    message: error.localizedDescription
                )
                isRefreshing = false
                scheduleRetryIfAvailable()
            }
        }
    }

    private func scheduleRetryIfAvailable() {
        retryTask?.cancel()
        guard retryAttempt < refreshRetryPolicy.delays.count else {
            return
        }

        let delay = refreshRetryPolicy.delays[retryAttempt]
        retryAttempt += 1
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else {
                return
            }
            self.retryTask = nil
            self.refresh(resetRetryAttempts: false)
        }
    }

    private func resetRetryState() {
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
    }

    private func refreshLocalTokenStats(at refreshDate: Date? = nil, account: AccountDisplay? = nil) {
        let refreshDate = refreshDate ?? now()
        let account = account ?? currentSnapshot?.account
        guard let localTokenStats = tokenStatsLoader(refreshDate, account) else {
            return
        }

        switch state {
        case var .loaded(snapshot):
            snapshot.tokenStats = localTokenStats
            state = .loaded(snapshot)
        case let .failed(previous, message):
            state = .failed(
                previous: Self.snapshotWithUpdatedTokenStats(
                    previous: previous,
                    tokenStats: localTokenStats,
                    refreshedAt: refreshDate,
                    allowCreatingLocalOnly: false
                ),
                message: message
            )
        case .idle, .refreshing:
            break
        }
    }

    private static func failureSnapshot(
        previous: CodexStatusSnapshot?,
        tokenStats: TokenUsageStats?,
        refreshedAt: Date
    ) -> CodexStatusSnapshot? {
        snapshotWithUpdatedTokenStats(
            previous: previous,
            tokenStats: tokenStats,
            refreshedAt: refreshedAt,
            allowCreatingLocalOnly: true
        )
    }

    private static func snapshotWithUpdatedTokenStats(
        previous: CodexStatusSnapshot?,
        tokenStats: TokenUsageStats?,
        refreshedAt: Date,
        allowCreatingLocalOnly: Bool
    ) -> CodexStatusSnapshot? {
        guard let tokenStats else {
            return previous
        }
        if var previous {
            previous.tokenStats = tokenStats
            return previous
        }
        guard allowCreatingLocalOnly else {
            return nil
        }
        return CodexStatusSnapshot(
            account: AccountDisplay(
                kind: "Status unavailable",
                email: nil,
                plan: nil,
                requiresOpenAIAuth: false
            ),
            limits: [],
            tokenStats: tokenStats,
            refreshedAt: refreshedAt,
            source: tokenStats.source
        )
    }
}
