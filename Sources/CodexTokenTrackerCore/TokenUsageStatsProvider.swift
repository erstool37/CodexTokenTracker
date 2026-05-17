import Foundation

public enum TokenUsageStatsProvider {
    private static let cache = TokenUsageStatsCache()

    public static func load(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        now: Date = Date()
    ) -> TokenUsageStats {
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        return stats(from: sessionRecords(in: codexHome, modifiedSince: monthStart), now: now)
    }

    public static func stats(from records: [TokenUsageSessionRecord], now: Date = Date()) -> TokenUsageStats {
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let monthStart = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let weeklyRecords = records.filter { $0.updatedAt >= weekStart && $0.updatedAt <= now }
        let monthlyRecords = records.filter { $0.updatedAt >= monthStart && $0.updatedAt <= now }

        return TokenUsageStats(
            weekly: periodStats(label: "7 days", records: weeklyRecords),
            monthly: periodStats(label: "30 days", records: monthlyRecords),
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
            options: [.skipsHiddenFiles]
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
                if let record = cached {
                    records.append(record)
                }
                continue
            }

            let record = sessionRecord(from: fileURL)
            cache.store(
                record,
                for: fileURL.path,
                modifiedAt: metadata.modifiedAt,
                size: metadata.size
            )
            if let record {
                records.append(record)
            }
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

    private static func sessionRecord(from fileURL: URL) -> TokenUsageSessionRecord? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let decoder = JSONDecoder()
        guard var offset = try? handle.seekToEnd() else {
            return nil
        }
        var suffix = Data()

        while offset > 0 {
            let readSize = min(64 * 1024, Int(offset))
            offset -= UInt64(readSize)
            do {
                try handle.seek(toOffset: offset)
            } catch {
                break
            }
            guard var chunk = try? handle.read(upToCount: readSize), !chunk.isEmpty else {
                break
            }
            chunk.append(suffix)

            var searchEnd = chunk.endIndex
            while let newlineRange = chunk.range(
                of: newlineData,
                options: .backwards,
                in: chunk.startIndex..<searchEnd
            ) {
                let line = chunk.subdata(in: newlineRange.upperBound..<searchEnd)
                if let record = tokenUsageRecord(from: line, decoder: decoder) {
                    return record
                }
                searchEnd = newlineRange.lowerBound
            }

            suffix = chunk.subdata(in: chunk.startIndex..<searchEnd)
        }

        if !suffix.isEmpty, let record = tokenUsageRecord(from: suffix, decoder: decoder) {
            return record
        }

        return nil
    }

    private static func tokenUsageRecord(from line: Data, decoder: JSONDecoder) -> TokenUsageSessionRecord? {
        guard !line.isEmpty else {
            return nil
        }
        guard
            let event = try? decoder.decode(TokenCountEvent.self, from: line),
            event.type == "event_msg",
            event.payload.type == "token_count",
            let updatedAt = parseTimestamp(event.timestamp)
        else {
            return nil
        }
        return TokenUsageSessionRecord(updatedAt: updatedAt, usage: event.payload.info.totalTokenUsage)
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

    func record(for path: String, modifiedAt: Date, size: Int) -> TokenUsageSessionRecord?? {
        lock.lock()
        defer { lock.unlock() }

        guard
            let entry = entries[path],
            entry.modifiedAt == modifiedAt,
            entry.size == size
        else {
            return nil
        }
        return .some(entry.record)
    }

    func store(_ record: TokenUsageSessionRecord?, for path: String, modifiedAt: Date, size: Int) {
        lock.lock()
        entries[path] = CachedTokenUsageFile(modifiedAt: modifiedAt, size: size, record: record)
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
    var record: TokenUsageSessionRecord?
}

public struct TokenUsageSessionRecord: Equatable, Sendable {
    public var updatedAt: Date
    public var usage: TokenUsageBreakdownDisplay

    public init(updatedAt: Date, usage: TokenUsageBreakdownDisplay) {
        self.updatedAt = updatedAt
        self.usage = usage
    }
}

private struct TokenCountEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: TokenCountPayload
}

private struct TokenCountPayload: Decodable {
    let type: String
    let info: TokenCountInfo
}

private struct TokenCountInfo: Decodable {
    let totalTokenUsage: TokenUsageBreakdownDisplay

    private enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
    }
}

extension TokenUsageBreakdownDisplay: Decodable {
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
}
