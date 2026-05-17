import AppKit
import CodexTokenTrackerCore
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private static let popoverSize = NSSize(width: 360, height: 360)
    private static let screenMargin: CGFloat = 10

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: StatusStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: StatusStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "CodexTokenTracker"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.contentSize = Self.popoverSize
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
            button.title = ""
            button.contentTintColor = nil
            button.toolTip = "CodexTokenTracker - refreshing"
            return
        }

        button.title = ""

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

    func showPopover() {
        guard let button = statusItem.button else {
            return
        }

        if !popover.isShown {
            store.refresh()
            popover.contentSize = constrainedContentSize(for: button)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            framePopoverInsideScreen(relativeTo: button)
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button else {
                    return
                }
                self.framePopoverInsideScreen(relativeTo: button)
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func constrainedContentSize(for button: NSStatusBarButton) -> NSSize {
        let visibleFrame = (button.window?.screen ?? NSScreen.main)?.visibleFrame
        guard let visibleFrame else {
            return Self.popoverSize
        }

        return NSSize(
            width: min(Self.popoverSize.width, max(300, visibleFrame.width - (Self.screenMargin * 2))),
            height: min(Self.popoverSize.height, max(280, visibleFrame.height - (Self.screenMargin * 2)))
        )
    }

    private func framePopoverInsideScreen(relativeTo button: NSStatusBarButton) {
        guard let window = popover.contentViewController?.view.window else {
            return
        }

        let screen = button.window?.screen ?? window.screen ?? NSScreen.main
        guard let screen else {
            window.makeKey()
            return
        }

        let visibleFrame = screen.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        var frame = window.frame
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y -= frame.maxY - visibleFrame.maxY
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y += visibleFrame.minY - frame.minY
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x -= frame.maxX - visibleFrame.maxX
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x += visibleFrame.minX - frame.minX
        }

        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
        window.makeKey()
    }
}
