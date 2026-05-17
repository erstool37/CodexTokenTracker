import AppKit
import CodexTokenTrackerCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var statusController: StatusBarController?
    private var statusWindowController: StatusWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController(store: store)
        statusWindowController = StatusWindowController(store: store)
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleReopenEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEReopenApplication)
        )
        enableLaunchAtLoginIfPossible()
        store.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showMainInterface()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController = nil
        statusWindowController = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainInterface()
        return true
    }

    private func showMainInterface() {
        statusWindowController?.showStatusWindow()
    }

    @objc private func handleReopenEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        showMainInterface()
    }

    private func enableLaunchAtLoginIfPossible() {
        guard SMAppService.mainApp.status != .enabled else {
            return
        }
        try? SMAppService.mainApp.register()
    }
}
