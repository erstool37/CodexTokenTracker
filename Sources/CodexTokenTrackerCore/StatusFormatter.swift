import Foundation

public enum StatusFormatter {
    public static let staleInterval: TimeInterval = 60

    public static func percentLeft(from usedPercent: Double) -> Int {
        Int((100.0 - usedPercent).rounded()).clamped(to: 0...100)
    }

    public static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else {
            return fallback
        }
        switch minutes {
        case 60:
            return "1h limit"
        case 300:
            return "5h limit"
        case 10_080:
            return "Weekly limit"
        default:
            if minutes % 10_080 == 0 {
                let weeks = minutes / 10_080
                return weeks == 1 ? "Weekly limit" : "\(weeks)w limit"
            }
            if minutes % 1_440 == 0 {
                let days = minutes / 1_440
                return days == 1 ? "1d limit" : "\(days)d limit"
            }
            if minutes % 60 == 0 {
                let hours = minutes / 60
                return hours == 1 ? "1h limit" : "\(hours)h limit"
            }
            return "\(minutes)m limit"
        }
    }

    public static func resetText(secondsSince1970: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let secondsSince1970 else {
            return nil
        }
        let resetDate = Date(timeIntervalSince1970: secondsSince1970)
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.autoupdatingCurrent
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: resetDate)
        if calendar.isDate(resetDate, inSameDayAs: now) {
            return time
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale.autoupdatingCurrent
        dateFormatter.dateFormat = "d MMM"
        return "\(time) on \(dateFormatter.string(from: resetDate))"
    }

    public static func displayPlan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "pro_lite", "ProLite":
            return "Pro Lite"
        case "team", "self_serve_business_usage_based":
            return "Business"
        case "business", "enterprise_cbp_usage_based", "enterprise":
            return "Enterprise"
        default:
            return raw
                .replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
    }

    public static func displayStatusReason(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else {
            return nil
        }
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
        return spaced
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    static func creditsText(_ credits: CreditsSnapshotDTO?) -> String? {
        guard let credits, credits.hasCredits else {
            return nil
        }
        if credits.unlimited {
            return "Unlimited"
        }
        guard
            let balance = credits.balance?.trimmingCharacters(in: .whitespacesAndNewlines),
            !balance.isEmpty
        else {
            return nil
        }
        if let intValue = Int(balance), intValue > 0 {
            return "\(intValue) credits"
        }
        if let value = Double(balance), value > 0 {
            return "\(Int(value.rounded())) credits"
        }
        return nil
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
