import Foundation

enum JSONLines {
    /// Streams a file line by line in 1 MB chunks. Newlines are found with `memchr` and, when a
    /// `marker` is given, lines without it are skipped with `memmem` before any `Data` is built,
    /// so multi-gigabyte transcript folders scan quickly and in bounded memory.
    static func forEach(in fileURL: URL, containing marker: [UInt8]? = nil, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? handle.close() }

        let marker = marker?.isEmpty == true ? nil : marker
        func emit(_ start: UnsafePointer<UInt8>, _ count: Int) {
            guard count > 0 else { return }
            if let marker, marker.withUnsafeBufferPointer({ memmem(start, count, $0.baseAddress, $0.count) }) == nil {
                return
            }
            body(Data(bytes: start, count: count))
        }

        // Holds the unfinished tail of the previous chunk plus the new chunk.
        var buffer: [UInt8] = []
        while true {
            let chunk: Data? = autoreleasepool { try? handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            // The carried-over tail has no newline, so the search resumes at the new bytes.
            var searchFrom = buffer.count
            buffer.append(contentsOf: chunk)
            var consumed = 0
            buffer.withUnsafeBufferPointer { bytes in
                guard let base = bytes.baseAddress else { return }
                while searchFrom < bytes.count,
                      let newline = memchr(base + searchFrom, 0x0A, bytes.count - searchFrom) {
                    let end = base.distance(to: newline.assumingMemoryBound(to: UInt8.self))
                    emit(base + consumed, end - consumed)
                    consumed = end + 1
                    searchFrom = consumed
                }
            }
            buffer.removeFirst(consumed)
        }
        buffer.withUnsafeBufferPointer { bytes in
            if let base = bytes.baseAddress { emit(base, bytes.count) }
        }
    }

    // ISO8601DateFormatter is thread-safe; building one per line dominated the old scan's profile.
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

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
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
                let parsed = autoreleasepool { parse(fileURL) }
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
