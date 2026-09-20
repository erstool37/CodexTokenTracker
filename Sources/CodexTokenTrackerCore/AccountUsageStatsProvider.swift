import Foundation

public enum AccountUsageStatsProvider {
    public static func stats(
        from response: GetAccountTokenUsageResponse,
        now: Date = Date(),
        calendar requestedCalendar: Calendar? = nil
    ) -> TokenUsageStats {
        let calendar = requestedCalendar ?? serverCalendar
        let buckets = (response.dailyUsageBuckets ?? []).compactMap(AccountUsageBucket.init)
        let latestDate = buckets.map(\.date).max()
        let anchorDay = latestDate.map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: anchorDay) ?? anchorDay
        let monthStart = calendar.date(byAdding: .day, value: -27, to: anchorDay) ?? anchorDay
        let daily = periodStats(
            label: "Today",
            buckets: buckets.filter { calendar.isDate($0.date, inSameDayAs: anchorDay) }
        )
        let weekly = periodStats(
            label: "7 days",
            buckets: buckets.filter { $0.date >= weekStart && $0.date <= anchorDay }
        )
        let monthly = periodStats(
            label: "28 days",
            buckets: buckets.filter { $0.date >= monthStart && $0.date <= anchorDay }
        )
        // Calendar month-to-date, which is the window a monthly allowance actually resets on —
        // the rolling 28-day figure never lines up with the 1st of the month.
        let calendarMonthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: anchorDay)
        ) ?? anchorDay
        let thisMonth = periodStats(
            label: "This month",
            buckets: buckets.filter { $0.date >= calendarMonthStart && $0.date <= anchorDay }
        )

        return TokenUsageStats(
            today: daily,
            weekly: weekly,
            monthly: monthly,
            source: "exact /usage",
            showsBreakdown: false,
            note: nil,
            periods: [daily, weekly, thisMonth]
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
