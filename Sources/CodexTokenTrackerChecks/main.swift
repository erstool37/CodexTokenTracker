import CodexTokenTrackerCore
import Foundation
#if canImport(AppKit)
import AppKit
#endif

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Check failed: \(message)\n", stderr)
        exit(1)
    }
}

func tokenCountLine(timestamp: String, totalTokens: Int) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(totalTokens),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(totalTokens)},"last_token_usage":{"input_tokens":\(totalTokens),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(totalTokens)},"model_context_window":258400}}}
    """
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

func appendLine(_ line: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer {
        try? handle.close()
    }
    try handle.seekToEnd()
    handle.write(Data("\(line)\n".utf8))
}

enum ChecksError: Error, LocalizedError {
    case expectedRefreshFailure

    var errorDescription: String? {
        "expected refresh failure"
    }
}

struct AlwaysFailingStatusProvider: StatusProviding {
    func fetchStatus() async throws -> CodexStatusSnapshot {
        throw ChecksError.expectedRefreshFailure
    }
}

final class TokenStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TokenUsageStats

    init(_ value: TokenUsageStats) {
        self.storedValue = value
    }

    var value: TokenUsageStats {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}

final class TokenStatsLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCallCount = 0
    private let stats: TokenUsageStats?

    init(_ stats: TokenUsageStats?) {
        self.stats = stats
    }

    func load(date: Date, account: AccountDisplay?) -> TokenUsageStats? {
        lock.lock()
        storedCallCount += 1
        lock.unlock()
        return stats
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }
}

actor SequencedStatusProvider: StatusProviding {
    private var callCount = 0
    private let firstSnapshot: CodexStatusSnapshot
    private let secondSnapshot: CodexStatusSnapshot

    init(firstSnapshot: CodexStatusSnapshot, secondSnapshot: CodexStatusSnapshot) {
        self.firstSnapshot = firstSnapshot
        self.secondSnapshot = secondSnapshot
    }

    func fetchStatus() async throws -> CodexStatusSnapshot {
        callCount += 1
        let currentCall = callCount

        if currentCall == 1 {
            return firstSnapshot
        }
        try await Task.sleep(for: .milliseconds(500))
        return secondSnapshot
    }
}

actor RetryableStatusProvider: StatusProviding {
    private var fetchCount = 0
    private let snapshots: [Result<CodexStatusSnapshot, Error>]

    init(_ snapshots: [Result<CodexStatusSnapshot, Error>]) {
        self.snapshots = snapshots
    }

    func fetchStatus() async throws -> CodexStatusSnapshot {
        let index = min(fetchCount, snapshots.count - 1)
        fetchCount += 1
        switch snapshots[index] {
        case let .success(snapshot):
            return snapshot
        case let .failure(error):
            throw error
        }
    }

    func callCount() -> Int {
        fetchCount
    }
}

@MainActor
func waitForRefreshToFinish(_ store: StatusStore) async {
    for _ in 0..<100 {
        if !store.isRefreshing {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    expect(false, "store refresh should finish")
}

@MainActor
func waitForLoadedSnapshot(
    _ store: StatusStore,
    matching predicate: (CodexStatusSnapshot) -> Bool,
    message: String
) async {
    for _ in 0..<100 {
        if case let .loaded(snapshot) = store.state, predicate(snapshot) {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    expect(false, message)
}

expect(StatusFormatter.percentLeft(from: 0) == 100, "0% used should leave 100%")
expect(StatusFormatter.percentLeft(from: 54.4) == 46, "percent left should round")
expect(StatusFormatter.percentLeft(from: 130) == 0, "percent left should clamp low")
expect(StatusFormatter.windowLabel(minutes: 300, fallback: "5h limit") == "5h limit", "300 minutes should be 5h")
expect(StatusFormatter.windowLabel(minutes: 10_080, fallback: "Weekly limit") == "Weekly limit", "10080 minutes should be weekly")
expect(StatusFormatter.windowLabel(minutes: 43_200, fallback: "Weekly limit") == "Monthly limit", "43200 minutes should be monthly")
expect(StatusFormatter.windowLabel(minutes: 86_400, fallback: "Weekly limit") == "2mo limit", "86400 minutes should be 2 months")

let json = """
{
  "rateLimits": {
    "limitId": "codex",
    "limitName": "codex",
    "primary": { "usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": 1700003600 },
    "secondary": { "usedPercent": 40.4, "windowDurationMins": 10080, "resetsAt": 1700090000 },
    "credits": { "hasCredits": true, "unlimited": false, "balance": "12.6" },
    "planType": "pro",
    "rateLimitReachedType": null
  },
  "rateLimitsByLimitId": {
    "gpt-5.3-codex-spark": {
      "limitId": "gpt-5.3-codex-spark",
      "limitName": "GPT-5.3-Codex-Spark",
      "primary": { "usedPercent": 10.0, "windowDurationMins": 300, "resetsAt": null },
      "secondary": null,
      "credits": null,
      "planType": null,
      "rateLimitReachedType": null
    }
  }
}
""".data(using: .utf8)!

let decoded = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: json)
let buckets = StatusMapper.limitDisplays(from: decoded, now: Date(timeIntervalSince1970: 1_700_000_000))
expect(buckets.count == 1, "Spark/model-specific buckets should be hidden")
expect(buckets[0].label == "Codex", "codex bucket should be labeled Codex")
expect(buckets[0].windows.isEmpty, "both the 5h and weekly windows are hidden, leaving no windows")
expect(buckets[0].creditsText != nil, "a bucket with no visible windows still survives to show its credits")

// With no credits either, a bucket whose only windows are hidden drops out entirely.
let windowsOnlyJSON = """
{
  "rateLimits": {
    "limitId": "codex",
    "limitName": "codex",
    "primary": { "usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": null },
    "secondary": { "usedPercent": 40.4, "windowDurationMins": 10080, "resetsAt": null },
    "credits": null,
    "planType": "edu",
    "rateLimitReachedType": null
  }
}
""".data(using: .utf8)!
let windowsOnly = try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: windowsOnlyJSON)
expect(
    StatusMapper.limitDisplays(from: windowsOnly, now: Date(timeIntervalSince1970: 1_700_000_000)).isEmpty,
    "a bucket with only hidden windows and no credits drops out entirely"
)
expect(LimitWarningLevel(percentLeft: 11) == .normal, "limits above 10% remaining should stay normal")
expect(LimitWarningLevel(percentLeft: 10) == .warning, "limits at 10% remaining should warn")
expect(LimitWarningLevel(percentLeft: 5) == .critical, "limits at 5% remaining should be critical")
expect(LimitWarningLevel(percentLeft: 0) == .critical, "depleted limits should be critical")

// The hide rule is duration-based, so it covers a renamed or newly introduced short window.
expect(LimitWindowVisibility.isHidden(windowMinutes: 300), "the 5h window is hidden")
expect(LimitWindowVisibility.isHidden(windowMinutes: 60), "a 1h window is shorter still and also hidden")
expect(LimitWindowVisibility.isHidden(windowMinutes: 10_080), "the weekly window is hidden")
expect(!LimitWindowVisibility.isHidden(windowMinutes: 10_081), "anything longer than a week stays visible")
expect(!LimitWindowVisibility.isHidden(windowMinutes: 43_200), "a monthly window stays visible")
expect(!LimitWindowVisibility.isHidden(windowMinutes: nil), "an unknown duration is kept unless the slot is known to be short")
expect(
    LimitWindowVisibility.isHidden(windowMinutes: nil, treatUnknownAsHidden: true),
    "a known-short slot with no reported duration is hidden"
)

// Adaptive Claude usage: the self-describing `limits[]` array drives the windows so newly
// introduced limits (e.g. a per-model weekly "Fable" window) render with no code change.
let claudeNow = Date(timeIntervalSince1970: 1_770_000_000)
let claudeAdaptiveJSON = """
{
  "five_hour": { "utilization": 99.0 },
  "seven_day": { "utilization": 99.0 },
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "limits": [
    { "kind": "session", "group": "session", "percent": 11, "resets_at": "2026-07-02T04:40:00.974674+00:00", "is_active": true },
    { "kind": "weekly_all", "group": "weekly", "percent": 2, "resets_at": "2026-07-02T19:00:00.974697+00:00", "is_active": false },
    { "kind": "weekly_scoped", "group": "weekly", "percent": 40, "resets_at": "2026-07-02T19:00:00.974979+00:00", "scope": { "model": { "id": null, "display_name": "Fable" } }, "is_active": false }
  ],
  "extra_usage": { "is_enabled": false },
  "spend": { "enabled": false, "used": { "amount_minor": 0, "currency": "USD", "exponent": 2 } }
}
""".data(using: .utf8)!
let claudeSnapshot = try ClaudeUsageMapper.snapshot(fromJSON: claudeAdaptiveJSON, now: claudeNow)
// Every window Anthropic currently reports is week-or-shorter, and all of those are hidden, so
// with spend and extra_usage disabled the Claude pane contributes no limit buckets at all. The
// usage card carries that pane instead.
expect(claudeSnapshot.limits.isEmpty, "all Claude windows are week-or-shorter and hidden — got \(claudeSnapshot.limits.count) bucket(s)")
expect(
    LimitWindowVisibility.isHiddenClaudeLimit(kind: "session", group: "session"),
    "the Claude session limit is hidden"
)
expect(
    LimitWindowVisibility.isHiddenClaudeLimit(kind: "weekly_all", group: "weekly"),
    "the Claude weekly limit is hidden"
)
expect(
    LimitWindowVisibility.isHiddenClaudeLimit(kind: "weekly_scoped", group: "weekly"),
    "a model-scoped weekly window (Fable) is hidden too"
)
expect(
    !LimitWindowVisibility.isHiddenClaudeLimit(kind: "monthly_all", group: "monthly"),
    "a monthly Claude window, should one appear, stays visible"
)

// A longer-than-weekly Claude window renders if Anthropic ever reports one.
let claudeMonthlyJSON = """
{
  "limits": [
    { "kind": "session", "group": "session", "percent": 11, "resets_at": null },
    { "kind": "monthly_all", "group": "monthly", "percent": 30, "resets_at": null }
  ],
  "extra_usage": { "is_enabled": false },
  "spend": { "enabled": false }
}
""".data(using: .utf8)!
let claudeMonthly = try ClaudeUsageMapper.snapshot(fromJSON: claudeMonthlyJSON, now: claudeNow)
expect(claudeMonthly.limits.count == 1, "a monthly Claude window produces a bucket")
expect(claudeMonthly.limits[0].windows.map(\.label) == ["Monthly limit"], "the monthly window survives while session is hidden")
expect(claudeMonthly.limits[0].windows[0].percentLeft == 70, "monthly percent left should map from `percent`")

// Regression: a well-formed response whose windows are ALL hidden is still a recognized
// response. Treating "no visible buckets" as "unrecognized shape" made the live Claude pane
// fail with "Unrecognized usage response" once session and weekly were both hidden.
expect(
    ClaudeUsageMapper.isRecognizableUsage(json: claudeAdaptiveJSON),
    "a payload whose windows are all hidden is still recognized"
)
expect(
    !ClaudeUsageMapper.isRecognizableUsage(json: #"{"something_else": 1}"#.data(using: .utf8)!),
    "a payload carrying no known usage shape is not recognized"
)

// When `limits[]` is absent, the legacy top-level fields still render (backward compatibility).
let claudeLegacyJSON = """
{
  "five_hour": { "utilization": 25.0, "resets_at": "2026-07-02T04:40:00Z" },
  "seven_day": { "used_percentage": 60.0 },
  "used_credits": 3,
  "monthly_credit_limit": 10
}
""".data(using: .utf8)!
expect(
    ClaudeUsageMapper.isRecognizableUsage(json: claudeLegacyJSON),
    "a legacy-shaped payload is recognized even though all its windows are hidden"
)
let claudeLegacy = try ClaudeUsageMapper.snapshot(fromJSON: claudeLegacyJSON, now: claudeNow)
// Every legacy window field is week-or-shorter and therefore hidden, so the legacy path now
// contributes only the credits line.
expect(claudeLegacy.limits.first?.windows.isEmpty == true, "legacy 5h/weekly fields are hidden like their limits[] equivalents")
expect(claudeLegacy.limits.first?.creditsText == "3/10 credits", "legacy credits should render")

// The shared adaptive labeler humanizes never-before-seen identifiers legibly.
expect(AdaptiveLabel.humanize("seven_day_haiku") == "Seven Day Haiku", "unknown snake_case humanizes")
expect(AdaptiveLabel.humanize("codex") == "Codex", "single token capitalizes")
let warningSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: [
        LimitBucketDisplay(
            id: "codex",
            label: "Codex",
            windows: [
                LimitWindowDisplay(
                    id: "5h",
                    label: "5h limit",
                    percentUsed: 90,
                    percentLeft: 10,
                    resetsAtText: nil
                ),
                LimitWindowDisplay(
                    id: "weekly",
                    label: "Weekly limit",
                    percentUsed: 96,
                    percentLeft: 4,
                    resetsAtText: nil
                )
            ],
            creditsText: nil
        )
    ],
    refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
)
expect(warningSnapshot.mostSevereLimitWarningLevel == .critical, "snapshot should use the lowest remaining limit warning")
expect(buckets[0].creditsText == "13 credits", "credits should round and render")
expect(StatusFormatter.displayStatusReason("workspace_owner_credits_depleted") == "Workspace Owner Credits Depleted", "limit reasons should be readable")
expect(StatusFormatter.compactTokenCount(950) == "950", "small token counts should not be abbreviated")
expect(StatusFormatter.compactTokenCount(12_430) == "12.4K", "thousands should abbreviate")
expect(StatusFormatter.compactTokenCount(1_250_000) == "1.3M", "millions should abbreviate")
expect(StatusFormatter.compactTokenCount(1_576_000_000) == "1.6B", "billions should abbreviate")

let accountUsageJSON = """
{
  "summary": {
    "lifetimeTokens": 1000,
    "peakDailyTokens": 400,
    "longestRunningTurnSec": 120,
    "currentStreakDays": 2,
    "longestStreakDays": 5
  },
  "dailyUsageBuckets": [
    { "startDate": "2026-06-14", "tokens": 10 },
    { "startDate": "2026-06-13", "tokens": 20 },
    { "startDate": "2026-06-08", "tokens": 30 },
    { "startDate": "2026-05-20", "tokens": 40 }
  ]
}
""".data(using: .utf8)!
let accountUsage = try JSONDecoder().decode(GetAccountTokenUsageResponse.self, from: accountUsageJSON)
expect(accountUsage.summary.lifetimeTokens == 1000, "online account usage should decode summary totals")
expect(accountUsage.dailyUsageBuckets?.count == 4, "online account usage should decode daily buckets")
let onlineStatsNow = ISO8601DateFormatter().date(from: "2026-06-19T12:00:00Z")!
let onlineStats = AccountUsageStatsProvider.stats(from: accountUsage, now: onlineStatsNow)
expect(onlineStats.source == "exact /usage", "exact usage stats should identify the CLI usage source")
expect(onlineStats.showsBreakdown == false, "exact usage stats should not claim local input/output breakdowns")
expect(onlineStats.periods.map(\.label) == ["Today", "7 days", "This month"], "exact usage should show today, 7-day, and calendar-month-to-date periods")
// Anchor day is the latest server bucket (2026-06-14), so the month runs from 2026-06-01:
// 06-14 (10) + 06-13 (20) + 06-08 (30) = 60, with the 2026-05-20 bucket excluded.
expect(onlineStats.periods[2].usage.totalTokens == 60, "month-to-date should sum only buckets in the anchor day's calendar month")
expect(onlineStats.periods[2].countLabel == "3 days", "month-to-date should count nonzero daily buckets in the calendar month")
expect(onlineStats.today.usage.totalTokens == 10, "exact daily stats should use the latest server bucket")
expect(onlineStats.weekly.usage.totalTokens == 60, "exact weekly stats should sum the 7-day window ending at the latest server bucket")
expect(onlineStats.monthly.usage.totalTokens == 100, "exact monthly stats should sum the 28-day window ending at the latest server bucket")
expect(onlineStats.today.countLabel == "1 day", "exact daily stats should count days, not local events")
expect(onlineStats.weekly.countLabel == "3 days", "exact weekly stats should count nonzero daily buckets")
expect(onlineStats.monthly.countLabel == "4 days", "exact monthly stats should count nonzero daily buckets in the 28-day window")
expect(onlineStats.note == nil, "online stats should not surface a latest-bucket note")

#if canImport(AppKit)
let appearancePolicy = StatusBarAppearanceRefreshPolicy.menuBar
expect(
    appearancePolicy.applicationNotificationNames.contains(NSApplication.didChangeScreenParametersNotification),
    "menu bar icon should refresh when screen/menu bar parameters change"
)
expect(
    appearancePolicy.applicationNotificationNames.contains(NSApplication.didBecomeActiveNotification),
    "menu bar icon should refresh when the app becomes active"
)
expect(
    appearancePolicy.workspaceNotificationNames.contains(NSWorkspace.activeSpaceDidChangeNotification),
    "menu bar icon should refresh when switching full-screen spaces"
)
expect(
    appearancePolicy.deferredRefreshDelays == [0.05, 0.25],
    "menu bar icon should schedule bounded delayed redraws after appearance changes"
)
expect(
    !appearancePolicy.usesFixedWhiteIcon,
    "menu bar icon should use the adaptive system template tint"
)
#endif

let popoverSource = try String(contentsOfFile: "Sources/CodexTokenTracker/StatusPopoverView.swift", encoding: .utf8)
let statusBarControllerSource = try String(contentsOfFile: "Sources/CodexTokenTracker/StatusBarController.swift", encoding: .utf8)
let usageCardIndex = popoverSource.range(of: "UsageStatsCardView(")?.lowerBound
let exactUsageIndex = popoverSource.range(of: "UsageStatsCardView(title: \"Usage\", stats: onlineTokenStats)")?.lowerBound
let fallbackUsageIndex = popoverSource.range(of: "UsageStatsCardView(title: \"Estimated device\", stats: localTokenStats)")?.lowerBound
let limitsIndex = popoverSource.range(of: "if snapshot.limits.isEmpty")?.lowerBound
expect(exactUsageIndex != nil, "popover should render exact /usage token stats as the primary usage card")
expect(fallbackUsageIndex != nil, "popover should render local stats only as an estimated device fallback")
expect(usageCardIndex != nil, "popover should define a single compact usage card")
expect(limitsIndex != nil, "popover should render codex limits")
expect(limitsIndex! < usageCardIndex!, "codex limits should render before usage stats")
expect(popoverSource.contains(".frame(width: 420, height: 400)"), "popover content should use the widened 420x400 size")
expect(!popoverSource.contains(".frame(width: 380)"), "popover content should not use the wider 380 point layout")
expect(!popoverSource.contains(".frame(width: 520)"), "popover content should not use the too-wide 520 point layout")
expect(statusBarControllerSource.contains("popoverSize = NSSize(width: 420, height: 400)"), "popover controller should use the widened 420pt width")
expect(popoverSource.contains("ProviderPaneView("), "popover should render Codex and Claude as two side-by-side provider panes")
expect(popoverSource.contains("title: \"Codex\"") && popoverSource.contains("title: \"Claude\""), "popover should label a Codex pane and a Claude pane")
expect(!popoverSource.contains("TokenStatsComparisonView"), "exact usage should replace the old online/device comparison row")
expect(!popoverSource.contains("LocalTokenSummaryView"), "device stats should not render beside exact usage")
if let usageCardRange = popoverSource.range(of: "private struct UsageStatsCardView"),
   let compactRowRange = popoverSource.range(of: "private struct CompactTokenRow") {
    let tokenStatsSource = popoverSource[usageCardRange.lowerBound..<compactRowRange.lowerBound]
    expect(tokenStatsSource.contains("ForEach(stats.periods"), "usage card should render every usage period returned by the stats model")
    expect(tokenStatsSource.contains("stats.note"), "usage card should surface exact usage freshness/source notes")
    expect(!tokenStatsSource.contains("ProgressView("), "usage stats should render numbers only, without bars")
} else {
    expect(false, "popover should define compact exact usage card views")
}
expect(!popoverSource.contains("TokenStatsMetricView"), "compact token stats should not render detailed breakdown metrics")
expect(!popoverSource.contains("Input\""), "compact token stats should hide input breakdown")
expect(!popoverSource.contains("Cached\""), "compact token stats should hide cached breakdown")
expect(!popoverSource.contains("Reasoning\""), "compact token stats should hide reasoning breakdown")

let statsNow = Date(timeIntervalSince1970: 1_700_000_000)
var statsCalendar = Calendar(identifier: .gregorian)
statsCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
let stats = TokenUsageStatsProvider.stats(from: [
    TokenUsageSessionRecord(
        updatedAt: statsNow.addingTimeInterval(-2 * 60 * 60),
        usage: TokenUsageBreakdownDisplay(
            totalTokens: 500,
            inputTokens: 350,
            cachedInputTokens: 100,
            outputTokens: 125,
            reasoningOutputTokens: 25
        )
    ),
    TokenUsageSessionRecord(
        updatedAt: statsNow.addingTimeInterval(-2 * 24 * 60 * 60),
        usage: TokenUsageBreakdownDisplay(
            totalTokens: 1_000,
            inputTokens: 700,
            cachedInputTokens: 200,
            outputTokens: 250,
            reasoningOutputTokens: 50
        )
    ),
    TokenUsageSessionRecord(
        updatedAt: statsNow.addingTimeInterval(-10 * 24 * 60 * 60),
        usage: TokenUsageBreakdownDisplay(
            totalTokens: 2_000,
            inputTokens: 1_400,
            cachedInputTokens: 400,
            outputTokens: 500,
            reasoningOutputTokens: 100
        )
    ),
    TokenUsageSessionRecord(
        updatedAt: statsNow.addingTimeInterval(-40 * 24 * 60 * 60),
        usage: TokenUsageBreakdownDisplay(totalTokens: 4_000)
    )
], now: statsNow, calendar: statsCalendar)
expect(stats.today.sessionCount == 1, "today stats should include only today's sessions")
expect(stats.today.usage.totalTokens == 500, "today stats should sum today's sessions")
expect(stats.weekly.sessionCount == 2, "weekly stats should include only last 7 days")
expect(stats.weekly.usage.totalTokens == 1_500, "weekly stats should sum recent sessions")
// statsNow is 2023-11-14, so month-to-date starts 2023-11-01: the today, -2d and -10d records
// all fall inside November, while the -40d record (2023-10-05) does not.
expect(stats.monthly.label == "This month", "monthly stats should be shown as calendar month-to-date")
expect(stats.monthly.sessionCount == 3, "month-to-date should include sessions since the 1st")
expect(stats.monthly.usage.totalTokens == 3_500, "month-to-date should sum sessions since the 1st")
expect(stats.periods.map(\.label) == ["Today", "7 days", "This month"], "token stats should expose periods in display order")

// A record from the previous calendar month is excluded even when it is inside a rolling 28 days.
let crossMonthNow = Date(timeIntervalSince1970: 1_701_000_000) // 2023-11-26
let crossMonthStats = TokenUsageStatsProvider.stats(from: [
    TokenUsageSessionRecord(
        updatedAt: Date(timeIntervalSince1970: 1_698_800_000), // 2023-11-01, same month
        usage: TokenUsageBreakdownDisplay(totalTokens: 10)
    ),
    TokenUsageSessionRecord(
        updatedAt: Date(timeIntervalSince1970: 1_698_600_000), // 2023-10-29, previous month
        usage: TokenUsageBreakdownDisplay(totalTokens: 99)
    )
], now: crossMonthNow, calendar: statsCalendar)
expect(crossMonthStats.monthly.usage.totalTokens == 10, "month-to-date must exclude the previous calendar month even within 28 days")
expect(stats.maxPeriodTotalTokens == 3_500, "token stats should expose the largest period total for visualization")

let temporaryCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexTokenTrackerChecks-\(UUID().uuidString)", isDirectory: true)
let temporarySessions = temporaryCodexHome.appendingPathComponent("sessions/2023/11/14", isDirectory: true)
try FileManager.default.createDirectory(at: temporarySessions, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: temporaryCodexHome)
}

let multiTurnSession = """
{"timestamp":"2023-11-12T22:13:20Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":70,"cached_input_tokens":20,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":100},"last_token_usage":{"input_tokens":70,"cached_input_tokens":20,"output_tokens":25,"reasoning_output_tokens":5,"total_tokens":100},"model_context_window":258400}}}
{"timestamp":"2023-11-14T21:13:20Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":105,"cached_input_tokens":30,"output_tokens":38,"reasoning_output_tokens":7,"total_tokens":150},"last_token_usage":{"input_tokens":35,"cached_input_tokens":10,"output_tokens":13,"reasoning_output_tokens":2,"total_tokens":50},"model_context_window":258400}}}
"""
try multiTurnSession.write(
    to: temporarySessions.appendingPathComponent("rollout-test.jsonl"),
    atomically: true,
    encoding: .utf8
)

let loadedStats = TokenUsageStatsProvider.load(
    codexHome: temporaryCodexHome,
    now: statsNow,
)
expect(loadedStats.today.sessionCount == 1, "today file stats should count one token event")
expect(loadedStats.today.usage.totalTokens == 50, "today file stats should use per-event token usage")
expect(loadedStats.weekly.sessionCount == 2, "weekly file stats should count token events, not files")
expect(loadedStats.weekly.usage.totalTokens == 150, "weekly file stats should sum per-event token usage")

let hiddenParent = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexTokenTrackerHidden-\(UUID().uuidString)", isDirectory: true)
let hiddenCodexHome = hiddenParent.appendingPathComponent(".codex", isDirectory: true)
let hiddenSessions = hiddenCodexHome.appendingPathComponent("sessions/2023/11/14", isDirectory: true)
try FileManager.default.createDirectory(at: hiddenSessions, withIntermediateDirectories: true)
let hiddenSessionsRoot = hiddenCodexHome.appendingPathComponent("sessions", isDirectory: true)
let chflagsProcess = Process()
chflagsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
chflagsProcess.arguments = ["hidden", hiddenCodexHome.path, hiddenSessionsRoot.path]
try chflagsProcess.run()
chflagsProcess.waitUntilExit()
expect(chflagsProcess.terminationStatus == 0, "hidden .codex fixture should set macOS hidden flags")
defer {
    try? FileManager.default.removeItem(at: hiddenParent)
}
try multiTurnSession.write(
    to: hiddenSessions.appendingPathComponent("rollout-hidden-test.jsonl"),
    atomically: true,
    encoding: .utf8
)
let hiddenStats = TokenUsageStatsProvider.load(
    codexHome: hiddenCodexHome,
    now: statsNow
)
expect(hiddenStats.weekly.sessionCount == 2, "hidden .codex session roots should still be traversed")
expect(hiddenStats.weekly.usage.totalTokens == 150, "hidden .codex session roots should still sum token events")

let accountCodexHome = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexTokenTrackerAccountChecks-\(UUID().uuidString)", isDirectory: true)
let accountSessions = accountCodexHome.appendingPathComponent("sessions/2023/11/14", isDirectory: true)
try FileManager.default.createDirectory(at: accountSessions, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: accountCodexHome)
}
let accountLedgerURL = accountCodexHome.appendingPathComponent("account-token-usage.json")
let accountSessionURL = accountSessions.appendingPathComponent("rollout-account-test.jsonl")
try [
    tokenCountLine(timestamp: "2023-11-14T18:13:20Z", totalTokens: 100),
    tokenCountLine(timestamp: "2023-11-14T19:13:20Z", totalTokens: 200)
].joined(separator: "\n").appending("\n").write(
    to: accountSessionURL,
    atomically: true,
    encoding: .utf8
)
let firstAccount = AccountDisplay(
    kind: "ChatGPT",
    email: "First@Example.com",
    plan: "Pro",
    requiresOpenAIAuth: false
)
let secondAccount = AccountDisplay(
    kind: "ChatGPT",
    email: "second@example.com",
    plan: "Plus",
    requiresOpenAIAuth: false
)
let baselineAccountStats = TokenUsageStatsProvider.load(
    for: firstAccount,
    codexHome: accountCodexHome,
    ledgerURL: accountLedgerURL,
    now: statsNow,
    calendar: statsCalendar
)
expect(baselineAccountStats.today.sessionCount == 0, "account ledger should start fresh by baselining existing untagged events")
expect(baselineAccountStats.weekly.usage.totalTokens == 0, "account ledger should not claim old untagged history")
try appendLine(tokenCountLine(timestamp: "2023-11-14T20:13:20Z", totalTokens: 50), to: accountSessionURL)
let firstAccountStats = TokenUsageStatsProvider.load(
    for: firstAccount,
    codexHome: accountCodexHome,
    ledgerURL: accountLedgerURL,
    now: statsNow,
    calendar: statsCalendar
)
expect(firstAccountStats.today.sessionCount == 1, "new token events should be assigned to the active account")
expect(firstAccountStats.today.usage.totalTokens == 50, "active account stats should include newly assigned usage")
let secondAccountBeforeNewUsageStats = TokenUsageStatsProvider.load(
    for: secondAccount,
    codexHome: accountCodexHome,
    ledgerURL: accountLedgerURL,
    now: statsNow,
    calendar: statsCalendar
)
expect(secondAccountBeforeNewUsageStats.weekly.usage.totalTokens == 0, "other accounts should not see usage assigned to the first account")
try appendLine(tokenCountLine(timestamp: "2023-11-14T21:13:20Z", totalTokens: 75), to: accountSessionURL)
let secondAccountStats = TokenUsageStatsProvider.load(
    for: secondAccount,
    codexHome: accountCodexHome,
    ledgerURL: accountLedgerURL,
    now: statsNow,
    calendar: statsCalendar
)
expect(secondAccountStats.today.sessionCount == 1, "switched accounts should receive their own new token events")
expect(secondAccountStats.today.usage.totalTokens == 75, "switched account stats should be stored separately")
let firstAccountAfterSwitchStats = TokenUsageStatsProvider.load(
    for: firstAccount,
    codexHome: accountCodexHome,
    ledgerURL: accountLedgerURL,
    now: statsNow,
    calendar: statsCalendar
)
expect(firstAccountAfterSwitchStats.today.usage.totalTokens == 50, "first account stats should remain separate after switching accounts")

let fallbackStats = TokenUsageStats(
    today: TokenUsagePeriodStats(
        label: "Today",
        sessionCount: 2,
        usage: TokenUsageBreakdownDisplay(totalTokens: 250)
    ),
    weekly: TokenUsagePeriodStats(
        label: "7 days",
        sessionCount: 2,
        usage: TokenUsageBreakdownDisplay(totalTokens: 250)
    ),
    monthly: TokenUsagePeriodStats(
        label: "28 days",
        sessionCount: 2,
        usage: TokenUsageBreakdownDisplay(totalTokens: 250)
    ),
    source: "~/.codex/sessions"
)
let exactUsageFirstSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: [],
    onlineTokenStats: onlineStats,
    onlineTokenStatsError: nil,
    tokenStats: nil,
    refreshedAt: statsNow
)
let exactUsageSecondSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: [],
    onlineTokenStats: onlineStats,
    onlineTokenStatsError: nil,
    tokenStats: nil,
    refreshedAt: statsNow.addingTimeInterval(1)
)
let exactUsageFallbackProbe = TokenStatsLoaderProbe(fallbackStats)
let exactUsageRefreshStore = StatusStore(
    provider: SequencedStatusProvider(
        firstSnapshot: exactUsageFirstSnapshot,
        secondSnapshot: exactUsageSecondSnapshot
    ),
    tokenStatsLoader: exactUsageFallbackProbe.load(date:account:),
    now: { statsNow }
)
await MainActor.run {
    exactUsageRefreshStore.refresh()
}
await waitForRefreshToFinish(exactUsageRefreshStore)
let firstExactUsageTokenStats = await MainActor.run(body: { exactUsageRefreshStore.currentSnapshot?.onlineTokenStats })
expect(
    firstExactUsageTokenStats == onlineStats,
    "first refresh should load exact usage stats"
)
await MainActor.run {
    exactUsageRefreshStore.refresh()
}
try? await Task.sleep(for: .milliseconds(50))
let exactUsageRefreshStillInFlight = await MainActor.run(body: { exactUsageRefreshStore.isRefreshing })
expect(
    exactUsageRefreshStillInFlight,
    "second provider refresh should still be in flight"
)
let immediateExactUsageSnapshot = await MainActor.run(body: { exactUsageRefreshStore.currentSnapshot })
expect(
    exactUsageFallbackProbe.callCount == 0,
    "manual refresh with exact usage should not load local fallback stats before the status provider finishes"
)
expect(
    immediateExactUsageSnapshot?.tokenStats == nil,
    "exact usage snapshot should not be overwritten with estimated device fallback stats"
)
await waitForRefreshToFinish(exactUsageRefreshStore)

let freshFailureStats = TokenUsageStats(
    today: TokenUsagePeriodStats(
        label: "Today",
        sessionCount: 1,
        usage: TokenUsageBreakdownDisplay(totalTokens: 42)
    ),
    weekly: TokenUsagePeriodStats(
        label: "7 days",
        sessionCount: 1,
        usage: TokenUsageBreakdownDisplay(totalTokens: 42)
    ),
    monthly: TokenUsagePeriodStats(
        label: "28 days",
        sessionCount: 1,
        usage: TokenUsageBreakdownDisplay(totalTokens: 42)
    ),
    source: "~/.codex/sessions"
)
let failingStore = StatusStore(
    provider: AlwaysFailingStatusProvider(),
    tokenStatsLoader: { _, _ in freshFailureStats },
    now: { statsNow }
)
await MainActor.run {
    failingStore.refresh()
}
await waitForRefreshToFinish(failingStore)
if case let .failed(previous, message) = await MainActor.run(body: { failingStore.state }) {
    expect(message == "expected refresh failure", "failed refresh should keep the provider error message")
    expect(previous?.limits.isEmpty == true, "failed refresh without a previous snapshot should publish an empty limits snapshot")
    expect(previous?.tokenStats == freshFailureStats, "failed refresh should still publish fresh local token stats")
} else {
    expect(false, "failing provider should put store into failed state")
}

let retrySuccessSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: [
        LimitBucketDisplay(
            id: "codex",
            label: "Codex",
            windows: [
                LimitWindowDisplay(
                    id: "5h",
                    label: "5h limit",
                    percentUsed: 1,
                    percentLeft: 99,
                    resetsAtText: nil
                )
            ],
            creditsText: nil
        )
    ],
    tokenStats: freshFailureStats,
    refreshedAt: statsNow
)
let retryingFailureProvider = RetryableStatusProvider([
    .failure(ChecksError.expectedRefreshFailure),
    .success(retrySuccessSnapshot)
])
let retryingFailureStore = StatusStore(
    provider: retryingFailureProvider,
    tokenStatsLoader: { _, _ in freshFailureStats },
    refreshRetryPolicy: RefreshRetryPolicy(delays: [.milliseconds(20)]),
    now: { statsNow }
)
await MainActor.run {
    retryingFailureStore.refresh()
}
await waitForRefreshToFinish(retryingFailureStore)
if case .failed = await MainActor.run(body: { retryingFailureStore.state }) {
    await waitForLoadedSnapshot(
        retryingFailureStore,
        matching: { $0.limits.first?.label == "Codex" },
        message: "failed provider refresh should retry and load a later successful snapshot"
    )
} else {
    expect(false, "first retrying provider attempt should fail before retrying")
}
let retryingFailureCalls = await retryingFailureProvider.callCount()
expect(retryingFailureCalls == 2, "failed provider refresh should retry once")

let onlineUsageFailedSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: retrySuccessSnapshot.limits,
    onlineTokenStats: nil,
    onlineTokenStatsError: "usage timeout",
    tokenStats: freshFailureStats,
    refreshedAt: statsNow
)
let onlineUsageRecoveredSnapshot = CodexStatusSnapshot(
    account: AccountDisplay(kind: "ChatGPT", email: nil, plan: nil, requiresOpenAIAuth: false),
    limits: retrySuccessSnapshot.limits,
    onlineTokenStats: onlineStats,
    onlineTokenStatsError: nil,
    tokenStats: freshFailureStats,
    refreshedAt: statsNow.addingTimeInterval(1)
)
let retryingOnlineUsageProvider = RetryableStatusProvider([
    .success(onlineUsageFailedSnapshot),
    .success(onlineUsageRecoveredSnapshot)
])
let retryingOnlineUsageStore = StatusStore(
    provider: retryingOnlineUsageProvider,
    tokenStatsLoader: { _, _ in freshFailureStats },
    refreshRetryPolicy: RefreshRetryPolicy(delays: [.milliseconds(20)]),
    now: { statsNow }
)
await MainActor.run {
    retryingOnlineUsageStore.refresh()
}
await waitForRefreshToFinish(retryingOnlineUsageStore)
if case let .loaded(snapshot) = await MainActor.run(body: { retryingOnlineUsageStore.state }) {
    expect(snapshot.onlineTokenStatsError == "usage timeout", "first online usage attempt should expose the usage error")
    await waitForLoadedSnapshot(
        retryingOnlineUsageStore,
        matching: { $0.onlineTokenStats == onlineStats && $0.onlineTokenStatsError == nil },
        message: "online usage failures should retry and recover account token stats"
    )
} else {
    expect(false, "first online usage retry snapshot should be loaded with an online usage error")
}
let retryingOnlineUsageCalls = await retryingOnlineUsageProvider.callCount()
expect(retryingOnlineUsageCalls == 2, "online usage error should retry once")

print("CodexTokenTracker checks passed")
