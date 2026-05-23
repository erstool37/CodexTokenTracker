#if canImport(AppKit)
import AppKit
import Foundation

public struct StatusBarAppearanceRefreshPolicy: Equatable, Sendable {
    public var applicationNotificationNames: [Notification.Name]
    public var workspaceNotificationNames: [Notification.Name]
    public var deferredRefreshDelays: [TimeInterval]

    public init(
        applicationNotificationNames: [Notification.Name],
        workspaceNotificationNames: [Notification.Name],
        deferredRefreshDelays: [TimeInterval]
    ) {
        self.applicationNotificationNames = applicationNotificationNames
        self.workspaceNotificationNames = workspaceNotificationNames
        self.deferredRefreshDelays = deferredRefreshDelays
    }

    public static let menuBar = StatusBarAppearanceRefreshPolicy(
        applicationNotificationNames: [
            NSApplication.didChangeScreenParametersNotification,
            NSApplication.didBecomeActiveNotification
        ],
        workspaceNotificationNames: [
            NSWorkspace.activeSpaceDidChangeNotification
        ],
        deferredRefreshDelays: [0.05, 0.25]
    )
}
#endif
