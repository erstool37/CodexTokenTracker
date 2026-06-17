import Foundation

public enum TokenUsageStatsProvider {
    private static let cache = TokenUsageStatsCache()

    public static func load(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        now: Date = Date()
    ) -> TokenUsageStats {
        let monthStart = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let records = sessionRecords(in: codexHome, modifiedSince: monthStart)
        return stats(from: records, now: now)
    }

    public static func load(
        for account: AccountDisplay,
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        ledgerURL: URL = AccountTokenUsageLedgerStore.defaultLedgerURL(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenUsageStats {
        let monthStart = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let records = sessionRecords(in: codexHome, modifiedSince: monthStart)
        return AccountTokenUsageLedgerStore(url: ledgerURL).stats(
            for: account,
            records: records,
            now: now,
            calendar: calendar
        )
    }

    public static func stats(
        from records: [TokenUsageSessionRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenUsageStats {
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-28 * 24 * 60 * 60)
        let todayStart = calendar.startOfDay(for: now)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? now
        let todayRecords = records.filter { $0.updatedAt >= todayStart && $0.updatedAt < tomorrowStart && $0.updatedAt <= now }
        let weeklyRecords = records.filter { $0.updatedAt >= weekStart && $0.updatedAt <= now }
        let monthlyRecords = records.filter { $0.updatedAt >= monthStart && $0.updatedAt <= now }

        return TokenUsageStats(
            today: periodStats(label: "Today", records: todayRecords),
            weekly: periodStats(label: "7 days", records: weeklyRecords),
            monthly: periodStats(label: "28 days", records: monthlyRecords),
            source: "~/.codex/sessions"
        )
    }

    private static func periodStats(label: String, records: [TokenUsageSessionRecord]) -> TokenUsagePeriodStats {
        TokenUsagePeriodStats(
            label: label,
            sessionCount: records.count,
            usage: records.reduce(.zero) { $0 + $1.usage }
        )
    }

    private static func sessionRecords(in codexHome: URL, modifiedSince cutoff: Date) -> [TokenUsageSessionRecord] {
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
        var seenPaths = Set<String>()
        let records = roots.flatMap { root in
            sessionRecordsUnderRoot(root, modifiedSince: cutoff, seenPaths: &seenPaths)
        }
        cache.retain(paths: seenPaths)
        return records
    }

    private static func sessionRecordsUnderRoot(
        _ root: URL,
        modifiedSince cutoff: Date,
        seenPaths: inout Set<String>
    ) -> [TokenUsageSessionRecord] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else {
            return []
        }

        var records: [TokenUsageSessionRecord] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let metadata = fileMetadata(for: fileURL) else {
                continue
            }
            if metadata.modifiedAt < cutoff {
                continue
            }
            seenPaths.insert(fileURL.path)
            if let cached = cache.record(
                for: fileURL.path,
                modifiedAt: metadata.modifiedAt,
                size: metadata.size
            ) {
                records.append(contentsOf: cached)
                continue
            }

            let fileRecords = sessionRecords(from: fileURL)
            cache.store(
                fileRecords,
                for: fileURL.path,
                modifiedAt: metadata.modifiedAt,
                size: metadata.size
            )
            records.append(contentsOf: fileRecords)
        }
        return records
    }

    private static func fileMetadata(for fileURL: URL) -> TokenUsageFileMetadata? {
        guard
            let values = try? fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
                .isRegularFileKey
            ]),
            values.isRegularFile != false,
            let modifiedAt = values.contentModificationDate
        else {
            return nil
        }
        return TokenUsageFileMetadata(modifiedAt: modifiedAt, size: values.fileSize ?? 0)
    }

    private static func sessionRecords(from fileURL: URL) -> [TokenUsageSessionRecord] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer {
            try? handle.close()
        }

        let decoder = JSONDecoder()
        var records: [TokenUsageSessionRecord] = []
        var pendingLine = Data()
        var previousTotalUsage: TokenUsageBreakdownDisplay?
        var lineNumber = 0

        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                break
            }
            pendingLine.append(chunk)

            while let newlineRange = pendingLine.firstRange(of: newlineData) {
                let line = pendingLine.subdata(in: pendingLine.startIndex..<newlineRange.lowerBound)
                pendingLine.removeSubrange(pendingLine.startIndex..<newlineRange.upperBound)
                lineNumber += 1
                if let record = tokenUsageRecord(
                    from: line,
                    decoder: decoder,
                    previousTotalUsage: &previousTotalUsage,
                    sourceID: "\(fileURL.path):\(lineNumber)"
                ) {
                    records.append(record)
                }
            }
        }

        if !pendingLine.isEmpty {
            lineNumber += 1
            if let record = tokenUsageRecord(
                from: pendingLine,
                decoder: decoder,
                previousTotalUsage: &previousTotalUsage,
                sourceID: "\(fileURL.path):\(lineNumber)"
            ) {
                records.append(record)
            }
        }

        return records
    }

    private static func tokenUsageRecord(
        from line: Data,
        decoder: JSONDecoder,
        previousTotalUsage: inout TokenUsageBreakdownDisplay?,
        sourceID: String
    ) -> TokenUsageSessionRecord? {
        guard !line.isEmpty else {
            return nil
        }
        guard
            let event = try? decoder.decode(TokenCountEvent.self, from: line),
            event.type == "event_msg",
            event.payload.type == "token_count",
            let info = event.payload.info,
            let updatedAt = parseTimestamp(event.timestamp)
        else {
            return nil
        }
        let usage = info.lastTokenUsage ?? usageDelta(
            currentTotal: info.totalTokenUsage,
            previousTotal: previousTotalUsage
        )
        previousTotalUsage = info.totalTokenUsage
        return TokenUsageSessionRecord(updatedAt: updatedAt, usage: usage, sourceID: sourceID)
    }

    private static func usageDelta(
        currentTotal: TokenUsageBreakdownDisplay,
        previousTotal: TokenUsageBreakdownDisplay?
    ) -> TokenUsageBreakdownDisplay {
        guard let previousTotal else {
            return currentTotal
        }
        if currentTotal.totalTokens < previousTotal.totalTokens {
            return currentTotal
        }
        return TokenUsageBreakdownDisplay(
            totalTokens: max(0, currentTotal.totalTokens - previousTotal.totalTokens),
            inputTokens: max(0, currentTotal.inputTokens - previousTotal.inputTokens),
            cachedInputTokens: max(0, currentTotal.cachedInputTokens - previousTotal.cachedInputTokens),
            outputTokens: max(0, currentTotal.outputTokens - previousTotal.outputTokens),
            reasoningOutputTokens: max(0, currentTotal.reasoningOutputTokens - previousTotal.reasoningOutputTokens)
        )
    }

    private static func parseTimestamp(_ raw: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: raw) {
            return date
        }

        let fractionalISOFormatter = ISO8601DateFormatter()
        fractionalISOFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalISOFormatter.date(from: raw)
    }

    private static let newlineData = Data([0x0A])
}

private final class TokenUsageStatsCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: CachedTokenUsageFile] = [:]

    func record(for path: String, modifiedAt: Date, size: Int) -> [TokenUsageSessionRecord]? {
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

    func store(_ records: [TokenUsageSessionRecord], for path: String, modifiedAt: Date, size: Int) {
        lock.lock()
        entries[path] = CachedTokenUsageFile(modifiedAt: modifiedAt, size: size, records: records)
        lock.unlock()
    }

    func retain(paths: Set<String>) {
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        lock.unlock()
    }
}

private struct TokenUsageFileMetadata {
    var modifiedAt: Date
    var size: Int
}

private struct CachedTokenUsageFile {
    var modifiedAt: Date
    var size: Int
    var records: [TokenUsageSessionRecord]
}

public struct TokenUsageSessionRecord: Equatable, Sendable {
    public var updatedAt: Date
    public var usage: TokenUsageBreakdownDisplay
    public var sourceID: String?

    public init(updatedAt: Date, usage: TokenUsageBreakdownDisplay, sourceID: String? = nil) {
        self.updatedAt = updatedAt
        self.usage = usage
        self.sourceID = sourceID
    }
}

private struct TokenCountEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: TokenCountPayload
}

private struct TokenCountPayload: Decodable {
    let type: String
    let info: TokenCountInfo?
}

private struct TokenCountInfo: Decodable {
    let totalTokenUsage: TokenUsageBreakdownDisplay
    let lastTokenUsage: TokenUsageBreakdownDisplay?

    private enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
        case lastTokenUsage = "last_token_usage"
    }
}

extension TokenUsageBreakdownDisplay: Codable {
    private enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0,
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            cachedInputTokens: try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0,
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            reasoningOutputTokens: try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(inputTokens, forKey: .inputTokens)
        try container.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try container.encode(outputTokens, forKey: .outputTokens)
        try container.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
    }
}
