import Foundation
import os

/// Team (organization seat) or personal (individual Pro/Max) Claude plan.
public enum ClaudeAccountKind: String, Codable, Sendable {
    case team
    case personal
}

/// Which organization a Claude Code login belongs to. The same email can sign in to a team
/// organization and to a personal one; they have separate usage limits, so the organization —
/// not the email — is what identifies an account here.
public struct ClaudeAccountIdentity: Codable, Equatable, Sendable {
    public var organizationUUID: String
    public var organizationName: String?
    /// `/api/oauth/profile` organization type: "claude_team", "claude_enterprise", "claude_max", …
    public var organizationType: String?
    /// Claude Code's own record in the keychain: "team", "enterprise", "max", "pro", …
    public var subscriptionType: String?
    /// e.g. "default_claude_max_5x".
    public var rateLimitTier: String?

    public init(
        organizationUUID: String,
        organizationName: String? = nil,
        organizationType: String? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.organizationUUID = organizationUUID
        self.organizationName = organizationName
        self.organizationType = organizationType
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var kind: ClaudeAccountKind {
        let markers = [organizationType, subscriptionType].compactMap { $0?.lowercased() }
        return markers.contains { $0.contains("team") || $0.contains("enterprise") } ? .team : .personal
    }

    /// "LAMP · Team" or "Personal · Max 5x".
    public var label: String {
        switch kind {
        case .team:
            let name = organizationName?.trimmingCharacters(in: .whitespaces)
            return [name.flatMap { $0.isEmpty ? nil : $0 }, "Team"].compactMap { $0 }.joined(separator: " · ")
        case .personal:
            return ["Personal", planName].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// "Max 5x", "Max 20x", "Pro" — from the rate-limit tier, else the plan type.
    private var planName: String? {
        if let tier = rateLimitTier?.lowercased(), tier.contains("max") {
            if let multiplier = tier.split(separator: "_").last, multiplier.hasSuffix("x") {
                return "Max \(multiplier)"
            }
            return "Max"
        }
        let raw = (subscriptionType ?? organizationType?.replacingOccurrences(of: "claude_", with: ""))?
            .trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty else { return nil }
        return AdaptiveLabel.humanize(raw)
    }
}

/// What one Mac publishes for the other: the raw usage payload of every Claude Code login it
/// holds. Written to `claude-accounts-published.json` in the app's Application Support folder
/// and read by the peer over SSH. Usage numbers and organization names only — no tokens.
public struct ClaudePublishedAccounts: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var identity: ClaudeAccountIdentity
        /// When `usage` came back from the API (seconds since 1970).
        public var fetchedAt: TimeInterval
        /// Raw `/api/oauth/usage` response body (UTF-8 JSON).
        public var usage: String

        public init(identity: ClaudeAccountIdentity, fetchedAt: TimeInterval, usage: String) {
            self.identity = identity
            self.fetchedAt = fetchedAt
            self.usage = usage
        }
    }

    public var version: Int
    public var machineID: String
    public var machineName: String
    public var publishedAt: TimeInterval
    public var accounts: [Account]

    public init(machineID: String, machineName: String, publishedAt: TimeInterval, accounts: [Account]) {
        version = 1
        self.machineID = machineID
        self.machineName = machineName
        self.publishedAt = publishedAt
        self.accounts = accounts
    }
}

/// One account as the popover shows it, from this Mac or from a peer.
public struct ClaudeAccountEntry: Equatable, Sendable {
    public var identity: ClaudeAccountIdentity
    public var snapshot: CodexStatusSnapshot?
    /// Machine whose Claude Code login produced the data.
    public var machineName: String
    public var isLocal: Bool
    /// Why there is no fresh data, when there isn't.
    public var errorMessage: String?

    public init(
        identity: ClaudeAccountIdentity,
        snapshot: CodexStatusSnapshot?,
        machineName: String,
        isLocal: Bool,
        errorMessage: String? = nil
    ) {
        self.identity = identity
        self.snapshot = snapshot
        self.machineName = machineName
        self.isLocal = isLocal
        self.errorMessage = errorMessage
    }
}

public enum ClaudeAccountMerger {
    /// One entry per organization. Where two Macs report the same organization, the one with the
    /// newest usage wins; an entry with data always beats one without.
    public static func merge(_ entries: [ClaudeAccountEntry]) -> [ClaudeAccountEntry] {
        var best: [String: ClaudeAccountEntry] = [:]
        for entry in entries {
            let key = entry.identity.organizationUUID
            guard let current = best[key] else {
                best[key] = entry
                continue
            }
            if isBetter(entry, than: current) {
                best[key] = entry
            }
        }
        return best.values.sorted(by: displayOrder)
    }

    private static func isBetter(_ lhs: ClaudeAccountEntry, than rhs: ClaudeAccountEntry) -> Bool {
        switch (lhs.snapshot?.refreshedAt, rhs.snapshot?.refreshedAt) {
        case let (l?, r?):
            return l > r || (l == r && lhs.isLocal && !rhs.isLocal)
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return lhs.isLocal && !rhs.isLocal
        }
    }

    /// Team accounts first (left in the menu bar), then personal ones.
    private static func displayOrder(_ lhs: ClaudeAccountEntry, _ rhs: ClaudeAccountEntry) -> Bool {
        if lhs.identity.kind != rhs.identity.kind {
            return lhs.identity.kind == .team
        }
        return lhs.identity.label.localizedStandardCompare(rhs.identity.label) == .orderedAscending
    }

    /// Combine the accounts into the single snapshot the Claude pane renders: one limit bucket
    /// per account, labeled with its organization. Bucket ids start with `claude-team-` or
    /// `claude-personal-`, which the menu bar uses to place team left and personal right.
    public static func combinedSnapshot(
        _ entries: [ClaudeAccountEntry],
        now: Date,
        localStats: TokenUsageStats?
    ) -> CodexStatusSnapshot {
        let buckets = entries.map { entry -> LimitBucketDisplay in
            let windows = entry.snapshot?.limits.flatMap(\.windows) ?? []
            return LimitBucketDisplay(
                id: "claude-\(entry.identity.kind.rawValue)-\(entry.identity.organizationUUID)",
                label: entry.identity.label,
                windows: windows,
                creditsText: entry.snapshot?.limits.compactMap(\.creditsText).first,
                statusText: statusText(for: entry, now: now)
            )
        }
        let refreshedAt = entries.compactMap { $0.snapshot?.refreshedAt }.max() ?? now
        return CodexStatusSnapshot(
            account: AccountDisplay(kind: "Claude", email: nil, plan: nil, requiresOpenAIAuth: false),
            limits: buckets,
            onlineTokenStats: localStats,
            refreshedAt: refreshedAt,
            source: "anthropic oauth usage"
        )
    }

    /// Shown under an account only when it needs saying: data from the other Mac, old data,
    /// or no data at all.
    static func statusText(for entry: ClaudeAccountEntry, now: Date) -> String? {
        guard let snapshot = entry.snapshot else {
            return entry.errorMessage ?? "No usage yet"
        }
        var parts: [String] = []
        if !entry.isLocal {
            parts.append("via \(entry.machineName)")
        }
        if now.timeIntervalSince(snapshot.refreshedAt) > StatusFormatter.staleInterval {
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDate(snapshot.refreshedAt, inSameDayAs: now) ? .none : .short
            formatter.timeStyle = .short
            parts.append("as of \(formatter.string(from: snapshot.refreshedAt))")
        }
        if let errorMessage = entry.errorMessage, entry.isLocal {
            parts.append(errorMessage)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// All Claude accounts, on any Mac: every Claude Code login on this machine (the default one and
/// one per `CLAUDE_CONFIG_DIR`), plus whatever the other Macs publish, read over SSH. Each login's
/// usage is fetched only by the Mac that holds it, then shared — so a team login on one Mac and a
/// personal login on another both show on both, with no tokens leaving either machine.
public final class ClaudeAccountsProvider: StatusProviding, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.erstool37.CodexTokenTracker", category: "ClaudeAccounts")
    public static let publishedFileName = "claude-accounts-published.json"
    /// SSH aliases tried for peers when `claude-peers.txt` is absent. Unknown or self aliases are
    /// harmless: unresolvable ones fail at once, and a Mac recognises its own file by machine id.
    public static let defaultPeerHosts = ["home", "pro"]

    private let session: URLSession
    private let supportDirectory: URL
    private let machineID: String
    private let machineName: String

    private let lock = NSLock()
    private var providers: [String: ClaudeUsageProvider] = [:]
    private var lastServiceScan: Date?
    private var identities: [String: CachedIdentity] = [:]
    private var peerFiles: [String: ClaudePublishedAccounts] = [:]
    private var lastPeerFetch: Date?
    private var peerTask: Task<Void, Never>?
    private var latestLocalStats: TokenUsageStats?
    private var localStatsTask: Task<Void, Never>?
    private var peerUpdateHandler: (@Sendable () -> Void)?

    private let serviceScanInterval: TimeInterval = 600
    private let peerFetchInterval: TimeInterval = 60
    private let identityRefreshInterval: TimeInterval = 6 * 3600

    private struct CachedIdentity: Codable {
        var identity: ClaudeAccountIdentity
        var fetchedAt: TimeInterval
    }

    public init(session: URLSession = .shared, supportDirectory: URL? = nil) {
        self.session = session
        let directory = supportDirectory ?? AccountTokenUsageLedgerStore.defaultLedgerURL().deletingLastPathComponent()
        self.supportDirectory = directory
        machineID = Self.loadOrCreateMachineID(in: directory)
        machineName = Self.shortMachineName(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        for host in peerHosts() {
            if let data = try? Data(contentsOf: peerCacheURL(host: host)),
               let file = try? JSONDecoder().decode(ClaudePublishedAccounts.self, from: data) {
                peerFiles[host] = file
            }
        }
    }

    /// Called (off the main thread) when a peer read brings new data, so the UI can refresh
    /// without waiting for its next tick.
    public func onPeerUpdate(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { peerUpdateHandler = handler }
    }

    public func fetchStatus() async throws -> CodexStatusSnapshot {
        let now = Date()
        startPeerFetchIfDue(now: now)

        let localProviders = currentProviders(now: now)
        var localEntries: [ClaudeAccountEntry] = []
        var firstError: Error?
        await withTaskGroup(of: (ClaudeAccountEntry?, Error?).self) { group in
            for provider in localProviders {
                group.addTask { await self.localEntry(for: provider, now: now) }
            }
            for await (entry, error) in group {
                if let entry { localEntries.append(entry) }
                if firstError == nil, let error { firstError = error }
            }
        }
        publish(now: now, providers: localProviders)

        let peerEntries = lock.withLock { Array(peerFiles.values) }
            .filter { $0.machineID != machineID }
            .flatMap { file in
                file.accounts.compactMap { account -> ClaudeAccountEntry? in
                    let fetchedAt = Date(timeIntervalSince1970: account.fetchedAt)
                    guard let data = account.usage.data(using: .utf8),
                          let snapshot = try? ClaudeUsageMapper.snapshot(fromJSON: data, now: fetchedAt) else {
                        return nil
                    }
                    return ClaudeAccountEntry(
                        identity: account.identity,
                        snapshot: snapshot,
                        machineName: file.machineName,
                        isLocal: false
                    )
                }
            }

        let entries = ClaudeAccountMerger.merge(localEntries + peerEntries)
        if entries.allSatisfy({ $0.snapshot == nil }), let firstError {
            throw firstError
        }
        return ClaudeAccountMerger.combinedSnapshot(entries, now: now, localStats: currentLocalStats())
    }

    // MARK: Local logins

    private func currentProviders(now: Date) -> [ClaudeUsageProvider] {
        let needsScan = lock.withLock {
            lastServiceScan.map { now.timeIntervalSince($0) >= serviceScanInterval } ?? true
        }
        if needsScan {
            let sources = ClaudeKeychain.credentialSources()
            let ids = Set(sources.map(\.id))
            lock.withLock {
                lastServiceScan = now
                for source in sources where providers[source.id] == nil {
                    providers[source.id] = ClaudeUsageProvider(source: source, session: session)
                }
                for id in providers.keys where !ids.contains(id) {
                    providers[id] = nil
                }
            }
        }
        return lock.withLock { providers.values.sorted { $0.source.id < $1.source.id } }
    }

    private func localEntry(for provider: ClaudeUsageProvider, now: Date) async -> (ClaudeAccountEntry?, Error?) {
        var snapshot: CodexStatusSnapshot?
        var fetchError: Error?
        do {
            snapshot = try await provider.fetchStatus()
        } catch {
            fetchError = error
        }
        let identity = await identity(for: provider, now: now)
        guard let identity else {
            // Without an organization this login can't be told apart from the others; it only
            // reaches the screen through the error when nothing else does.
            return (nil, fetchError)
        }
        // A cached snapshot older than the last fetch attempt means the fetch failed; say why.
        let entry = ClaudeAccountEntry(
            identity: identity,
            snapshot: snapshot,
            machineName: machineName,
            isLocal: true,
            errorMessage: fetchError?.localizedDescription
        )
        return (entry, fetchError)
    }

    /// The organization behind a login, from `/api/oauth/profile`, cached on disk per login and
    /// re-read every few hours or when Claude Code's recorded plan changes (a re-login).
    private func identity(for provider: ClaudeUsageProvider, now: Date) async -> ClaudeAccountIdentity? {
        let service = provider.source.id
        let token = try? provider.readToken()
        let cached = lock.withLock { identities[service] } ?? loadIdentity(source: provider.source)
        if let cached,
           now.timeIntervalSince1970 - cached.fetchedAt < identityRefreshInterval,
           token == nil || token?.subscriptionType == cached.identity.subscriptionType {
            lock.withLock { identities[service] = cached }
            return cached.identity
        }
        if let token, let fetched = await fetchProfile(token: token) {
            let entry = CachedIdentity(identity: fetched, fetchedAt: now.timeIntervalSince1970)
            lock.withLock { identities[service] = entry }
            saveIdentity(entry, source: provider.source)
            return fetched
        }
        if let cached { return cached.identity }
        // Profile unreachable and never cached: a provisional identity keeps the login on screen.
        // It is not published, since the other Mac couldn't match it to an organization.
        return token.map {
            ClaudeAccountIdentity(organizationUUID: "login:\(service)", subscriptionType: $0.subscriptionType)
        }
    }

    private func fetchProfile(token: ClaudeKeychain.Token) async -> ClaudeAccountIdentity? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CodexTokenTracker/0.1 (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        struct Profile: Decodable {
            struct Organization: Decodable {
                let uuid: String?
                let name: String?
                let organization_type: String?
                let rate_limit_tier: String?
            }
            let organization: Organization?
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  let organization = try JSONDecoder().decode(Profile.self, from: data).organization,
                  let uuid = organization.uuid else {
                return nil
            }
            return ClaudeAccountIdentity(
                organizationUUID: uuid,
                organizationName: organization.name,
                organizationType: organization.organization_type,
                subscriptionType: token.subscriptionType,
                rateLimitTier: organization.rate_limit_tier
            )
        } catch {
            Self.log.error("claude profile fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Publishing for the other Mac

    private func publish(now: Date, providers: [ClaudeUsageProvider]) {
        let accounts = providers.compactMap { provider -> ClaudePublishedAccounts.Account? in
            guard let identity = lock.withLock({ identities[provider.source.id]?.identity }),
                  let payload = provider.lastGoodPayload(),
                  let usage = String(data: payload.data, encoding: .utf8) else {
                return nil
            }
            return ClaudePublishedAccounts.Account(
                identity: identity,
                fetchedAt: payload.savedAt.timeIntervalSince1970,
                usage: usage
            )
        }
        let file = ClaudePublishedAccounts(
            machineID: machineID,
            machineName: machineName,
            publishedAt: now.timeIntervalSince1970,
            accounts: accounts
        )
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: supportDirectory.appendingPathComponent(Self.publishedFileName), options: .atomic)
    }

    // MARK: Peers

    /// SSH aliases of the other Macs, one per line in `claude-peers.txt`, else the defaults.
    private func peerHosts() -> [String] {
        let url = supportDirectory.appendingPathComponent("claude-peers.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Self.defaultPeerHosts
        }
        let hosts = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return hosts
    }

    private func peerCacheURL(host: String) -> URL {
        let safe = host.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return supportDirectory.appendingPathComponent("claude-peer-\(safe).json")
    }

    /// Peers are read in the background; a refresh shows the latest finished read so a sleeping
    /// or unreachable Mac never delays this one's own numbers.
    private func startPeerFetchIfDue(now: Date) {
        let hosts = peerHosts()
        lock.withLock {
            guard peerTask == nil,
                  lastPeerFetch.map({ now.timeIntervalSince($0) >= peerFetchInterval }) ?? true else {
                return
            }
            lastPeerFetch = now
            peerTask = Task.detached(priority: .utility) { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for host in hosts {
                        group.addTask { await self?.fetchPeer(host: host) }
                    }
                }
                self?.lock.withLock { self?.peerTask = nil }
            }
        }
    }

    private func fetchPeer(host: String) async {
        guard let data = await Self.readRemotePublishedFile(host: host),
              let file = try? JSONDecoder().decode(ClaudePublishedAccounts.self, from: data) else {
            return
        }
        guard file.machineID != machineID else { return }
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            let changed = peerFiles[host]?.accounts != file.accounts
            peerFiles[host] = file
            return changed ? peerUpdateHandler : nil
        }
        try? data.write(to: peerCacheURL(host: host), options: .atomic)
        handler?()
    }

    /// `ssh <host> cat …/claude-accounts-published.json`, non-interactive and time-boxed.
    static func readRemotePublishedFile(host: String, timeout: TimeInterval = 15) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "BatchMode=yes",
                    "-o", "ConnectTimeout=5",
                    "-o", "ServerAliveInterval=5",
                    "-o", "ServerAliveCountMax=1",
                    host,
                    "cat \"$HOME/Library/Application Support/CodexTokenTracker/\(publishedFileName)\"",
                ]
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

    // MARK: Local transcript stats

    /// Latest finished transcript totals of this Mac (Fable excluded); starts a background rescan
    /// when none is running. The first scan reads gigabytes, so it never delays the limits.
    private func currentLocalStats() -> TokenUsageStats? {
        lock.withLock {
            if localStatsTask == nil {
                localStatsTask = Task.detached(priority: .utility) { [weak self] in
                    let stats = ClaudeTokenUsageProvider.load(now: Date())
                    guard let self else { return }
                    self.lock.withLock {
                        if let stats { self.latestLocalStats = stats }
                        self.localStatsTask = nil
                    }
                }
            }
            return latestLocalStats
        }
    }

    // MARK: Files

    private func identityURL(source: ClaudeCredentialSource) -> URL {
        let name = ClaudeUsageProvider.lastGoodFileName(source: source)
            .replacingOccurrences(of: "claude-usage", with: "claude-profile")
        return supportDirectory.appendingPathComponent(name)
    }

    private func loadIdentity(source: ClaudeCredentialSource) -> CachedIdentity? {
        guard let data = try? Data(contentsOf: identityURL(source: source)) else { return nil }
        return try? JSONDecoder().decode(CachedIdentity.self, from: data)
    }

    private func saveIdentity(_ identity: CachedIdentity, source: ClaudeCredentialSource) {
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: identityURL(source: source), options: .atomic)
    }

    private static func loadOrCreateMachineID(in directory: URL) -> String {
        let url = directory.appendingPathComponent("machine-id")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    /// "Jongwon’s MacBook Air" → "MacBook Air".
    static func shortMachineName(_ name: String) -> String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker) {
                let rest = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
        }
        return name
    }
}
