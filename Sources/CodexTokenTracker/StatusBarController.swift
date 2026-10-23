import AppKit
import CodexTokenTrackerCore
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private static let popoverWidth: CGFloat = 420
    private static let screenMargin: CGFloat = 12

    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: StatusStore
    private let claudeStore: StatusStore
    private let appearanceRefreshPolicy = StatusBarAppearanceRefreshPolicy.menuBar
    private var cancellables: Set<AnyCancellable> = []
    private var currentSymbolName = "gauge.with.needle"

    init(store: StatusStore, claudeStore: StatusStore) {
        self.store = store
        self.claudeStore = claudeStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        // Left click refreshes; right click opens the popover.
        button.action = #selector(handleClick(_:))
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setStatusImage(symbolName: currentSymbolName)
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Token Tracker"
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        // The popover takes its height from the SwiftUI content, so it is only as tall as needed.
        let host = NSHostingController(rootView: StatusPopoverView(store: store, claudeStore: claudeStore))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    private func bindStore() {
        store.objectWillChange.merge(with: claudeStore.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange fires before the new value lands; read it on the next turn.
                DispatchQueue.main.async { self?.updateStatusItem() }
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
            applyStatusItemTint()
            button.toolTip = "Token Tracker - refreshing"
            return
        }

        button.title = ""
        applyStatusItemTint()

        let warningLevel = store.currentSnapshot?.mostSevereLimitWarningLevel ?? .normal

        if store.hasError {
            button.toolTip = "Token Tracker - refresh failed: \(store.errorMessage ?? "unknown error")"
        } else if warningLevel != .normal {
            button.toolTip = "Token Tracker - \(warningLevel.statusItemTooltip)"
        } else if store.stale {
            button.toolTip = "Token Tracker - stale data"
        } else {
            button.toolTip = MenuBarBars(codex: store.currentSnapshot, claude: claudeStore.currentSnapshot).tooltip
        }
    }

    private func setStatusImage(symbolName: String) {
        guard let button = statusItem.button else {
            return
        }

        let bars = MenuBarBars(codex: store.currentSnapshot, claude: claudeStore.currentSnapshot)
        let image: NSImage?
        if bars.hasAnyValue {
            image = bars.image()
        } else {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Token Tracker")
            image?.isTemplate = true
        }
        button.image = image
        applyStatusItemTint()
        button.needsDisplay = true
    }

    private func applyStatusItemTint() {
        guard let button = statusItem.button else {
            return
        }

        button.contentTintColor = appearanceRefreshPolicy.usesFixedWhiteIcon ? .white : nil
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
            claudeStore.refresh()
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

    @objc private func handleClick(_ sender: AnyObject?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            togglePopover(sender)
        } else {
            store.refresh()
            claudeStore.refresh()
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
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

/// Menu-bar summary, colored per provider: Codex monthly credits (blue) as one bar + number,
/// then two Claude blocks (orange) — the team account left, the personal account right — each
/// with 5h and weekly as two stacked bars + numbers. Bars fill with the share still left and
/// numbers are % left, matching the popover. Drawn at display time so the text follows the menu
/// bar's light/dark appearance.
struct MenuBarBars {
    static let codexColor = NSColor(srgbRed: 30 / 255, green: 136 / 255, blue: 229 / 255, alpha: 1)
    static let claudeColor = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)

    struct ClaudeAccountBars {
        var label: String?
        var sessionLeft: Int?
        var weeklyLeft: Int?
    }

    var codexMonthlyLeft: Int?
    var claudeTeam = ClaudeAccountBars()
    var claudePersonal = ClaudeAccountBars()

    init(codex: CodexStatusSnapshot?, claude: CodexStatusSnapshot?) {
        func left(_ windows: [LimitWindowDisplay], label: String) -> Int? {
            windows.first { $0.label == label && $0.showsNumericUsage }?.percentLeft
        }
        func bars(_ kind: String) -> ClaudeAccountBars {
            guard let bucket = claude?.limits.first(where: { $0.id.hasPrefix("claude-\(kind)-") }) else {
                return ClaudeAccountBars()
            }
            return ClaudeAccountBars(
                label: bucket.label,
                sessionLeft: left(bucket.windows, label: "5h limit"),
                weeklyLeft: left(bucket.windows, label: "Weekly limit")
            )
        }
        codexMonthlyLeft = left(codex?.limits.flatMap(\.windows) ?? [], label: "Monthly credits")
        claudeTeam = bars("team")
        claudePersonal = bars("personal")
    }

    var hasAnyValue: Bool {
        [codexMonthlyLeft, claudeTeam.sessionLeft, claudeTeam.weeklyLeft, claudePersonal.sessionLeft, claudePersonal.weeklyLeft]
            .contains { $0 != nil }
    }

    var tooltip: String {
        func text(_ value: Int?) -> String { value.map { "\($0)% left" } ?? "–" }
        func claude(_ bars: ClaudeAccountBars, fallback: String) -> String {
            "\(bars.label ?? fallback) 5h \(text(bars.sessionLeft)) · weekly \(text(bars.weeklyLeft))"
        }
        return [
            "Codex monthly \(text(codexMonthlyLeft))",
            "Claude \(claude(claudeTeam, fallback: "Team"))",
            "Claude \(claude(claudePersonal, fallback: "Personal"))",
        ].joined(separator: "\n")
    }

    private static let barWidth: CGFloat = 30
    private static let numberWidth: CGFloat = 26
    private static let blockGap: CGFloat = 8
    private static let height: CGFloat = 18

    func image() -> NSImage {
        let blockWidth = Self.barWidth + 3 + Self.numberWidth
        let size = NSSize(width: blockWidth * 3 + Self.blockGap * 2, height: Self.height)
        let image = NSImage(size: size, flipped: true) { _ in
            // Codex: one bar, vertically centred, larger number.
            Self.drawRow(value: codexMonthlyLeft, color: Self.codexColor, x: 0, midY: Self.height / 2,
                         barHeight: 4, fontSize: 11)
            // Claude: team block, then personal block; each 5h on top, weekly below.
            for (index, account) in [claudeTeam, claudePersonal].enumerated() {
                let x = (blockWidth + Self.blockGap) * CGFloat(index + 1)
                Self.drawRow(value: account.sessionLeft, color: Self.claudeColor, x: x, midY: 4.5,
                             barHeight: 3, fontSize: 8.5)
                Self.drawRow(value: account.weeklyLeft, color: Self.claudeColor, x: x, midY: 13.5,
                             barHeight: 3, fontSize: 8.5)
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = tooltip
        return image
    }

    private static func drawRow(value: Int?, color: NSColor, x: CGFloat, midY: CGFloat, barHeight: CGFloat, fontSize: CGFloat) {
        let track = NSRect(x: x, y: midY - barHeight / 2, width: barWidth, height: barHeight)
        NSColor.labelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        if let value, value > 0 {
            var fill = track
            fill.size.width = max(barHeight, barWidth * CGFloat(min(value, 100)) / 100)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }

        let text = value.map { "\($0)%" } ?? "–"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: x + barWidth + 3, y: midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
