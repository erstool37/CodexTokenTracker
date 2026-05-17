import AppKit
import CodexTokenTrackerCore
import SwiftUI

@MainActor
final class StatusWindowController: NSWindowController {
    private let store: StatusStore

    init(store: StatusStore) {
        self.store = store

        let hostingController = NSHostingController(
            rootView: StatusPopoverView(store: store)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CodexTokenTracker"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.setContentSize(NSSize(width: 360, height: 500))
        window.minSize = NSSize(width: 340, height: 420)

        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showStatusWindow() {
        guard let window else {
            return
        }

        if !window.isVisible {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        store.refresh()
    }
}
