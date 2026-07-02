import Foundation

/// Config-free adaptive labeling shared by every usage provider.
///
/// Both the Codex app-server response (`rateLimitsByLimitId`) and the Anthropic OAuth usage
/// response (`limits[]`) are *self-describing*: new rate-limit buckets/windows can appear at any
/// time without an app update (e.g. Anthropic adding a per-model weekly window like "Fable").
/// Rather than hardcode every known key, providers hand the raw identifiers here and get a
/// human-readable label back, so a never-before-seen limit still renders with a sensible name.
public enum AdaptiveLabel {
    /// Turn a raw identifier (`snake_case`, `kebab-case`, or `camelCase`) into Title Case,
    /// upper-casing well-known acronyms. Unknown tokens fall through to plain capitalization,
    /// which is what makes brand-new keys render legibly with no code change.
    public static func humanize(_ raw: String) -> String {
        let spaced = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
        let words = spaced.split(separator: " ")
        guard !words.isEmpty else { return raw }
        return words
            .map { word in
                // Preserve the existing Codex convention: any token beginning with "gpt"
                // (e.g. "gpt", "gpt5") is fully upper-cased.
                if word.uppercased().hasPrefix("GPT") {
                    return word.uppercased()
                }
                if let acronym = acronyms[word.lowercased()] {
                    return acronym
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static let acronyms: [String: String] = [
        "api": "API",
        "ai": "AI",
        "oauth": "OAuth"
    ]

    // MARK: - Claude `limits[]` window labels

    /// Derive a window label for one entry of the Anthropic `limits[]` array.
    ///
    /// - `kind`: e.g. `"session"`, `"weekly_all"`, `"weekly_scoped"` — a new kind humanizes cleanly.
    /// - `group`: e.g. `"session"`, `"weekly"` — the coarse window family, used as the base name.
    /// - `model`: `scope.model.display_name` when the limit is scoped to a model (e.g. `"Fable"`).
    ///
    /// A model-scoped window becomes `"<base> · <Model>"` (e.g. `"Weekly · Fable"`), so any future
    /// per-model window Anthropic introduces is labeled automatically.
    static func claudeWindowLabel(kind: String?, group: String?, model: String?) -> String {
        if let model, !model.isEmpty {
            return "\(claudeGroupBase(group: group, kind: kind)) · \(model)"
        }

        switch kind {
        case "session":
            return "5h limit"
        case "weekly_all":
            return "Weekly limit"
        default:
            break
        }

        switch group {
        case "session":
            return "5h limit"
        case "weekly":
            return "Weekly limit"
        default:
            break
        }

        // Unknown, unscoped window: humanize whatever identifier we were given.
        let raw = kind ?? group
        guard let raw, !raw.isEmpty else { return "Limit" }
        let humanized = humanize(raw)
        return humanized.lowercased().contains("limit") ? humanized : "\(humanized) limit"
    }

    /// The base name for a scoped window ("Weekly", "5h", or a humanized fallback).
    private static func claudeGroupBase(group: String?, kind: String?) -> String {
        switch group {
        case "weekly":
            return "Weekly"
        case "session":
            return "5h"
        default:
            let raw = group ?? kind
            guard let raw, !raw.isEmpty else { return "Limit" }
            return humanize(raw)
        }
    }
}
