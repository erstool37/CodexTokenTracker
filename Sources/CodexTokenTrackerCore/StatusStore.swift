import Foundation

@MainActor
public final class StatusStore: ObservableObject {
    @Published public private(set) var state: TrackerLoadState = .idle
    @Published public private(set) var isRefreshing = false

    private let provider: StatusProviding
    private var refreshTask: Task<Void, Never>?
    private var staleTicker: Task<Void, Never>?

    public init(provider: StatusProviding = AppServerStatusProvider()) {
        self.provider = provider
        staleTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.objectWillChange.send()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        staleTicker?.cancel()
    }

    public var currentSnapshot: CodexStatusSnapshot? {
        switch state {
        case let .loaded(snapshot):
            return snapshot
        case let .failed(previous, _):
            return previous
        case .idle, .refreshing:
            return nil
        }
    }

    public var stale: Bool {
        guard let snapshot = currentSnapshot else {
            return false
        }
        return Date().timeIntervalSince(snapshot.refreshedAt) > StatusFormatter.staleInterval
    }

    public var hasError: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    public var errorMessage: String? {
        if case let .failed(_, message) = state {
            return message
        }
        return nil
    }

    public func refresh() {
        if isRefreshing {
            return
        }
        let previous = currentSnapshot
        isRefreshing = true
        if previous == nil {
            state = .refreshing
        }

        refreshTask = Task { [provider] in
            do {
                let snapshot = try await provider.fetchStatus()
                guard !Task.isCancelled else { return }
                state = .loaded(snapshot)
                isRefreshing = false
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(previous: previous, message: error.localizedDescription)
                isRefreshing = false
            }
        }
    }
}
