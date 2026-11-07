import Foundation

/// Persists the raw body of the last successful API response so the tracker can keep showing the
/// last known values after a failed call or an app restart. Files live next to the token ledger
/// in `~/Library/Application Support/CodexTokenTracker/`.
public struct LastGoodPayloadStore: Sendable {
    public var url: URL

    public init(fileName: String) {
        url = AccountTokenUsageLedgerStore.defaultLedgerURL()
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }

    public init(url: URL) {
        self.url = url
    }

    public func save(_ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// The saved body and when it was saved (the file's modification time). Read from the file
    /// system each time, not via `URL.resourceValues`: those are cached on the URL, so a long-lived
    /// store kept reporting the first modification time it saw and the other Mac took fresh
    /// numbers for days-old ones.
    public func load() -> (data: Data, savedAt: Date)? {
        guard
            let data = try? Data(contentsOf: url),
            let savedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else {
            return nil
        }
        return (data, savedAt)
    }
}
