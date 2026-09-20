import Foundation

/// Which rate-limit windows the popover shows.
///
/// The short rolling windows are hidden: Codex's `primary` (300 min) and `secondary` (10080 min),
/// and Claude's `session` and `weekly` limits. They churn on their own schedules and say nothing
/// about the budget that actually runs out, so they crowded out the monthly view that does.
/// (User decision, 2026-09-20.) What remains is monthly-or-longer windows, plus the usage card.
///
/// Hiding is decided centrally, and by *duration* rather than by label, so a provider that
/// renames its window or introduces a new short one is covered without another edit. A window
/// longer than a week — a monthly limit, or anything beyond it — is always shown.
public enum LimitWindowVisibility {
    /// Windows at or below this length are hidden. 10080 minutes is exactly 7 days, so the
    /// weekly window and everything shorter falls under it while a 30-day window does not.
    public static let hiddenWindowMaxMinutes = 10_080

    /// Hide a window given its duration in minutes.
    ///
    /// A `nil` duration means the provider did not report one. For the Codex `primary` slot that
    /// is precisely the case the "5h limit" fallback label exists for, so callers that know they
    /// are looking at a short slot pass `treatUnknownAsHidden: true` and get it hidden too.
    public static func isHidden(windowMinutes: Int?, treatUnknownAsHidden: Bool = false) -> Bool {
        guard let windowMinutes, windowMinutes > 0 else {
            return treatUnknownAsHidden
        }
        return windowMinutes <= hiddenWindowMaxMinutes
    }

    /// Hide one entry of the Anthropic `limits[]` array, which describes its window with
    /// `kind`/`group` strings rather than a duration. Covers `session`, `weekly_all`, and
    /// `weekly_scoped` (the per-model windows such as Fable), since all are week-or-shorter.
    public static func isHiddenClaudeLimit(kind: String?, group: String?) -> Bool {
        let identifiers = [kind, group].compactMap { $0?.lowercased() }
        return identifiers.contains { $0 == "session" || $0.hasPrefix("weekly") }
    }
}
