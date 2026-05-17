import AppKit
import CodexTokenTrackerCore
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StatusStore()
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController(store: store)
        store.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController = nil
    }
}
