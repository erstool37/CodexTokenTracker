import Foundation

/// Whether the local transcript scans are worth doing yet.
///
/// The usage card they feed is only ever visible inside the popover — the menu-bar item shows an
/// icon tint driven by rate limits, which come from the network, not from transcripts. Scanning
/// `~/.claude/projects` and `~/.codex/sessions` at launch therefore spent the app's single most
/// expensive operation (roughly 85 s of CPU here, on 1.8 GB of transcripts) producing a number
/// nobody had asked to see. On a laptop that is a login-time battery cost for nothing.
///
/// The gate opens the first time the popover is shown and stays open for the rest of the process,
/// so the scan happens once, on demand, and every later refresh is served from the warm per-file
/// cache. An app launched at login and never clicked now does no scanning at all.
public enum UsageDetailGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var opened = false

    /// True once the user has opened the popover at least once this launch.
    public static var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    /// Called when the popover is shown. Latching rather than toggling: once the user has looked,
    /// keep the usage card current so reopening it is instant.
    public static func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    /// Testing seam.
    public static func resetForTesting() {
        lock.lock()
        opened = false
        lock.unlock()
    }
}
