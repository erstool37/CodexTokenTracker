import Foundation

public enum StatusMapper {
    public static func accountDisplay(from response: GetAccountResponse) -> AccountDisplay {
        guard let account = response.account else {
            return AccountDisplay(
                kind: "Not signed in",
                email: nil,
                plan: nil,
                requiresOpenAIAuth: response.requiresOpenaiAuth
            )
        }

        switch account {
        case .apiKey:
            return AccountDisplay(
                kind: "API key",
                email: nil,
                plan: nil,
                requiresOpenAIAuth: response.requiresOpenaiAuth
            )
        case let .chatGPT(email, planType):
            return AccountDisplay(
                kind: "ChatGPT",
                email: email,
                plan: StatusFormatter.displayPlan(planType),
                requiresOpenAIAuth: response.requiresOpenaiAuth
            )
        case .amazonBedrock:
            return AccountDisplay(
                kind: "Amazon Bedrock",
                email: nil,
                plan: nil,
                requiresOpenAIAuth: response.requiresOpenaiAuth
            )
        case let .unknown(type):
            return AccountDisplay(
                kind: type,
                email: nil,
                plan: nil,
                requiresOpenAIAuth: response.requiresOpenaiAuth
            )
        }
    }

    public static func limitDisplays(from response: GetAccountRateLimitsResponse, now: Date = Date()) -> [LimitBucketDisplay] {
        var snapshots: [(String, RateLimitSnapshotDTO)] = []
        snapshots.append(("codex", response.rateLimits))

        if let byLimitId = response.rateLimitsByLimitId {
            for key in byLimitId.keys.sorted() {
                if key == "codex" {
                    continue
                }
                if let value = byLimitId[key] {
                    snapshots.append((key, value))
                }
            }
        }

        return snapshots.compactMap { key, snapshot in
            if shouldHideBucket(key: key, snapshot: snapshot) {
                return nil
            }
            return limitDisplay(key: key, snapshot: snapshot, now: now)
        }
    }

    private static func shouldHideBucket(key: String, snapshot: RateLimitSnapshotDTO) -> Bool {
        let text = [
            key,
            snapshot.limitId,
            snapshot.limitName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        return text.contains("codex-spark")
            || text.contains("codex spark")
            || text.contains("bengalfox")
    }

    private static func limitDisplay(key: String, snapshot: RateLimitSnapshotDTO, now: Date) -> LimitBucketDisplay? {
        var windows: [LimitWindowDisplay] = []
        if let primary = snapshot.primary {
            windows.append(windowDisplay(id: "\(key)-primary", window: primary, fallback: "5h limit", now: now))
        }
        if let secondary = snapshot.secondary {
            windows.append(windowDisplay(id: "\(key)-secondary", window: secondary, fallback: "Weekly limit", now: now))
        }
        let credits = StatusFormatter.creditsText(snapshot.credits)
        guard !windows.isEmpty || credits != nil else {
            return nil
        }

        let rawLabel = snapshot.limitName ?? snapshot.limitId ?? key
        return LimitBucketDisplay(
            id: key,
            label: bucketLabel(rawLabel),
            windows: windows,
            creditsText: credits,
            statusText: StatusFormatter.displayStatusReason(snapshot.rateLimitReachedType)
        )
    }

    private static func windowDisplay(id: String, window: RateLimitWindowDTO, fallback: String, now: Date) -> LimitWindowDisplay {
        let left = StatusFormatter.percentLeft(from: window.usedPercent)
        return LimitWindowDisplay(
            id: id,
            label: StatusFormatter.windowLabel(minutes: window.windowDurationMins, fallback: fallback),
            percentUsed: window.usedPercent,
            percentLeft: left,
            resetsAtText: StatusFormatter.resetText(secondsSince1970: window.resetsAt, now: now),
            showsNumericUsage: window.windowDurationMins != 300
        )
    }

    private static func bucketLabel(_ raw: String) -> String {
        if raw.caseInsensitiveCompare("codex") == .orderedSame {
            return "Codex"
        }
        if raw.contains("-") && raw.rangeOfCharacter(from: .uppercaseLetters) != nil {
            return raw
        }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                if word.uppercased().hasPrefix("GPT") {
                    return word.uppercased()
                }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
