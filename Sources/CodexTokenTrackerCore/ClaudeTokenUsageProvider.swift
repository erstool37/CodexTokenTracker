import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates
/// token usage into today / 7 days / 28 days, mirroring the structure of
/// `TokenUsageStatsProvider` (Codex). Deduplicates assistant responses by
/// `requestId` (falling back to `message.id` then top-level `uuid`) so that
/// responses replayed across resumed or forked transcripts are not double-counted.
///
/// ## Why this caches per file
///
/// The transcript corpus is large and almost entirely immutable: only the handful of
/// files belonging to live sessions change between refreshes. An earlier version
/// re-read and re-decoded every `.jsonl` under `~/.claude/projects` on *every* refresh
/// — measured here at 1.8 GB across 631 files, roughly 27 s of CPU and a large
/// allocation peak every 10 minutes, which is what drove the app's resident size to ~1.9 GB.
/// Keying parsed records by (path, mtime, size) — the same scheme
/// `TokenUsageStatsProvider` already uses for `~/.codex/sessions` — reduces steady-state
/// work to just the files that actually changed.
public enum ClaudeTokenUsageProvider {
    private static let cache = ClaudeTranscriptCache()

    /// Entry point. Returns nil when no transcripts or usage are found, and also while the
    /// popover has never been opened — see `UsageDetailGate` for why the scan is deferred.
    public static func load(now: Date = Date()) -> TokenUsageStats? {
        guard UsageDetailGate.isOpen else {
            return nil
        }

        let claudeHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
        let projectsDir = claudeHome.appendingPathComponent("projects", isDirectory: true)

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        // 31 days, not 28: the longest period reported is calendar month-to-date, which on the
        // 31st of a month reaches back 31 days. A 28-day scan cutoff would silently drop the
        // first days of that month.
        let cutoff = now.addingTimeInterval(-31 * 24 * 60 * 60)
        let records = transcriptRecords(under: projectsDir, modifiedSince: cutoff, now: now)
        guard !records.isEmpty else {
            return nil
        }

        return stats(from: records, now: now)
    }

    // MARK: - Aggregation

    private static func stats(from records: [ClaudeTranscriptRecord], now: Date) -> TokenUsageStats {
        let calendar = Calendar.current
        let weekCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let todayStart = calendar.startOfDay(for: now)
        // Calendar month-to-date, not a rolling 28 days: a monthly allowance resets on the 1st,
        // and a rolling window never lines up with it.
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? todayStart

        let todayRecords = records.filter { $0.timestamp >= todayStart && $0.timestamp <= now }
        let weeklyRecords = records.filter { $0.timestamp >= weekCutoff && $0.timestamp <= now }
        let monthlyRecords = records.filter { $0.timestamp >= monthStart && $0.timestamp <= now }

        return TokenUsageStats(
            today: periodStats(label: "Today", records: todayRecords),
            weekly: periodStats(label: "7 days", records: weeklyRecords),
            monthly: periodStats(label: "This month", records: monthlyRecords),
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

    /// Collect records from every in-window transcript, reusing cached parses for files whose
    /// (mtime, size) are unchanged. Deduplication happens once here, across the combined list,
    /// rather than during parsing — that is what lets a file's records be cached independently
    /// of the other files it is later merged with.
    private static func transcriptRecords(
        under root: URL,
        modifiedSince cutoff: Date,
        now: Date
    ) -> [ClaudeTranscriptRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        var seenPaths = Set<String>()
        var parsed: [ClaudeTranscriptRecord] = []

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
            let size = values.fileSize ?? 0
            seenPaths.insert(path)

            if let cached = cache.records(for: path, modifiedAt: modifiedAt, size: size) {
                parsed.append(contentsOf: cached)
                continue
            }

            // Drain per file. Reading and decoding goes through Foundation types that autorelease;
            // with no pool inside this loop they accumulate for the whole traversal, which is what
            // let a full scan of the corpus hold ~1.9 GB resident rather than a working set.
            let fileRecords = autoreleasepool { parseFile(fileURL) }
            cache.store(fileRecords, for: path, modifiedAt: modifiedAt, size: size)
            parsed.append(contentsOf: fileRecords)
        }

        // Drop cache entries for transcripts that have aged out or been deleted, so the cache
        // tracks the working set rather than growing without bound.
        cache.retain(paths: seenPaths)

        return deduplicated(parsed)
    }

    /// First occurrence wins, matching the previous parse-order behavior: a response replayed
    /// into a resumed or forked transcript is counted once.
    private static func deduplicated(_ records: [ClaudeTranscriptRecord]) -> [ClaudeTranscriptRecord] {
        var seen = Set<String>()
        seen.reserveCapacity(records.count)
        var result: [ClaudeTranscriptRecord] = []
        result.reserveCapacity(records.count)

        for record in records {
            if let key = record.dedupeKey {
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            result.append(record)
        }
        return result
    }

    // MARK: - Per-file parsing

    private static func parseFile(_ fileURL: URL) -> [ClaudeTranscriptRecord] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer { try? handle.close() }

        var records: [ClaudeTranscriptRecord] = []
        var pending = Data()
        // Index of the first unconsumed byte in `pending`. Advancing a cursor and compacting
        // once per chunk avoids the repeated front-removal (and its memmove of the whole
        // remainder) that the previous line loop performed for every single line.
        var cursor = pending.startIndex

        // Each chunk is read and consumed inside its own autorelease pool.
        //
        // `FileHandle.read(upToCount:)` hands back autoreleased `Data`, and with no pool in this
        // loop every chunk of every file stays alive until the enclosing pool drains — which, on
        // a background task walking the whole corpus, is never. Measured over this 1.8 GB corpus:
        // no pool held 1857 MB resident, a pool per file 42 MB, and a pool per chunk 8 MB.
        // That retention, not the parsed records (a few MB), is what made the app sit at ~1.9 GB.
        while true {
            let reachedEOF: Bool = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    return true
                }
                pending.append(chunk)

                while let newlineRange = pending[cursor...].firstRange(of: newlineData) {
                    let line = pending[cursor..<newlineRange.lowerBound]
                    if let record = parseLine(line) {
                        records.append(record)
                    }
                    cursor = newlineRange.upperBound
                }

                if cursor > pending.startIndex {
                    pending.removeSubrange(pending.startIndex..<cursor)
                    cursor = pending.startIndex
                }
                return false
            }
            if reachedEOF {
                break
            }
        }

        let tail = pending[cursor...]
        if !tail.isEmpty, let record = parseLine(tail) {
            records.append(record)
        }
        return records
    }

    private static func parseLine(_ slice: Data.SubSequence) -> ClaudeTranscriptRecord? {
        guard !slice.isEmpty else { return nil }

        // Cheap byte-level prefilter before the (comparatively very expensive) JSON decode.
        // Only assistant events carrying a `usage` object can ever produce a record, so a line
        // missing either marker cannot match. Both markers appear literally in the JSON text,
        // so this can only skip lines the full decode would also have rejected — a false
        // positive merely costs the decode we would have done anyway.
        guard slice.firstRange(of: assistantMarker) != nil,
              slice.firstRange(of: usageMarker) != nil else {
            return nil
        }

        guard let raw = try? decoder.decode(ClaudeTranscriptLine.self, from: Data(slice)) else {
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
        // Unique ID for deduplication — prefer API-stable requestId/message.id over local uuid.
        return ClaudeTranscriptRecord(
            timestamp: timestamp,
            usage: breakdown,
            dedupeKey: raw.requestId ?? raw.message?.id ?? raw.uuid
        )
    }

    // MARK: - Timestamp parsing

    private static func parseTimestamp(_ raw: String) -> Date? {
        // Transcripts use 3-digit millis (e.g. "...07.417Z") — fractional formatter handles them.
        if let date = fractionalTimestampFormatter.date(from: raw) { return date }

        // Fallback to plain internet date-time.
        return plainTimestampFormatter.date(from: raw)
    }

    // Formatters and the decoder are shared rather than constructed per line: building an
    // ISO8601DateFormatter is expensive, and the previous code built two of them for every
    // assistant event in the corpus.
    //
    // `nonisolated(unsafe)` because neither type conforms to `Sendable`, though both are
    // documented as thread-safe for concurrent use once configured. Nothing here mutates them
    // after construction, so the only concurrent access is `date(from:)` / `decode(_:from:)`.
    nonisolated(unsafe) private static let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let decoder = JSONDecoder()

    private static let newlineData = Data([0x0A])
    private static let assistantMarker = Data("\"assistant\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)
}

// MARK: - Internal record type

struct ClaudeTranscriptRecord {
    var timestamp: Date
    var usage: TokenUsageBreakdownDisplay
    /// `requestId` / `message.id` / `uuid`, used to collapse responses replayed across
    /// resumed or forked transcripts. Carried on the record so per-file parses stay cacheable.
    var dedupeKey: String?
}

// MARK: - Per-file parse cache

private final class ClaudeTranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: CachedTranscriptFile] = [:]

    func records(for path: String, modifiedAt: Date, size: Int) -> [ClaudeTranscriptRecord]? {
        lock.lock()
        defer { lock.unlock() }

        guard
            let entry = entries[path],
            entry.modifiedAt == modifiedAt,
            entry.size == size
        else {
            return nil
        }
        return entry.records
    }

    func store(_ records: [ClaudeTranscriptRecord], for path: String, modifiedAt: Date, size: Int) {
        lock.lock()
        entries[path] = CachedTranscriptFile(modifiedAt: modifiedAt, size: size, records: records)
        lock.unlock()
    }

    func retain(paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }
}

private struct CachedTranscriptFile {
    var modifiedAt: Date
    var size: Int
    var records: [ClaudeTranscriptRecord]
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
