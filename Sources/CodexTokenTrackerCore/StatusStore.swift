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
    private var staleTicker: Timer?
    private var refreshTicker: Timer?
    private var retryAttempt = 0
    private var isPopoverVisible = false

    /// How often the "Last refreshed" label re-renders while the popover is on screen.
    static let staleTickInterval: TimeInterval = 60
    /// Refresh cadence while the popover is open.
    static let foregroundRefreshInterval: TimeInterval = 600
    /// Refresh cadence while it is closed — only the menu-bar tint depends on it, and opening
    /// the popover always refreshes immediately.
    static let backgroundRefreshInterval: TimeInterval = 1_800

    public init(
        provider: StatusProviding = AppServerStatusProvider(),
        tokenStatsLoader: @escaping @Sendable (Date, AccountDisplay?) -> TokenUsageStats? = { date, account in
            // Deferred until the popover has been opened at least once — see `UsageDetailGate`.
            guard let account, UsageDetailGate.isOpen else {
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
        startRefreshTicker()
    }

    // MARK: - Power behavior

    /// Told by the status-bar controller whether the popover is on screen.
    ///
    /// Two things follow from this, and both matter for battery on a widget that runs all day:
    ///
    /// - The stale ticker exists only to re-render the "Last refreshed" timestamp. Nobody can
    ///   read it while the popover is closed, so running it then spent a wakeup a minute — plus
    ///   a full SwiftUI invalidation of an off-screen view — for no visible effect.
    /// - Background refreshes can be far less frequent than foreground ones. A Codex refresh
    ///   spawns an entire `codex app-server` process, which is the most expensive thing this app
    ///   does after launch, so doing it every 10 minutes while nobody is looking is waste.
    ///   Opening the popover refreshes immediately regardless, so the background cadence only
    ///   needs to keep the menu-bar warning tint roughly current.
    public func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else {
            return
        }
        isPopoverVisible = visible

        if visible {
            startStaleTicker()
        } else {
            staleTicker?.invalidate()
            staleTicker = nil
        }
        // Re-arm at the cadence that now applies.
        startRefreshTicker()
    }

    private func startStaleTicker() {
        staleTicker?.invalidate()
        staleTicker = Self.tick(every: Self.staleTickInterval, tolerance: 5) { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func startRefreshTicker() {
        refreshTicker?.invalidate()
        let interval = isPopoverVisible ? Self.foregroundRefreshInterval : Self.backgroundRefreshInterval
        refreshTicker = Self.tick(every: interval, tolerance: interval / 4) { [weak self] in
            self?.refresh()
        }
    }

    /// A repeating timer that lets macOS coalesce its firing with other work.
    ///
    /// `Task.sleep` offers no tolerance, so each sleep wakes the CPU at its own exact moment and
    /// cannot be batched with anything else. `Timer.tolerance` lets the system slide the fire
    /// time, which is what allows several timers across the system to share one wakeup — the
    /// single most effective change available for a periodic background widget.
    private static func tick(
        every interval: TimeInterval,
        tolerance: TimeInterval,
        _ body: @escaping @MainActor () -> Void
    ) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                body()
            }
        }
        timer.tolerance = tolerance
        return timer
    }

    deinit {
        refreshTask?.cancel()
        retryTask?.cancel()
        // Timers are not Sendable, so they cannot be touched from a nonisolated deinit. They are
        // invalidated in `stopTimers()`, which the app calls on termination; a scheduled timer
        // also holds its target only weakly here, so nothing leaks if that call is missed.
    }

    /// Invalidate both tickers. Called when the app is shutting down.
    public func stopTimers() {
        staleTicker?.invalidate()
        staleTicker = nil
        refreshTicker?.invalidate()
        refreshTicker = nil
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
                let localTokenStats = previous?.onlineTokenStats == nil
                    ? tokenStatsLoader(failureDate, previous?.account)
                    : nil
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
