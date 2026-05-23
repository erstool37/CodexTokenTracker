import AppKit
import CodexTokenTrackerCore
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private static let popoverSize = NSSize(width: 340, height: 320)
    private static let screenMargin: CGFloat = 12

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: StatusStore
    private let appearanceRefreshPolicy = StatusBarAppearanceRefreshPolicy.menuBar
    private var cancellables: Set<AnyCancellable> = []
    private var currentSymbolName = "gauge.with.needle"

    init(store: StatusStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.popover = NSPopover()
        super.init()

        configureStatusItem()
        configurePopover()
        bindStore()
        bindAppearanceRefresh()
        updateStatusItem()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }
        button.action = #selector(togglePopover(_:))
        button.target = self
        setStatusImage(symbolName: currentSymbolName)
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

    private func bindAppearanceRefresh() {
        for notificationName in appearanceRefreshPolicy.applicationNotificationNames {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleAppearanceRefreshNotification(_:)),
                name: notificationName,
                object: nil
            )
        }

        for notificationName in appearanceRefreshPolicy.workspaceNotificationNames {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(handleAppearanceRefreshNotification(_:)),
                name: notificationName,
                object: nil
            )
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        let symbolName = store.hasError ? "exclamationmark.triangle" : "gauge.with.needle"
        currentSymbolName = symbolName
        setStatusImage(symbolName: symbolName)

        if store.isRefreshing && store.currentSnapshot == nil {
            button.title = ""
            button.contentTintColor = nil
            button.toolTip = "CodexTokenTracker - refreshing"
            return
        }

        button.title = ""

        let warningLevel = store.currentSnapshot?.mostSevereLimitWarningLevel ?? .normal

        if store.hasError {
            button.contentTintColor = .systemOrange
            button.toolTip = "CodexTokenTracker - refresh failed: \(store.errorMessage ?? "unknown error")"
        } else if warningLevel != .normal {
            button.contentTintColor = warningLevel.statusItemTintColor
            button.toolTip = "CodexTokenTracker - \(warningLevel.statusItemTooltip)"
        } else if store.stale {
            button.contentTintColor = .systemOrange
            button.toolTip = "CodexTokenTracker - stale data"
        } else {
            button.contentTintColor = nil
            button.toolTip = "CodexTokenTracker"
        }
    }

    private func setStatusImage(symbolName: String) {
        guard let button = statusItem.button else {
            return
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CodexTokenTracker")
        image?.isTemplate = true
        button.image = image
        button.needsDisplay = true
    }

    private func refreshStatusIconAppearance() {
        guard let button = statusItem.button else {
            return
        }

        setStatusImage(symbolName: currentSymbolName)
        button.needsDisplay = true
        button.window?.displayIfNeeded()
    }

    private func scheduleAppearanceRefresh() {
        refreshStatusIconAppearance()

        for delay in appearanceRefreshPolicy.deferredRefreshDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in
                    self?.refreshStatusIconAppearance()
                }
            }
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

    @objc private func handleAppearanceRefreshNotification(_ notification: Notification) {
        scheduleAppearanceRefresh()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func constrainedContentSize(for button: NSStatusBarButton) -> NSSize {
        let screen = button.window?.screen ?? NSScreen.main
        guard let screen else {
            return Self.popoverSize
        }
        let visibleFrame = usableFrame(for: screen)

        return NSSize(
            width: min(Self.popoverSize.width, max(300, visibleFrame.width - (Self.screenMargin * 2))),
            height: min(Self.popoverSize.height, max(240, visibleFrame.height - (Self.screenMargin * 2)))
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

        let visibleFrame = usableFrame(for: screen).insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
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

    private func usableFrame(for screen: NSScreen) -> NSRect {
        let menuBarBottom = screen.frame.maxY - NSStatusBar.system.thickness
        let top = min(screen.visibleFrame.maxY, menuBarBottom)
        return NSRect(
            x: screen.visibleFrame.minX,
            y: screen.visibleFrame.minY,
            width: screen.visibleFrame.width,
            height: max(1, top - screen.visibleFrame.minY)
        )
    }
}

private extension LimitWarningLevel {
    var statusItemTintColor: NSColor? {
        switch self {
        case .normal:
            return nil
        case .warning:
            return .systemOrange
        case .critical:
            return .systemRed
        }
    }

    var statusItemTooltip: String {
        switch self {
        case .normal:
            return "limits healthy"
        case .warning:
            return "a token limit is below 10%"
        case .critical:
            return "a token limit is below 5%"
        }
    }
}
