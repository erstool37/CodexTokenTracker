import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates
/// token usage into today / 7 days / 28 days, mirroring the structure of
/// `TokenUsageStatsProvider` (Codex). Deduplicates assistant responses by
/// `requestId` (falling back to `message.id` then top-level `uuid`) so that
/// responses replayed across resumed or forked transcripts are not double-counted.
///
/// Parsing is incremental: `ClaudeTranscriptCache` keeps each file's parsed records and
/// the byte offset it has consumed, so a refresh only reads bytes appended since the last
/// one. A full re-parse of a ~4 GB / ~900-file 28-day window took ~165 s per refresh,
/// which held the Claude pane in `isRefreshing` and published already-stale snapshots.
public enum ClaudeTokenUsageProvider {
    /// Entry point. Returns nil when no transcripts or usage are found.
    public static func load(
        now: Date = Date(),
        projectsDir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true),
        cache: ClaudeTranscriptCache = .shared
    ) -> TokenUsageStats? {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let cutoff28 = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let records = cache.records(under: projectsDir, modifiedSince: cutoff28)
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
}

// MARK: - Incremental per-file cache

/// Process-wide cache of parsed transcript records, keyed by file path. Transcripts are
/// append-only JSONL, so each file is re-read only from the last consumed newline; a file
/// whose inode changed or that shrank is re-parsed from the start.
public final class ClaudeTranscriptCache: @unchecked Sendable {
    public static let shared = ClaudeTranscriptCache()

    public init() {}

    private struct FileState {
        var fileNumber: Int?
        var offset: UInt64
        var records: [ClaudeTranscriptRecord]
    }

    // Held for the whole scan so concurrent refreshes wait for, then reuse, one pass.
    private let lock = NSLock()
    private var files: [String: FileState] = [:]

    func records(under root: URL, modifiedSince cutoff: Date) -> [ClaudeTranscriptRecord] {
        lock.withLock {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: []
            ) else {
                files = [:]
                return []
            }

            var live = Set<String>()
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                guard
                    let values = try? fileURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .contentModificationDateKey,
                        .fileSizeKey
                    ]),
                    values.isRegularFile != false,
                    let modifiedAt = values.contentModificationDate,
                    modifiedAt >= cutoff
                else {
                    continue
                }

                let path = fileURL.path
                live.insert(path)
                let size = UInt64(values.fileSize ?? 0)
                let fileNumber = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? Int

                var state = files[path] ?? FileState(fileNumber: fileNumber, offset: 0, records: [])
                if state.fileNumber != fileNumber || size < state.offset {
                    state = FileState(fileNumber: fileNumber, offset: 0, records: [])
                }
                if size > state.offset {
                    Self.consume(fileURL, into: &state)
                }
                files[path] = state
            }
            files = files.filter { live.contains($0.key) }

            // Dedupe across files at aggregation time, in a stable path order, first occurrence wins.
            var seen = Set<String>()
            var result: [ClaudeTranscriptRecord] = []
            for path in files.keys.sorted() {
                for record in files[path]!.records {
                    if let key = record.dedupeKey, !seen.insert(key).inserted {
                        continue
                    }
                    result.append(record)
                }
            }
            return result
        }
    }

    /// Reads complete lines from `state.offset` onward and advances the offset past the last
    /// newline. A trailing partial line (a write in progress) is left for the next scan.
    private static func consume(_ fileURL: URL, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil else {
            return
        }

        var seenInFile = Set<String>(state.records.compactMap(\.dedupeKey))
        var pending = Data()
        var consumed: UInt64 = 0

        while true {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                break
            }
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                let line = pending[lineStart..<newline]
                if let record = parseLine(line), record.dedupeKey.map({ seenInFile.insert($0).inserted }) ?? true {
                    state.records.append(record)
                }
                consumed += UInt64(newline - lineStart + 1)
                lineStart = pending.index(after: newline)
            }
            pending = Data(pending[lineStart...])
        }
        state.offset += consumed
    }

    // MARK: - Per-line parsing

    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)

    private static func parseLine(_ data: Data) -> ClaudeTranscriptRecord? {
        guard !data.isEmpty else { return nil }
        // Cheap byte prefilter: user/tool-result lines dominate transcript volume and can never
        // carry assistant usage, so skip full JSON decoding unless both markers are present.
        guard data.range(of: assistantMarker) != nil, data.range(of: usageMarker) != nil else {
            return nil
        }
        guard let raw = try? JSONDecoder().decode(ClaudeTranscriptLine.self, from: data) else {
            return nil
        }
        // Only process assistant events.
        guard raw.type == "assistant" else { return nil }

        // Resolve usage — prefer nested message.usage, fall back to top-level usage.
        guard let usage = raw.message?.usage ?? raw.usage else { return nil }
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
        // Prefer API-stable requestId/message.id over local uuid for deduplication.
        return ClaudeTranscriptRecord(
            timestamp: timestamp,
            usage: breakdown,
            dedupeKey: raw.requestId ?? raw.message?.id ?? raw.uuid
        )
    }

    // MARK: - Timestamp parsing

    // Only ever used under `lock`, so sharing the formatters is safe.
    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ raw: String) -> Date? {
        // Transcripts use 3-digit millis (e.g. "...07.417Z") — fractional formatter handles them.
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}

// MARK: - Internal record type

struct ClaudeTranscriptRecord {
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
