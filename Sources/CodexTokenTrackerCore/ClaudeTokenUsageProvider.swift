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
/// append-only JSONL, so each file is re-read only from the last consumed byte. A file is
/// re-parsed from the start when its inode changed, it shrank, or its mtime changed and its
/// leading bytes no longer match (an in-place rewrite).
public final class ClaudeTranscriptCache: @unchecked Sendable {
    public static let shared = ClaudeTranscriptCache()

    public init() {}

    private struct FileState {
        var fileNumber: Int?
        var modifiedAt: Date?
        var head = Data()
        var offset: UInt64 = 0
        var records: [ClaudeTranscriptRecord] = []
    }

    private static let headLength = 4096

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

                var state = files[path] ?? FileState(fileNumber: fileNumber)
                let rewritten = state.fileNumber != fileNumber
                    || size < state.offset
                    || (state.modifiedAt != modifiedAt && Self.readHead(fileURL, length: state.head.count) != state.head)
                if rewritten {
                    state = FileState(fileNumber: fileNumber)
                }
                if size > state.offset {
                    Self.consume(fileURL, into: &state)
                }
                state.modifiedAt = modifiedAt
                files[path] = state
            }
            files = files.filter { live.contains($0.key) }

            // Dedupe across files: a requestId replayed into a resumed or forked transcript keeps
            // its earliest timestamp, i.e. the original response.
            var result: [ClaudeTranscriptRecord] = []
            var indexByKey: [String: Int] = [:]
            for state in files.values {
                for record in state.records {
                    guard let key = record.dedupeKey else {
                        result.append(record)
                        continue
                    }
                    if let index = indexByKey[key] {
                        if record.timestamp < result[index].timestamp {
                            result[index] = record
                        }
                    } else {
                        indexByKey[key] = result.count
                        result.append(record)
                    }
                }
            }
            return result
        }
    }

    private static func readHead(_ fileURL: URL, length: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: length)) ?? Data()
    }

    /// Reads lines from `state.offset` onward and advances the offset past what was consumed.
    /// A trailing line without a newline is consumed only if it is already complete JSON;
    /// otherwise it is a write in progress and is left for the next scan.
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

        func take(_ line: Data) {
            if let record = parseLine(line), record.dedupeKey.map({ seenInFile.insert($0).inserted }) ?? true {
                state.records.append(record)
            }
        }

        // Drain per chunk: this runs on a cooperative-pool thread with no run-loop pool, so the
        // bridged NSData from FileHandle reads otherwise accumulates across a multi-GB cold scan.
        var reachedEnd = false
        while !reachedEnd {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                if state.offset == 0, state.head.count < headLength {
                    state.head.append(chunk.prefix(headLength - state.head.count))
                }
                pending.append(chunk)
                var lineStart = pending.startIndex
                while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
                    take(pending[lineStart..<newline])
                    consumed += UInt64(newline - lineStart + 1)
                    lineStart = pending.index(after: newline)
                }
                pending = Data(pending[lineStart...])
            }
        }
        if !pending.isEmpty, (try? JSONSerialization.jsonObject(with: pending)) != nil {
            take(pending)
            consumed += UInt64(pending.count)
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
