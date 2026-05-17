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

            let now = Date()
            return CodexStatusSnapshot(
                account: StatusMapper.accountDisplay(from: account),
                limits: StatusMapper.limitDisplays(from: rateLimits, now: now),
                tokenStats: TokenUsageStatsProvider.load(now: now),
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

    private func response<T: Decodable>(_ type: T.Type, from data: Data, expectedID: Int) throws -> T {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppServerClientError.decode("stdout was not valid UTF-8")
        }
        for lineText in text.split(separator: "\n") {
            let line = Data(lineText.utf8)
            let response: RPCResponse<T>
            do {
                response = try decoder.decode(RPCResponse<T>.self, from: line)
            } catch {
                continue
            }
            guard response.id == expectedID else {
                continue
            }
            if let error = response.error {
                throw AppServerClientError.rpc(error.description)
            }
            guard let result = response.result else {
                throw AppServerClientError.noResponse
            }
            return result
        }
        throw AppServerClientError.noResponse
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
        while Date() < deadline {
            do {
                return try response(type, from: stdout.snapshot, expectedID: expectedID)
            } catch AppServerClientError.noResponse {
                if !process.isRunning {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
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

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }
}
