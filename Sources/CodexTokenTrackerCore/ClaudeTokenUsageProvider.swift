import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates
/// token usage into today / 7 days / 28 days, mirroring the structure of
/// `TokenUsageStatsProvider` (Codex). Deduplicates assistant responses by
/// `requestId` (falling back to `message.id` then top-level `uuid`) so that
/// responses replayed across resumed or forked transcripts are not double-counted.
public enum ClaudeTokenUsageProvider {
    /// Entry point. Returns nil when no transcripts or usage are found.
    public static func load(now: Date = Date()) -> TokenUsageStats? {
        let claudeHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let projectsDir = claudeHome.appendingPathComponent("projects", isDirectory: true)

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let cutoff28 = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let records = transcriptRecords(under: projectsDir, modifiedSince: cutoff28, now: now)
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

    // MARK: - File traversal

    private static func transcriptRecords(
        under root: URL,
        modifiedSince cutoff: Date,
        now: Date
    ) -> [ClaudeTranscriptRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else {
            return []
        }

        var seen = Set<String>()
        var records: [ClaudeTranscriptRecord] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard
                let values = try? fileURL.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey
                ]),
                values.isRegularFile != false,
                let modifiedAt = values.contentModificationDate,
                modifiedAt >= cutoff
            else {
                continue
            }

            let fileRecords = parseFile(fileURL, seen: &seen)
            records.append(contentsOf: fileRecords)
        }

        return records
    }

    // MARK: - Per-file parsing

    private static func parseFile(_ fileURL: URL, seen: inout Set<String>) -> [ClaudeTranscriptRecord] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer { try? handle.close() }

        var records: [ClaudeTranscriptRecord] = []
        var pending = Data()

        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            pending.append(chunk)
            while let newlineRange = pending.firstRange(of: newlineData) {
                let line = pending.subdata(in: pending.startIndex..<newlineRange.lowerBound)
                pending.removeSubrange(pending.startIndex..<newlineRange.upperBound)
                if let record = parseLine(line, seen: &seen) {
                    records.append(record)
                }
            }
        }
        if !pending.isEmpty, let record = parseLine(pending, seen: &seen) {
            records.append(record)
        }
        return records
    }

    private static func parseLine(_ data: Data, seen: inout Set<String>) -> ClaudeTranscriptRecord? {
        guard !data.isEmpty else { return nil }
        guard let raw = try? JSONDecoder().decode(ClaudeTranscriptLine.self, from: data) else {
            return nil
        }
        // Only process assistant events.
        guard raw.type == "assistant" else { return nil }

        // Resolve usage — prefer nested message.usage, fall back to top-level usage.
        guard let usage = raw.message?.usage ?? raw.usage else { return nil }

        // Resolve unique ID for deduplication — prefer API-stable requestId/message.id over local uuid.
        let dedupeKey = raw.requestId ?? raw.message?.id ?? raw.uuid
        if let key = dedupeKey {
            if seen.contains(key) { return nil }
            seen.insert(key)
        }

        guard let timestamp = parseTimestamp(raw.timestamp) else { return nil }

        let total = usage.input_tokens + usage.output_tokens
            + usage.cache_creation_input_tokens + usage.cache_read_input_tokens
        let breakdown = TokenUsageBreakdownDisplay(
            totalTokens: total,
            inputTokens: usage.input_tokens,
            cachedInputTokens: usage.cache_read_input_tokens,
            outputTokens: usage.output_tokens,
            reasoningOutputTokens: 0
        )
        return ClaudeTranscriptRecord(timestamp: timestamp, usage: breakdown)
    }

    // MARK: - Timestamp parsing

    private static func parseTimestamp(_ raw: String) -> Date? {
        // Transcripts use 3-digit millis (e.g. "...07.417Z") — fractional formatter handles them.
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: raw) { return date }

        // Fallback to plain internet date-time.
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        return plainFormatter.date(from: raw)
    }

    private static let newlineData = Data([0x0A])
}

// MARK: - Internal record type

private struct ClaudeTranscriptRecord {
    var timestamp: Date
    var usage: TokenUsageBreakdownDisplay
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
