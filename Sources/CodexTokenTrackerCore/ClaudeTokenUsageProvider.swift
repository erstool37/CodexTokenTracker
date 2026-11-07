import Foundation

/// Reads Claude Code JSONL transcripts from `~/.claude/projects/` and aggregates token usage
/// into today / 7 days / 28 days. Fable models are excluded entirely. Deduplicates assistant responses by `requestId` (falling back to
/// `message.id` then top-level `uuid`) across files so that responses replayed across resumed
/// or forked transcripts are not double-counted.
///
/// Parsed records persist in an on-disk cache together with each file's parsed byte offset, so a
/// pass reads only what was appended since the previous one. The menu bar app runs passes in a
/// short-lived child process (`ClaudeTranscriptStatsCommand`): parsing gigabytes of JSON leaves a
/// fragmented heap behind, and that heap then dies with the child instead of staying in the app.
public enum ClaudeTokenUsageProvider {
    public static func defaultProjectsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    public static func defaultCacheURL() -> URL {
        AccountTokenUsageLedgerStore.defaultLedgerURL()
            .deletingLastPathComponent()
            .appendingPathComponent("claude-transcript-cache.json")
    }

    /// Entry point. Returns nil when no transcripts or usage are found. Without a `cacheURL`
    /// every pass parses all files of the window from the start.
    public static func load(
        now: Date = Date(),
        projectsDir: URL = defaultProjectsDirectory(),
        cacheURL: URL? = nil
    ) -> TokenUsageStats? {
        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return nil
        }

        let cutoff28 = now.addingTimeInterval(-28 * 24 * 60 * 60)
        var cache = cacheURL.flatMap(ClaudeTranscriptCache.load(from:)) ?? ClaudeTranscriptCache()
        let changed = cache.refresh(under: projectsDir, modifiedSince: cutoff28, parse: parseFile)
        if changed, let cacheURL {
            cache.save(to: cacheURL)
        }

        var seen = Set<UInt64>()
        let records = cache.files.values.flatMap(\.records).filter { record in
            record.key == ClaudeTranscriptRecord.noKey || seen.insert(record.key).inserted
        }
        guard !records.isEmpty else {
            return nil
        }

        return stats(from: records, now: now)
    }

    // MARK: - Aggregation

    private static func stats(from records: [ClaudeTranscriptRecord], now: Date) -> TokenUsageStats {
        let calendar = Calendar.current
        let nowSeconds = now.timeIntervalSince1970
        let weekCutoff = nowSeconds - 7 * 24 * 60 * 60
        let monthCutoff = nowSeconds - 28 * 24 * 60 * 60
        let todayStart = calendar.startOfDay(for: now).timeIntervalSince1970

        let todayRecords = records.filter { $0.timestamp >= todayStart && $0.timestamp <= nowSeconds }
        let weeklyRecords = records.filter { $0.timestamp >= weekCutoff && $0.timestamp <= nowSeconds }
        let monthlyRecords = records.filter { $0.timestamp >= monthCutoff && $0.timestamp <= nowSeconds }

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

    /// Records of the complete lines from `offset` on, and the offset to resume from next time.
    /// Lines of one response repeat its id and usage, so only the first of them is kept.
    static func parseFile(_ fileURL: URL, from offset: UInt64) -> (records: [ClaudeTranscriptRecord], end: UInt64)? {
        var records: [ClaudeTranscriptRecord] = []
        var seen = Set<UInt64>()
        let decoder = JSONDecoder()
        // Only assistant lines carry usage; most transcript bytes are user/tool-result lines.
        let end = autoreleasepool {
            JSONLines.forEach(in: fileURL, from: offset, containing: assistantMarker) { line in
                if let record = parseLine(line, decoder: decoder),
                   record.key == ClaudeTranscriptRecord.noKey || seen.insert(record.key).inserted {
                    records.append(record)
                }
            }
        }
        return end.map { (records, $0) }
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

        return ClaudeTranscriptRecord(
            timestamp: timestamp.timeIntervalSince1970,
            inputTokens: usage.input_tokens,
            outputTokens: usage.output_tokens,
            cacheCreationTokens: usage.cache_creation_input_tokens,
            cacheReadTokens: usage.cache_read_input_tokens,
            // API-stable requestId/message.id over local uuid.
            key: ClaudeTranscriptRecord.key(for: raw.requestId ?? raw.message?.id ?? raw.uuid)
        )
    }
}

// MARK: - Child-process scan

/// The transcript scan as a separate process. The app runs its own executable with
/// `--claude-transcript-stats`; the child scans (through the on-disk cache), prints the stats as
/// JSON and exits, so the app itself only ever holds the final totals.
public enum ClaudeTranscriptStatsCommand {
    public static let argument = "--claude-transcript-stats"

    /// Child side. Exit status 0 with JSON on stdout, 1 when there is nothing to report.
    public static func run() -> Int32 {
        guard let stats = ClaudeTokenUsageProvider.load(cacheURL: ClaudeTokenUsageProvider.defaultCacheURL()),
              let data = try? JSONEncoder().encode(stats) else {
            return 1
        }
        FileHandle.standardOutput.write(data)
        return 0
    }

    /// App side: runs `executable --claude-transcript-stats` and decodes its output. Nil when the
    /// child fails, finds nothing, or outlives `timeout`.
    public static func stats(executable: URL, timeout: TimeInterval = 120) async -> TokenUsageStats? {
        guard let data = await ProcessOutput.run(
            executable: executable,
            arguments: [argument],
            timeout: timeout,
            qualityOfService: .utility
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(TokenUsageStats.self, from: data)
    }
}

/// Stdout of a short command, read off the cooperative pool and killed after `timeout`. Nil on a
/// launch failure, a non-zero exit, or empty output.
enum ProcessOutput {
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        qualityOfService: QualityOfService = .default
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.qualityOfService = qualityOfService
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: process.terminationStatus == 0 && !data.isEmpty ? data : nil)
            }
        }
    }
}

// MARK: - Records and their cache

/// One assistant response: plain numbers only, so tens of thousands of them take a few hundred
/// kilobytes and no per-record heap allocations.
struct ClaudeTranscriptRecord: Codable, Equatable, Sendable {
    /// Seconds since 1970.
    var timestamp: TimeInterval
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    /// 64-bit FNV-1a hash of the response id; `noKey` when the line had none.
    var key: UInt64

    static let noKey: UInt64 = 0

    static func key(for id: String?) -> UInt64 {
        guard let id else { return noKey }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash == noKey ? 1 : hash
    }

    var usage: TokenUsageBreakdownDisplay {
        TokenUsageBreakdownDisplay(
            totalTokens: inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens,
            inputTokens: inputTokens,
            cachedInputTokens: cacheReadTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: 0
        )
    }

    // Stored as a bare array to keep the cache file small.
    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        timestamp = try container.decode(TimeInterval.self)
        inputTokens = try container.decode(Int.self)
        outputTokens = try container.decode(Int.self)
        cacheCreationTokens = try container.decode(Int.self)
        cacheReadTokens = try container.decode(Int.self)
        key = try container.decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(timestamp)
        try container.encode(inputTokens)
        try container.encode(outputTokens)
        try container.encode(cacheCreationTokens)
        try container.encode(cacheReadTokens)
        try container.encode(key)
    }

    init(
        timestamp: TimeInterval,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        key: UInt64
    ) {
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.key = key
    }
}

/// Per-file records of the transcripts in the window, keyed by path. A file that grew is read
/// from where the last pass stopped; one that shrank or was replaced (new inode) is read again
/// from the start; files that left the window or disappeared are dropped.
struct ClaudeTranscriptCache: Codable {
    static let currentVersion = 1

    struct File: Codable {
        var inode: UInt64
        var modifiedAt: TimeInterval
        var size: UInt64
        /// Bytes parsed so far, up to and including the last newline seen.
        var parsedOffset: UInt64
        var records: [ClaudeTranscriptRecord]
    }

    var version = currentVersion
    var files: [String: File] = [:]

    static func load(from url: URL) -> ClaudeTranscriptCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ClaudeTranscriptCache.self, from: data),
              cache.version == currentVersion else {
            return nil
        }
        return cache
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Brings every `.jsonl` under `root` modified since `cutoff` up to date. True when anything
    /// changed.
    mutating func refresh(
        under root: URL,
        modifiedSince cutoff: Date,
        parse: (URL, UInt64) -> (records: [ClaudeTranscriptRecord], end: UInt64)?
    ) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        let cutoffSeconds = cutoff.timeIntervalSince1970
        var seen = Set<String>()
        var changed = false
        while let fileURL = autoreleasepool(invoking: { enumerator.nextObject() as? URL }) {
            guard fileURL.pathExtension == "jsonl" else { continue }
            var info = stat()
            let path = fileURL.path
            guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modifiedAt = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            guard modifiedAt >= cutoffSeconds else { continue }
            seen.insert(path)

            let inode = UInt64(info.st_ino)
            let size = UInt64(info.st_size)
            let previous = files[path]
            if let previous, previous.inode == inode, previous.modifiedAt == modifiedAt, previous.size == size {
                continue
            }
            // Transcripts are append-only, so a grown file continues where the last pass stopped.
            let resumable = previous.map { $0.inode == inode && size >= $0.parsedOffset } ?? false
            let start = resumable ? previous?.parsedOffset ?? 0 : 0
            guard let parsed = parse(fileURL, start) else { continue }
            files[path] = File(
                inode: inode,
                modifiedAt: modifiedAt,
                size: size,
                parsedOffset: parsed.end,
                records: (resumable ? previous?.records ?? [] : []) + parsed.records
            )
            changed = true
        }
        let before = files.count
        files = files.filter { seen.contains($0.key) }
        return changed || files.count != before
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
