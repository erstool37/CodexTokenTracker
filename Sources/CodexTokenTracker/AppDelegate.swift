import AppKit
import CodexTokenTrackerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    // Keeps the store's 5s/20s retries for timeouts and 5xx; during a 429 cooldown the provider
    // throws without a network call, so those retries cannot re-trip the rate limit.
    private let claudeStore = StatusStore(
        provider: ClaudeUsageProvider(),
        tokenStatsLoader: { _, _ in nil }
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
