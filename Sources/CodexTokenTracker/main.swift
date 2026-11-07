import AppKit
import CodexTokenTrackerCore

// The app scans Claude transcripts by running itself with this flag; see ClaudeTranscriptStatsCommand.
if CommandLine.arguments.dropFirst().first == ClaudeTranscriptStatsCommand.argument {
    exit(ClaudeTranscriptStatsCommand.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
