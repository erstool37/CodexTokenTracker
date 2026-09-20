import Foundation

/// Which rate-limit windows the popover shows.
///
/// The short rolling window — Codex's `primary` (300 min) and Claude's `session` limit, both
/// surfaced as "5h limit" — is deliberately hidden. It churns minute to minute and says nothing
/// about the budget that actually runs out, so it crowded out the longer windows that do.
/// (User decision, 2026-09-20.)
///
/// Hiding is decided centrally, and by *duration* rather than by label, so a provider that
/// renames its window or introduces a new short one is covered without another edit.
public enum LimitWindowVisibility {
    /// Windows at or below this length are treated as the short session window.
    /// 6 h leaves room for a 5 h window reported with slight slack, while staying well clear of
    /// the next window up (24 h).
    public static let sessionWindowMaxMinutes = 360

    /// Hide a window given its duration in minutes.
    ///
    /// A `nil` duration means the provider did not report one. For the Codex `primary` slot that
    /// is precisely the case the "5h limit" fallback label exists for, so callers that know they
    /// are looking at the short slot pass `treatUnknownAsSession: true` and get it hidden too.
    public static func isHidden(windowMinutes: Int?, treatUnknownAsSession: Bool = false) -> Bool {
        guard let windowMinutes else {
            return treatUnknownAsSession
        }
        guard windowMinutes > 0 else {
            return treatUnknownAsSession
        }
        return windowMinutes <= sessionWindowMaxMinutes
    }

    /// Hide one entry of the Anthropic `limits[]` array, which describes its window with
    /// `kind`/`group` strings rather than a duration.
    public static func isHiddenClaudeLimit(kind: String?, group: String?) -> Bool {
        let identifiers = [kind, group].compactMap { $0?.lowercased() }
        return identifiers.contains("session")
    }
}
