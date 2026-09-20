import Foundation

/// Which rate-limit windows the popover shows, decided per provider.
///
/// The two providers are read for different things (user decision, 2026-09-20):
///
/// - **Claude** is watched session to session, so its short windows are the whole point: the
///   5h session limit and the weekly limits all render, including per-model ones like Fable.
/// - **Codex** is watched against a monthly allowance, so its 5h (`primary`) and weekly
///   (`secondary`) windows are noise and stay hidden. Only a monthly-or-longer window renders,
///   and month-to-date token usage carries that pane.
///
/// The Codex rule is keyed on window *duration* rather than label, so a renamed or newly
/// introduced short window is covered without another edit.
public enum LimitWindowVisibility {
    /// Codex windows at or below this length are hidden. 10080 minutes is exactly 7 days, so the
    /// weekly window and everything shorter falls under it while a 30-day window does not.
    public static let codexHiddenWindowMaxMinutes = 10_080

    /// Hide a Codex window given its duration in minutes.
    ///
    /// A `nil` duration means the app-server did not report one. Both the `primary` and
    /// `secondary` slots are short windows by convention — that is what their "5h limit" and
    /// "Weekly limit" fallback labels mean — so callers reading those slots pass
    /// `treatUnknownAsHidden: true`.
    public static func isHiddenCodexWindow(
        windowMinutes: Int?,
        treatUnknownAsHidden: Bool = false
    ) -> Bool {
        guard let windowMinutes, windowMinutes > 0 else {
            return treatUnknownAsHidden
        }
        return windowMinutes <= codexHiddenWindowMaxMinutes
    }

    /// Claude hides nothing: its session and weekly windows are exactly what that pane is for.
    /// Kept as an explicit function, rather than simply omitting the call, so the asymmetry
    /// between the two providers is visible at the call site instead of being silent.
    public static func isHiddenClaudeLimit(kind: String?, group: String?) -> Bool {
        false
    }
}
