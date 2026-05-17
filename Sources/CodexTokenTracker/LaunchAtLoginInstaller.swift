import Foundation
import ServiceManagement

enum LaunchAtLoginInstaller {
    private static let label = "com.erstool37.CodexTokenTracker"

    static func enable() {
        if enableServiceManagementLoginItem() {
            removeLaunchAgentFallback()
            return
        }

        do {
            try installLaunchAgentFallback()
        } catch {
            NSLog("CodexTokenTracker launch-at-login setup failed: \(error.localizedDescription)")
        }
    }

    private static func enableServiceManagementLoginItem() -> Bool {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            return true
        }

        do {
            try service.register()
        } catch {
            NSLog("CodexTokenTracker SMAppService registration failed: \(error.localizedDescription)")
        }

        if service.status == .requiresApproval {
            NSLog("CodexTokenTracker launch at login requires approval in System Settings.")
        }
        return service.status == .enabled
    }

    private static func installLaunchAgentFallback() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw LaunchAtLoginError.missingExecutableURL
        }

        let plistURL = launchAgentURL()
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        if (try? Data(contentsOf: plistURL)) == data {
            return
        }
        try data.write(to: plistURL, options: .atomic)
    }

    private static func removeLaunchAgentFallback() {
        try? FileManager.default.removeItem(at: launchAgentURL())
    }

    private static func launchAgentURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }
}

private enum LaunchAtLoginError: LocalizedError {
    case missingExecutableURL

    var errorDescription: String? {
        switch self {
        case .missingExecutableURL:
            return "Could not resolve the app executable URL."
        }
    }
}
