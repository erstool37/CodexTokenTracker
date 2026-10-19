import Foundation

public final class AccountTokenUsageLedgerStore: @unchecked Sendable {
    private static let lock = NSLock()
    /// Decoded ledger per file, valid while the file's modification date and size are unchanged.
    /// Guarded by `lock`.
    nonisolated(unsafe) private static var cachedLedgers: [String: CachedLedger] = [:]

    private let url: URL

    public init(url: URL = AccountTokenUsageLedgerStore.defaultLedgerURL()) {
        self.url = url
    }

    public static func defaultLedgerURL() -> URL {
        let fileManager = FileManager.default
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return baseURL
            .appendingPathComponent("CodexTokenTracker", isDirectory: true)
            .appendingPathComponent("account-token-usage.json")
    }

    public func stats(
        for account: AccountDisplay,
        records: [TokenUsageSessionRecord],
        now: Date,
        calendar: Calendar = .current
    ) -> TokenUsageStats {
        Self.lock.lock()
        defer {
            Self.lock.unlock()
        }

        var ledger = loadLedger() ?? AccountTokenUsageLedger()
        var changed = false
        let identity = AccountTokenUsageAccount(account: account)
        if ledger.accounts[identity.key] != identity {
            ledger.accounts[identity.key] = identity
            changed = true
        }

        let sourceIDs = Set(records.compactMap(\.sourceID))
        if ledger.startedAt == nil {
            ledger.startedAt = now
            ledger.baselineSourceIDs.formUnion(sourceIDs)
            changed = true
        }

        for record in records {
            guard let sourceID = record.sourceID else {
                continue
            }
            if ledger.baselineSourceIDs.contains(sourceID) || ledger.eventsBySourceID[sourceID] != nil {
                continue
            }
            ledger.eventsBySourceID[sourceID] = AccountTokenUsageStoredEvent(
                accountKey: identity.key,
                updatedAt: record.updatedAt,
                usage: record.usage
            )
            changed = true
        }

        if changed {
            saveLedger(ledger)
        }

        var stats = TokenUsageStatsProvider.stats(
            from: ledger.records(forAccountKey: identity.key),
            now: now,
            calendar: calendar
        )
        stats.source = identity.displayName
        return stats
    }

    private func loadLedger() -> AccountTokenUsageLedger? {
        let signature = fileSignature()
        if let signature, let cached = Self.cachedLedgers[url.path], cached.signature == signature {
            return cached.ledger
        }
        guard let data = try? Data(contentsOf: url) else {
            Self.cachedLedgers[url.path] = nil
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let ledger = try? decoder.decode(AccountTokenUsageLedger.self, from: data) else {
            Self.cachedLedgers[url.path] = nil
            return nil
        }
        if let signature {
            Self.cachedLedgers[url.path] = CachedLedger(signature: signature, ledger: ledger)
        }
        return ledger
    }

    private func saveLedger(_ ledger: AccountTokenUsageLedger) {
        do {
            let directoryURL = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(ledger)
            try data.write(to: url, options: .atomic)
            if let signature = fileSignature() {
                Self.cachedLedgers[url.path] = CachedLedger(signature: signature, ledger: ledger)
            }
        } catch {
            Self.cachedLedgers[url.path] = nil
        }
    }

    private func fileSignature() -> LedgerFileSignature? {
        guard
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modifiedAt = values.contentModificationDate,
            let size = values.fileSize
        else {
            return nil
        }
        return LedgerFileSignature(modifiedAt: modifiedAt, size: size)
    }
}

private struct LedgerFileSignature: Equatable {
    var modifiedAt: Date
    var size: Int
}

private struct CachedLedger {
    var signature: LedgerFileSignature
    var ledger: AccountTokenUsageLedger
}

private struct AccountTokenUsageLedger: Codable {
    var version: Int
    var startedAt: Date?
    var baselineSourceIDs: Set<String>
    var accounts: [String: AccountTokenUsageAccount]
    var eventsBySourceID: [String: AccountTokenUsageStoredEvent]

    init() {
        self.version = 1
        self.startedAt = nil
        self.baselineSourceIDs = []
        self.accounts = [:]
        self.eventsBySourceID = [:]
    }

    func records(forAccountKey accountKey: String) -> [TokenUsageSessionRecord] {
        eventsBySourceID.values.compactMap { event in
            guard event.accountKey == accountKey else {
                return nil
            }
            return TokenUsageSessionRecord(updatedAt: event.updatedAt, usage: event.usage)
        }
    }
}

private struct AccountTokenUsageStoredEvent: Codable, Equatable {
    var accountKey: String
    var updatedAt: Date
    var usage: TokenUsageBreakdownDisplay
}

private struct AccountTokenUsageAccount: Codable, Equatable {
    var key: String
    var displayName: String
    var kind: String
    var plan: String?

    init(account: AccountDisplay) {
        self.key = account.tokenUsageAccountKey
        self.displayName = account.title
        self.kind = account.kind
        self.plan = account.plan
    }
}

private extension AccountDisplay {
    var tokenUsageAccountKey: String {
        let kindKey = normalizedAccountComponent(kind)
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(kindKey):\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        }
        if let plan, !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(kindKey):plan:\(normalizedAccountComponent(plan))"
        }
        if requiresOpenAIAuth {
            return "\(kindKey):auth-required"
        }
        return kindKey
    }

    func normalizedAccountComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
    }
}
