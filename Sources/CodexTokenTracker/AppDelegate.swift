import AppKit
import CodexTokenTrackerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Codex shows only its monthly credit allowance, so no local token-stats fallback either.
    // The menu-bar bars show both providers without opening the popover, so both stores poll.
    private let store = StatusStore(tokenStatsLoader: { _, _ in nil }, autoRefreshInterval: .seconds(300))
    // No fast 5s/20s retries for Claude: the usage endpoint answers rate-limits with a long
    // Retry-After, so quick retries only re-trip it. Cadence is the provider's 60s throttle plus
    // the store's 3-minute ticker; the provider serves cached data in between.
    private let claudeStore = StatusStore(
        provider: ClaudeUsageProvider(),
        tokenStatsLoader: { _, _ in nil },
        refreshRetryPolicy: .disabled,
        autoRefreshInterval: .seconds(180)
    )
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController(store: store, claudeStore: claudeStore)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        LaunchAtLoginInstaller.enable()
        store.refresh()
        claudeStore.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showWidget()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget()
        return true
    }

    private func showWidget() {
        statusController?.showPopover()
    }

    @objc private func handleReopenEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        showWidget()
    }
}
