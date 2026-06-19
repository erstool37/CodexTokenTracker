import Foundation

public enum AppServerClientError: Error, LocalizedError, Sendable {
    case codexNotFound
    case launchFailed(String)
    case noResponse
    case rpc(String)
    case decode(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Could not find the codex executable in PATH, /opt/homebrew/bin, or /usr/local/bin."
        case let .launchFailed(message):
            return "Failed to launch codex app-server: \(message)"
        case .noResponse:
            return "codex app-server closed without returning a response."
        case let .rpc(message):
            return message
        case let .decode(message):
            return "Could not decode codex app-server response: \(message)"
        }
    }
}

public protocol StatusProviding: Sendable {
    func fetchStatus() async throws -> CodexStatusSnapshot
}

public final class AppServerStatusProvider: StatusProviding, @unchecked Sendable {
    private let executableURL: URL
    private let decoder = JSONDecoder()

    public init(executableURL: URL? = AppServerStatusProvider.defaultCodexURL()) {
        self.executableURL = executableURL ?? URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    }

    public func fetchStatus() async throws -> CodexStatusSnapshot {
        try await Task.detached(priority: .userInitiated) {
            try self.fetchStatusSync()
        }.value
    }

    private func fetchStatusSync() throws -> CodexStatusSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AppServerClientError.codexNotFound
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = Self.cleanEnvironment()

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw AppServerClientError.launchFailed(error.localizedDescription)
        }

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            terminate(process)
        }

        do {
            let writer = input.fileHandleForWriting
            try send(initializeMessage, to: writer)
            _ = try waitForResponse(
                InitializeResponse.self,
                expectedID: 1,
                from: process,
                stdout: stdoutBuffer,
                stderr: stderrBuffer,
                timeout: 10
            )

            try send(["method": "initialized"], to: writer)
            try send(
                ["method": "account/read", "id": 2, "params": ["refreshToken": false]],
                to: writer
            )
            try send(["method": "account/rateLimits/read", "id": 3], to: writer)
            try send(["method": "account/usage/read", "id": 4], to: writer)

            let account = try waitForResponse(
                GetAccountResponse.self,
                expectedID: 2,
                from: process,
                stdout: stdoutBuffer,
                stderr: stderrBuffer,
                timeout: 20
            )
            let rateLimits = try waitForResponse(
                GetAccountRateLimitsResponse.self,
                expectedID: 3,
                from: process,
                stdout: stdoutBuffer,
                stderr: stderrBuffer,
                timeout: 20
            )
            let usageResult: Result<GetAccountTokenUsageResponse, Error>
            do {
                let usage = try waitForResponse(
                    GetAccountTokenUsageResponse.self,
                    expectedID: 4,
                    from: process,
                    stdout: stdoutBuffer,
                    stderr: stderrBuffer,
                    timeout: 12
                )
                usageResult = .success(usage)
            } catch {
                usageResult = .failure(error)
            }

            let accountDisplay = StatusMapper.accountDisplay(from: account)
            let now = Date()
            let onlineTokenStats: TokenUsageStats?
            let onlineTokenStatsError: String?
            let fallbackTokenStats: TokenUsageStats?
            switch usageResult {
            case let .success(usage):
                onlineTokenStats = AccountUsageStatsProvider.stats(from: usage, now: now)
                onlineTokenStatsError = nil
                fallbackTokenStats = nil
            case let .failure(error):
                onlineTokenStats = nil
                onlineTokenStatsError = error.localizedDescription
                fallbackTokenStats = TokenUsageStatsProvider.load(for: accountDisplay, now: now)
            }
            return CodexStatusSnapshot(
                account: accountDisplay,
                limits: StatusMapper.limitDisplays(from: rateLimits, now: now),
                onlineTokenStats: onlineTokenStats,
                onlineTokenStatsError: onlineTokenStatsError,
                tokenStats: fallbackTokenStats,
                refreshedAt: now
            )
        } catch {
            terminate(process)
            if let appError = error as? AppServerClientError {
                throw appError
            }
            throw AppServerClientError.rpc(error.localizedDescription)
        }
    }

    private var initializeMessage: [String: Any] {
        [
            "method": "initialize",
            "id": 1,
            "params": [
                "clientInfo": [
                    "name": "codex_token_tracker",
                    "title": "CodexTokenTracker",
                    "version": "0.1.0"
                ],
                "capabilities": [
                    "experimentalApi": true,
                    "optOutNotificationMethods": [
                        "thread/started",
                        "item/agentMessage/delta",
                        "item/started",
                        "item/completed"
                    ]
                ]
            ]
        ]
    }

    private func send(_ message: [String: Any], to writer: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [])
        writer.write(data)
        writer.write(Data([0x0A]))
    }

    private func responseLine<T: Decodable>(_ type: T.Type, from line: Data, expectedID: Int) throws -> T? {
        guard !line.isEmpty else {
            return nil
        }
        let response: RPCResponse<T>
        do {
            response = try decoder.decode(RPCResponse<T>.self, from: line)
        } catch {
            return nil
        }
        guard response.id == expectedID else {
            return nil
        }
        if let error = response.error {
            throw AppServerClientError.rpc(error.description)
        }
        guard let result = response.result else {
            throw AppServerClientError.noResponse
        }
        return result
    }

    private func terminate(_ process: Process) {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }

    private func waitForResponse<T: Decodable>(
        _ type: T.Type,
        expectedID: Int,
        from process: Process,
        stdout: OutputBuffer,
        stderr: OutputBuffer,
        timeout: TimeInterval
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var readOffset = 0
        var pendingLine = Data()
        while Date() < deadline {
            let update = stdout.snapshot(startingAt: readOffset)
            readOffset = update.endOffset
            if !update.data.isEmpty {
                pendingLine.append(update.data)
                while let newlineRange = pendingLine.firstRange(of: Data([0x0A])) {
                    let line = pendingLine.subdata(in: pendingLine.startIndex..<newlineRange.lowerBound)
                    pendingLine.removeSubrange(pendingLine.startIndex..<newlineRange.upperBound)
                    if let response = try responseLine(type, from: line, expectedID: expectedID) {
                        return response
                    }
                }
            }
            if !process.isRunning {
                if let response = try responseLine(type, from: pendingLine, expectedID: expectedID) {
                    return response
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let stderrText = String(data: stderr.snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = String(data: stdout.snapshot, encoding: .utf8)?
            .split(separator: "\n")
            .suffix(3)
            .joined(separator: "\n")
        if !process.isRunning && process.terminationStatus != 0 {
            throw AppServerClientError.rpc(
                stderrText?.isEmpty == false
                    ? stderrText!
                    : "codex app-server exited with status \(process.terminationStatus)."
            )
        }

        let details = [
            stderrText?.isEmpty == false ? "stderr: \(stderrText!)" : nil,
            stdoutText?.isEmpty == false ? "last stdout: \(stdoutText!)" : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        throw AppServerClientError.rpc(
            details.isEmpty
                ? "codex app-server did not return response id \(expectedID) within \(Int(timeout)) seconds."
                : "codex app-server did not return response id \(expectedID) within \(Int(timeout)) seconds. \(details)"
        )
    }

    public static func defaultCodexURL() -> URL? {
        let pathCandidates = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/codex" } ?? []
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private static func cleanEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["RUST_LOG"] = nil
        environment["LOG_FORMAT"] = nil
        return environment
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func snapshot(startingAt offset: Int) -> (data: Data, endOffset: Int) {
        lock.lock()
        defer { lock.unlock() }

        let safeOffset = min(max(offset, 0), data.count)
        return (
            data: data.subdata(in: safeOffset..<data.count),
            endOffset: data.count
        )
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }
}
