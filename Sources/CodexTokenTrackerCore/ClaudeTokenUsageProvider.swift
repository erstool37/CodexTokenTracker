import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates token usage
/// into today / 7 days / 28 days. Fable models are excluded entirely. Deduplicates assistant responses by `requestId` (falling back to
/// `message.id` then top-level `uuid`) across files so that responses replayed across resumed
/// or forked transcripts are not double-counted. Parsed files are cached by (mtime, size).
public enum ClaudeTokenUsageProvider {
    private static let cache = FileRecordCache<ClaudeTranscriptRecord>()

    /// Entry point. Returns nil when no transcripts or usage are found.
    public static func load(now: Date = Date()) -> TokenUsageStats? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let cutoff28 = now.addingTimeInterval(-28 * 24 * 60 * 60)
        var seen = Set<String>()
        let records = cache.records(under: [projectsDir], modifiedSince: cutoff28, parse: parseFile)
            .filter { record in
                guard let key = record.dedupeKey else { return true }
                return seen.insert(key).inserted
            }
        guard !records.isEmpty else {
            return nil
        }

        return stats(from: records, now: now)
    }

    // MARK: - Aggregation

    private static func stats(from records: [ClaudeTranscriptRecord], now: Date) -> TokenUsageStats {
        let calendar = Calendar.current
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthCutoff = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let todayStart = calendar.startOfDay(for: now)

        let todayRecords = records.filter { $0.timestamp >= todayStart && $0.timestamp <= now }
        let weeklyRecords = records.filter { $0.timestamp >= weekCutoff && $0.timestamp <= now }
        let monthlyRecords = records.filter { $0.timestamp >= monthCutoff && $0.timestamp <= now }

        return TokenUsageStats(
            today: periodStats(label: "Today", records: todayRecords),
            weekly: periodStats(label: "7 days", records: weeklyRecords),
            monthly: periodStats(label: "28 days", records: monthlyRecords),
            source: "~/.claude sessions",
            note: nil
        )
    }

    private static func periodStats(label: String, records: [ClaudeTranscriptRecord]) -> TokenUsagePeriodStats {
        TokenUsagePeriodStats(
            label: label,
            sessionCount: records.count,
            usage: records.reduce(.zero) { $0 + $1.usage }
        )
    }

    // MARK: - Per-file parsing

    private static let assistantMarker = Array(#""type":"assistant""#.utf8)

    /// True for any Claude Fable model id or display name.
    public static func isFable(_ model: String) -> Bool {
        model.lowercased().contains("fable")
    }

    static func parseFile(_ fileURL: URL) -> [ClaudeTranscriptRecord] {
        var records: [ClaudeTranscriptRecord] = []
        let decoder = JSONDecoder()
        // Only assistant lines carry usage; most transcript bytes are user/tool-result lines.
        JSONLines.forEach(in: fileURL, containing: assistantMarker) { line in
            if let record = parseLine(line, decoder: decoder) {
                records.append(record)
            }
        }
        return records
    }

    static func parseLine(_ data: Data, decoder: JSONDecoder = JSONDecoder()) -> ClaudeTranscriptRecord? {
        guard let raw = try? decoder.decode(ClaudeTranscriptLine.self, from: data) else {
            return nil
        }
        // Only process assistant events.
        guard raw.type == "assistant" else { return nil }

        let model = raw.message?.model ?? "unknown"
        // Fable usage is not tracked at all.
        if isFable(model) { return nil }
        // Locally synthesized messages (e.g. interrupted turns) are not billed.
        if model == "<synthetic>" { return nil }

        // Resolve usage — prefer nested message.usage, fall back to top-level usage.
        guard let usage = raw.message?.usage ?? raw.usage else { return nil }
        guard let timestamp = JSONLines.parseTimestamp(raw.timestamp) else { return nil }

        let total = usage.input_tokens + usage.output_tokens
            + usage.cache_creation_input_tokens + usage.cache_read_input_tokens
        let breakdown = TokenUsageBreakdownDisplay(
            totalTokens: total,
            inputTokens: usage.input_tokens,
            cachedInputTokens: usage.cache_read_input_tokens,
            outputTokens: usage.output_tokens,
            reasoningOutputTokens: 0
        )

        return ClaudeTranscriptRecord(
            timestamp: timestamp,
            usage: breakdown,
            // API-stable requestId/message.id over local uuid.
            dedupeKey: raw.requestId ?? raw.message?.id ?? raw.uuid
        )
    }
}

// MARK: - Internal record type

struct ClaudeTranscriptRecord: Sendable {
    var timestamp: Date
    var usage: TokenUsageBreakdownDisplay
    var dedupeKey: String?
}

// MARK: - Minimal decodable DTOs

private struct ClaudeTranscriptLine: Decodable {
    let type: String
    let timestamp: String
    let requestId: String?
    let uuid: String?
    let message: ClaudeTranscriptMessage?
    // Top-level usage as defensive fallback (not observed in the wild, but specified).
    let usage: ClaudeUsageTokenCounts?
}

private struct ClaudeTranscriptMessage: Decodable {
    let id: String?
    let model: String?
    let usage: ClaudeUsageTokenCounts?
}

private struct ClaudeUsageTokenCounts: Decodable {
    let input_tokens: Int
    let output_tokens: Int
    let cache_creation_input_tokens: Int
    let cache_read_input_tokens: Int

    private enum CodingKeys: String, CodingKey {
        case input_tokens
        case output_tokens
        case cache_creation_input_tokens
        case cache_read_input_tokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .input_tokens)) ?? 0
        output_tokens = (try? container.decodeIfPresent(Int.self, forKey: .output_tokens)) ?? 0
        cache_creation_input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)) ?? 0
        cache_read_input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)) ?? 0
    }
}
