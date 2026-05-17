import AppKit
import CodexTokenTrackerCore
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: StatusStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: StatusStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
        updateStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.action = #selector(togglePopover(_:))
        button.target = self
        button.image = NSImage(
            systemSymbolName: "gauge.with.needle",
            accessibilityDescription: "CodexTokenTracker"
        )
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.toolTip = "CodexTokenTracker"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 440)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(store: store)
        )
    }

    private func bindStore() {
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        let symbolName = store.hasError ? "exclamationmark.triangle" : "gauge.with.needle"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CodexTokenTracker")
        button.image?.isTemplate = true

        if store.isRefreshing && store.currentSnapshot == nil {
            button.title = " ..."
            button.contentTintColor = nil
            return
        }

        if let percent = store.currentSnapshot?.bestRemainingPercent {
            button.title = " \(percent)%"
        } else {
            button.title = ""
        }

        if store.hasError {
            button.contentTintColor = .systemOrange
            button.toolTip = "CodexTokenTracker - refresh failed: \(store.errorMessage ?? "unknown error")"
        } else if store.stale {
            button.contentTintColor = .systemOrange
            button.toolTip = "CodexTokenTracker - stale data"
        } else {
            button.contentTintColor = nil
            button.toolTip = "CodexTokenTracker"
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
