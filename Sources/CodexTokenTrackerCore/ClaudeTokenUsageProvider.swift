import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates
/// token usage into today / 7 days / 28 days, mirroring the structure of
/// `TokenUsageStatsProvider` (Codex). Deduplicates assistant responses by
/// `requestId` (falling back to `message.id` then top-level `uuid`) so that
/// responses replayed across resumed or forked transcripts are not double-counted.
public enum ClaudeTokenUsageProvider {
    /// Entry point. Returns nil when no transcripts or usage are found.
    /// `projectsDirectory` overrides `~/.claude/projects` (used by checks).
    public static func load(now: Date = Date(), projectsDirectory: URL? = nil) -> TokenUsageStats? {
        let projectsDir = projectsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let cutoff28 = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let records = transcriptRecords(under: projectsDir, modifiedSince: cutoff28)
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
        modifiedSince cutoff: Date
    ) -> [ClaudeTranscriptRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: []
        ) else {
            return []
        }

        // Dedupe stays global across files and follows enumeration order, as before;
        // only the per-file parse is cached.
        var seen = Set<UInt64>()
        var records: [ClaudeTranscriptRecord] = []
        var seenPaths = Set<String>()

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
            let size = values.fileSize ?? -1
            seenPaths.insert(path)

            let entries: [ClaudeCachedEntry]
            if let cached = cache.entries(for: path, modifiedAt: modifiedAt, size: size) {
                entries = cached
            } else {
                entries = parseFile(fileURL)
                cache.store(entries, for: path, modifiedAt: modifiedAt, size: size)
            }

            for entry in entries {
                if entry.dedupeKey != 0 && !seen.insert(entry.dedupeKey).inserted { continue }
                guard let timestamp = entry.timestamp else { continue }
                records.append(ClaudeTranscriptRecord(timestamp: timestamp, usage: entry.usage))
            }
        }

        cache.retain(paths: seenPaths)
        return records
    }

    // MARK: - Per-file parsing

    /// Streams the file in fixed chunks through one reusable buffer and splits lines by index.
    private static func parseFile(_ fileURL: URL) -> [ClaudeCachedEntry] {
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        let decoder = JSONDecoder()
        var entries: [ClaudeCachedEntry] = []
        var buffer = [UInt8](repeating: 0, count: readChunkSize)
        var start = 0  // first unconsumed byte
        var end = 0    // end of valid bytes

        while true {
            // Grow only when a single line outgrows the buffer.
            if end == buffer.count {
                if start > 0 {
                    buffer.withUnsafeMutableBytes { raw in
                        memmove(raw.baseAddress!, raw.baseAddress! + start, end - start)
                    }
                    end -= start
                    start = 0
                } else {
                    buffer.append(contentsOf: repeatElement(0, count: buffer.count))
                }
            }
            let readCount = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress! + end, raw.count - end)
            }
            if readCount < 0 && errno == EINTR { continue }
            if readCount <= 0 { break }

            let scanFrom = end
            end += readCount
            buffer.withUnsafeBytes { raw in
                let base = raw.baseAddress!
                var cursor = scanFrom
                while cursor < end,
                      let hit = memchr(base + cursor, 0x0A, end - cursor) {
                    let newline = base.distance(to: UnsafeRawPointer(hit))
                    if let entry = parseLine(base + start, count: newline - start, decoder: decoder) {
                        entries.append(entry)
                    }
                    start = newline + 1
                    cursor = start
                }
            }
            if start == end {
                start = 0
                end = 0
            }
        }

        if end > start {
            buffer.withUnsafeBytes { raw in
                if let entry = parseLine(raw.baseAddress! + start, count: end - start, decoder: decoder) {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private static func parseLine(
        _ bytes: UnsafeRawPointer,
        count: Int,
        decoder: JSONDecoder
    ) -> ClaudeCachedEntry? {
        guard count > 0 else { return nil }
        // Lines without a literal "usage" key cannot yield a record: the parser requires one.
        guard memmem(bytes, count, usageKeyBytes, usageKeyBytes.count) != nil else { return nil }

        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes), count: count, deallocator: .none)
        guard let raw = try? decoder.decode(ClaudeTranscriptLine.self, from: data) else {
            return nil
        }
        // Only process assistant events.
        guard raw.type == "assistant" else { return nil }

        // Resolve usage — prefer nested message.usage, fall back to top-level usage.
        guard let usage = raw.message?.usage ?? raw.usage else { return nil }

        // Resolve unique ID for deduplication — prefer API-stable requestId/message.id over local uuid.
        // Keys are stored as 64-bit hashes; 0 marks "no key" (never deduplicated).
        let dedupeKey = (raw.requestId ?? raw.message?.id ?? raw.uuid).map(hashKey) ?? 0

        let total = usage.input_tokens + usage.output_tokens
            + usage.cache_creation_input_tokens + usage.cache_read_input_tokens
        let breakdown = TokenUsageBreakdownDisplay(
            totalTokens: total,
            inputTokens: usage.input_tokens,
            cachedInputTokens: usage.cache_read_input_tokens,
            outputTokens: usage.output_tokens,
            reasoningOutputTokens: 0
        )
        // A bad timestamp still consumes its dedupe key, so keep the entry with a nil timestamp.
        return ClaudeCachedEntry(dedupeKey: dedupeKey, timestamp: parseTimestamp(raw.timestamp), usage: breakdown)
    }

    /// FNV-1a over UTF-8; remapped so a real key never collides with the 0 "no key" marker.
    private static func hashKey(_ key: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash == 0 ? 1 : hash
    }

    // MARK: - Timestamp parsing

    // ISO8601DateFormatter is thread-safe for parsing, so these are shared.
    // Transcripts use 3-digit millis (e.g. "...07.417Z") — the fractional formatter handles them.
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
        if let date = fractionalFormatter.date(from: raw) { return date }
        // Fallback to plain internet date-time.
        return plainFormatter.date(from: raw)
    }

    private static let readChunkSize = 256 * 1024
    private static let usageKeyBytes = Array("\"usage\"".utf8)
    private static let cache = ClaudeTranscriptCache()
}

// MARK: - Internal record type

private struct ClaudeTranscriptRecord {
    var timestamp: Date
    var usage: TokenUsageBreakdownDisplay
}

// MARK: - Per-file cache

/// One assistant line reduced to what the aggregation needs.
private struct ClaudeCachedEntry {
    var dedupeKey: UInt64
    var timestamp: Date?
    var usage: TokenUsageBreakdownDisplay
}

private struct ClaudeCachedFile {
    var modifiedAt: Date
    var size: Int
    var entries: [ClaudeCachedEntry]
}

private final class ClaudeTranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: ClaudeCachedFile] = [:]

    func entries(for path: String, modifiedAt: Date, size: Int) -> [ClaudeCachedEntry]? {
        lock.lock()
        defer { lock.unlock() }

        guard
            let file = files[path],
            file.modifiedAt == modifiedAt,
            file.size == size
        else {
            return nil
        }
        return file.entries
    }

    func store(_ entries: [ClaudeCachedEntry], for path: String, modifiedAt: Date, size: Int) {
        lock.lock()
        files[path] = ClaudeCachedFile(modifiedAt: modifiedAt, size: size, entries: entries)
        lock.unlock()
    }

    func retain(paths: Set<String>) {
        lock.lock()
        files = files.filter { paths.contains($0.key) }
        lock.unlock()
    }
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
