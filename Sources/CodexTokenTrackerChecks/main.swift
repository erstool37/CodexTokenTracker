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

expect(StatusFormatter.percentLeft(from: 0) == 100, "0% used should leave 100%")
expect(StatusFormatter.percentLeft(from: 54.4) == 46, "percent left should round")
expect(StatusFormatter.percentLeft(from: 130) == 0, "percent left should clamp low")
expect(StatusFormatter.windowLabel(minutes: 300, fallback: "5h limit") == "5h limit", "300 minutes should be 5h")
expect(StatusFormatter.windowLabel(minutes: 10_080, fallback: "Weekly limit") == "Weekly limit", "10080 minutes should be weekly")

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
expect(buckets[0].windows.map(\.label) == ["5h limit", "Weekly limit"], "primary and weekly windows should be present")
expect(buckets[0].windows[0].percentLeft == 75, "primary percent left should be mapped")
expect(buckets[0].windows[0].showsNumericUsage == true, "5h windows should render numeric usage")
expect(buckets[0].windows[1].showsNumericUsage == true, "weekly windows should render numeric usage")
expect(LimitWarningLevel(percentLeft: 11) == .normal, "limits above 10% remaining should stay normal")
expect(LimitWarningLevel(percentLeft: 10) == .warning, "limits at 10% remaining should warn")
expect(LimitWarningLevel(percentLeft: 5) == .critical, "limits at 5% remaining should be critical")
expect(LimitWarningLevel(percentLeft: 0) == .critical, "depleted limits should be critical")
expect(buckets[0].windows[0].warningLevel == .normal, "5h window should expose its warning level")
expect(buckets[0].windows[1].warningLevel == .normal, "weekly window should expose its warning level")
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
expect(stats.monthly.label == "28 days", "monthly stats should be shown as a rolling 28-day window")
expect(stats.monthly.sessionCount == 3, "monthly stats should include last 28 days")
expect(stats.monthly.usage.totalTokens == 3_500, "monthly stats should sum 28-day sessions")

print("CodexTokenTracker checks passed")
