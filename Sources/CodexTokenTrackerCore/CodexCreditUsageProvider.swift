import Foundation

/// Prices local Codex session logs with the Codex credit rate card. Each billed response is
/// attributed to the model and `service_tier` of the latest preceding `turn_context` event in the
/// same file. Parsed files are cached by (mtime, size), so a refresh only re-reads changed logs.
///
/// Newer logs carry one `token_usage_record` per response (unique `response_id`, and it includes
/// compaction requests); those are used when present. Older logs only have `token_count`, which
/// is re-emitted with an unchanged cumulative total after compaction or settings changes, so
/// repeats of the previous total are skipped.
public enum CodexCreditUsageProvider {
    private static let cache = FileRecordCache<CreditUsageRecord>()

    public static let note = "Codex rate card · this Mac"
    /// Monthly Codex credit allowance on this account.
    public static let monthlyAllowance: Double = 7000

    public static func load(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"),
        now: Date = Date()
    ) -> CreditUsageStats {
        let cutoff = CreditUsageStats.windowStart(now: now)
        let roots = ["sessions", "archived_sessions"].map {
            codexHome.appendingPathComponent($0, isDirectory: true)
        }
        let records = cache.records(under: roots, modifiedSince: cutoff, parse: parseFile)
        return CreditUsageStats.aggregate(records, unit: .codexCredits, note: note, now: now)
    }

    static func parseFile(_ fileURL: URL) -> [CreditUsageRecord] {
        var model = "unknown"
        var serviceTier: String?
        var usageRecords: [CreditUsageRecord] = []
        var tokenCountRecords: [CreditUsageRecord] = []
        var seenResponses = Set<String>()
        var previousTotal: CodexCreditEvent.Usage?
        let decoder = JSONDecoder()

        func price(_ usage: CodexCreditEvent.Usage, at timestamp: Date) -> CreditUsageRecord {
            let cached = min(usage.cached_input_tokens, usage.input_tokens)
            let counts = CreditTokenCounts(
                uncachedInput: usage.input_tokens - cached,
                cachedInput: cached,
                output: usage.output_tokens
            )
            let credits = CodexCreditRates.rate(forModel: model).map {
                counts.cost(at: $0, multiplier: CodexCreditRates.multiplier(serviceTier: serviceTier, model: model))
            }
            return CreditUsageRecord(timestamp: timestamp, model: model, credits: credits, tokens: counts.total)
        }

        JSONLines.forEach(in: fileURL) { line in
            guard let event = try? decoder.decode(CodexCreditEvent.self, from: line) else {
                return
            }
            switch event.type {
            case "turn_context":
                if let next = event.payload.model {
                    model = next
                }
                serviceTier = event.payload.service_tier
            case "token_usage_record":
                guard
                    let usage = event.payload.usage,
                    let timestamp = JSONLines.parseTimestamp(event.timestamp),
                    seenResponses.insert(event.payload.response_id ?? "\(event.timestamp)").inserted
                else {
                    return
                }
                usageRecords.append(price(usage, at: timestamp))
            case "event_msg" where event.payload.type == "token_count":
                guard
                    let info = event.payload.info,
                    let usage = info.last_token_usage,
                    let timestamp = JSONLines.parseTimestamp(event.timestamp)
                else {
                    return
                }
                defer { previousTotal = info.total_token_usage ?? previousTotal }
                if let total = info.total_token_usage, total == previousTotal, total.input_tokens + total.output_tokens > 0 {
                    return
                }
                tokenCountRecords.append(price(usage, at: timestamp))
            default:
                return
            }
        }
        return usageRecords.isEmpty ? tokenCountRecords : usageRecords
    }
}

private struct CodexCreditEvent: Decodable {
    let timestamp: String
    let type: String
    let payload: Payload

    struct Payload: Decodable {
        let type: String?
        let model: String?
        let service_tier: String?
        let info: Info?
        let response_id: String?
        let usage: Usage?
    }

    struct Info: Decodable {
        let total_token_usage: Usage?
        let last_token_usage: Usage?
    }

    struct Usage: Decodable, Equatable {
        let input_tokens: Int
        let cached_input_tokens: Int
        let output_tokens: Int

        private enum CodingKeys: String, CodingKey {
            case input_tokens, cached_input_tokens, output_tokens
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .input_tokens)) ?? 0
            cached_input_tokens = (try? container.decodeIfPresent(Int.self, forKey: .cached_input_tokens)) ?? 0
            output_tokens = (try? container.decodeIfPresent(Int.self, forKey: .output_tokens)) ?? 0
        }
    }
}

// MARK: - Shared JSONL helpers

enum JSONLines {
    /// Streams a file line by line in 64 KB chunks without loading it whole.
    static func forEach(in fileURL: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }

        var pending = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstRange(of: newlineData) {
                let line = pending.subdata(in: pending.startIndex..<newline.lowerBound)
                pending.removeSubrange(pending.startIndex..<newline.upperBound)
                if !line.isEmpty {
                    body(line)
                }
            }
        }
        if !pending.isEmpty {
            body(pending)
        }
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static let newlineData = Data([0x0A])
}

/// Per-file parse cache keyed by path and invalidated by (mtime, size). Files that drop out of the
/// window are evicted on each pass.
final class FileRecordCache<Record: Sendable>: @unchecked Sendable {
    private struct Entry {
        var modifiedAt: Date
        var size: Int
        var records: [Record]
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func records(under roots: [URL], modifiedSince cutoff: Date, parse: (URL) -> [Record]) -> [Record] {
        var seen = Set<String>()
        var result: [Record] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            ) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                guard
                    let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                    values.isRegularFile != false,
                    let modifiedAt = values.contentModificationDate,
                    modifiedAt >= cutoff,
                    seen.insert(fileURL.path).inserted
                else {
                    continue
                }
                let size = values.fileSize ?? 0
                let cached: [Record]? = lock.withLock {
                    guard let entry = entries[fileURL.path], entry.modifiedAt == modifiedAt, entry.size == size else {
                        return nil
                    }
                    return entry.records
                }
                if let cached {
                    result.append(contentsOf: cached)
                    continue
                }
                let parsed = parse(fileURL)
                lock.withLock {
                    entries[fileURL.path] = Entry(modifiedAt: modifiedAt, size: size, records: parsed)
                }
                result.append(contentsOf: parsed)
            }
        }
        lock.withLock {
            entries = entries.filter { seen.contains($0.key) }
        }
        return result
    }
}
