import Foundation

enum JSONLines {
    /// Streams a file line by line in 1 MB chunks. Newlines are found with `memchr` and, when a
    /// `marker` is given, lines without it are skipped with `memmem` before any `Data` is built,
    /// so multi-gigabyte transcript folders scan quickly and in bounded memory.
    ///
    /// Reading starts at byte `offset`; the result is the offset just past the last newline, where
    /// the next read of the same append-only file resumes. A trailing line without a newline is
    /// still being written, so it is left for that next read (nil when the file can't be opened).
    @discardableResult
    static func forEach(
        in fileURL: URL,
        from offset: UInt64 = 0,
        containing marker: [UInt8]? = nil,
        _ body: (Data) -> Void
    ) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        if offset > 0 {
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        }

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
        var completeEnd = offset
        while true {
            let chunk: Data?
            do {
                chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            } catch {
                // A read error is not the end of the file: fail, so the caller retries the range.
                return nil
            }
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
            completeEnd += UInt64(consumed)
        }
        return completeEnd
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
