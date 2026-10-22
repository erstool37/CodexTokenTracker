import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates usage into
/// today / 7 days / 28 days, both as tokens and as API-rate credits (USD). Fable models are
/// excluded entirely. Deduplicates assistant responses by `requestId` (falling back to
/// `message.id` then top-level `uuid`) across files so that responses replayed across resumed
/// or forked transcripts are not double-counted. Parsed files are cached by (mtime, size).
public enum ClaudeTokenUsageProvider {
    private static let cache = FileRecordCache<ClaudeTranscriptRecord>()

    public static let creditNote = "API rates · Fable excluded · this Mac"

    public struct Usage: Sendable {
        public var tokens: TokenUsageStats
        public var credits: CreditUsageStats
    }

    /// Entry point. Returns nil when no transcripts or usage are found.
    public static func load(now: Date = Date()) -> Usage? {
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

        return Usage(
            tokens: stats(from: records, now: now),
            credits: CreditUsageStats.aggregate(
                records.map {
                    CreditUsageRecord(timestamp: $0.timestamp, model: $0.model, credits: $0.credits, tokens: $0.usage.totalTokens)
                },
                unit: .usd,
                note: creditNote,
                now: now
            )
        )
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

    static func parseFile(_ fileURL: URL) -> [ClaudeTranscriptRecord] {
        var records: [ClaudeTranscriptRecord] = []
        let decoder = JSONDecoder()
        JSONLines.forEach(in: fileURL) { line in
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
        if ClaudeCreditRates.isFable(model) { return nil }
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

        // Split cache writes by TTL when the breakdown is present; otherwise bill them as 5m writes.
        let write1h = min(usage.cache_creation?.ephemeral_1h_input_tokens ?? 0, usage.cache_creation_input_tokens)
        let counts = CreditTokenCounts(
            uncachedInput: usage.input_tokens,
            cachedInput: usage.cache_read_input_tokens,
            cacheWrite5m: usage.cache_creation_input_tokens - write1h,
            cacheWrite1h: write1h,
            output: usage.output_tokens
        )
        let credits = ClaudeCreditRates.rate(forModel: model).map {
            counts.cost(at: $0, multiplier: ClaudeCreditRates.multiplier(speed: usage.speed))
        }

        return ClaudeTranscriptRecord(
            timestamp: timestamp,
            usage: breakdown,
            model: ClaudeCreditRates.normalizedModel(model),
            credits: credits,
            // API-stable requestId/message.id over local uuid.
            dedupeKey: raw.requestId ?? raw.message?.id ?? raw.uuid
        )
    }
}

// MARK: - Internal record type

struct ClaudeTranscriptRecord: Sendable {
    var timestamp: Date
    var usage: TokenUsageBreakdownDisplay
    var model: String
    var credits: Double?
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

private struct ClaudeCacheCreation: Decodable {
    let ephemeral_5m_input_tokens: Int?
    let ephemeral_1h_input_tokens: Int?
}

private struct ClaudeUsageTokenCounts: Decodable {
    let input_tokens: Int
    let output_tokens: Int
    let cache_creation_input_tokens: Int
    let cache_read_input_tokens: Int
    let cache_creation: ClaudeCacheCreation?
    let speed: String?

    private enum CodingKeys: String, CodingKey {
        case input_tokens
        case output_tokens
        case cache_creation_input_tokens
        case cache_read_input_tokens
        case cache_creation
        case speed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .input_tokens)) ?? 0
        output_tokens = (try? container.decodeIfPresent(Int.self, forKey: .output_tokens)) ?? 0
        cache_creation_input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)) ?? 0
        cache_read_input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)) ?? 0
        cache_creation = try? container.decodeIfPresent(ClaudeCacheCreation.self, forKey: .cache_creation)
        speed = try? container.decodeIfPresent(String.self, forKey: .speed)
    }
}
