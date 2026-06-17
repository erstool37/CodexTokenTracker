import Foundation

public enum AccountUsageStatsProvider {
    public static func stats(
        from response: GetAccountTokenUsageResponse,
        now: Date = Date(),
        calendar requestedCalendar: Calendar? = nil
    ) -> TokenUsageStats {
        let calendar = requestedCalendar ?? serverCalendar
        let buckets = (response.dailyUsageBuckets ?? []).compactMap(AccountUsageBucket.init)
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let monthStart = calendar.date(byAdding: .day, value: -27, to: todayStart) ?? todayStart
        let latestDateText = buckets.map(\.startDateText).max()

        return TokenUsageStats(
            today: periodStats(
                label: "Today",
                buckets: buckets.filter { calendar.isDate($0.date, inSameDayAs: todayStart) }
            ),
            weekly: periodStats(
                label: "7 days",
                buckets: buckets.filter { $0.date >= weekStart && $0.date <= todayStart }
            ),
            monthly: periodStats(
                label: "28 days",
                buckets: buckets.filter { $0.date >= monthStart && $0.date <= todayStart }
            ),
            source: "online account usage",
            showsBreakdown: false,
            note: latestDateText.map { "Latest daily bucket \($0)" }
        )
    }

    private static func periodStats(label: String, buckets: [AccountUsageBucket]) -> TokenUsagePeriodStats {
        let dayCount = buckets.count
        return TokenUsagePeriodStats(
            label: label,
            sessionCount: dayCount,
            usage: TokenUsageBreakdownDisplay(totalTokens: buckets.reduce(0) { $0 + $1.tokens }),
            countLabel: "\(dayCount) \(dayCount == 1 ? "day" : "days")"
        )
    }

    private static let serverCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

private struct AccountUsageBucket {
    var startDateText: String
    var date: Date
    var tokens: Int

    init?(_ dto: AccountTokenUsageDailyBucketDTO) {
        guard let date = Self.formatter.date(from: dto.startDate) else {
            return nil
        }
        self.startDateText = dto.startDate
        self.date = date
        self.tokens = dto.tokens
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
