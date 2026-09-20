import Foundation

/// Raw byte searches over `Data`, used by the transcript scanners.
///
/// `Data.firstRange(of:)` resolves to the generic `DataProtocol` implementation, which walks the
/// buffer through `Collection` subscript reads one byte at a time. Profiling a cold scan of the
/// 1.8 GB transcript corpus put 80% of all samples inside that single call — it, not file I/O or
/// JSON decoding, was what made a scan cost ~85 s of CPU. `memchr` and `memmem` do the same work
/// against a flat pointer and are the reason a scan now finishes in a few seconds.
enum ByteScanning {
    /// Index of the next occurrence of `byte` at or after `start`, or nil.
    /// `start` is an absolute index into `data`.
    static func firstIndex(of byte: UInt8, in data: Data, from start: Data.Index) -> Data.Index? {
        guard start < data.endIndex else {
            return nil
        }
        let offset = start - data.startIndex
        return data.withUnsafeBytes { raw -> Data.Index? in
            guard let base = raw.baseAddress, raw.count > offset else {
                return nil
            }
            guard let hit = memchr(base + offset, Int32(byte), raw.count - offset) else {
                return nil
            }
            return data.startIndex + (UnsafeRawPointer(hit) - base)
        }
    }

    /// Whether `haystack` contains `needle`.
    static func contains(_ needle: [UInt8], in haystack: Data.SubSequence) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }
        return haystack.withUnsafeBytes { hay -> Bool in
            guard let hayBase = hay.baseAddress else {
                return false
            }
            return needle.withUnsafeBytes { nee -> Bool in
                guard let neeBase = nee.baseAddress else {
                    return false
                }
                return memmem(hayBase, hay.count, neeBase, nee.count) != nil
            }
        }
    }
}
