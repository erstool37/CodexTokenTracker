import Foundation

/// Shared request construction for `chatgpt.com/backend-api`.
///
/// Two providers talk to that host (the monthly credit allowance and the per-model credit
/// breakdown) and both must present the same identity: the Codex CLI's OAuth token plus the
/// originator and brand headers the API expects. Keeping it in one place means a change to how
/// the app identifies itself cannot drift between them.
///
/// Note on transport: this host sits behind a Cloudflare check that rejects curl's TLS
/// fingerprint with a 403 but accepts Apple's stack, so `URLSession` reaches it and a shell
/// probe does not.
enum CodexBackendRequest {
    static func make(url: URL, auth: CodexAuthFile.Credentials, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue("codex", forHTTPHeaderField: "OAI-App-Brand")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Perform a request synchronously. Callers are already off the main thread — the snapshot is
    /// assembled inside a detached task — so blocking here keeps the call sites straightforward.
    static func performSync(_ request: URLRequest, session: URLSession) throws -> Data {
        // The completion handler runs on a URLSession queue, so its result is handed back through
        // a locked box rather than by mutating locals: the semaphore does order the write before
        // the read, but only the box makes that safety visible to the compiler.
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            box.store(data: data, response: response, error: error)
            semaphore.signal()
        }.resume()
        semaphore.wait()

        let result = box.take()
        if let error = result.error {
            throw error
        }
        guard let http = result.response as? HTTPURLResponse, let payload = result.data else {
            throw CodexMonthlyCreditsError.unrecognizedResponse
        }
        guard http.statusCode == 200 else {
            throw CodexMonthlyCreditsError.http(status: http.statusCode)
        }
        return payload
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var response: URLResponse?
        private var error: Error?

        func store(data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            self.data = data
            self.response = response
            self.error = error
            lock.unlock()
        }

        func take() -> (data: Data?, response: URLResponse?, error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (data, response, error)
        }
    }

    /// Identify as the CLI: the API allow-lists this originator.
    static let userAgent: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "codex_cli_rs/0.155.0 (Mac OS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion); arm64) CodexTokenTracker"
    }()
}
