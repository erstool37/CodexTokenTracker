import Foundation

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
