# CodexTokenTracker

CodexTokenTracker is a local macOS menu bar utility for checking holistic Codex usage. It shows Codex rate-limit windows, reset times, remaining percentage, token stats, credits when available, and the last refresh time.

The app is intentionally status-first. It does not inspect conversation contents and does not read `~/.codex/auth.json` directly.

## Requirements

- macOS 14 or newer
- Swift 6 / Xcode command line tools
- Codex CLI installed and logged in

The app talks to Codex through:

```bash
codex app-server --listen stdio://
```

Codex app-server uses newline-delimited JSON-RPC messages with the JSON-RPC header omitted on the wire.

## Build

```bash
Scripts/test.sh
swift build --disable-sandbox --cache-path .swiftpm-cache/cache --config-path .swiftpm-cache/config --security-path .swiftpm-cache/security
Scripts/build_app.sh
```

The build script creates:

```text
dist/CodexTokenTracker.app
```

Open the app bundle or copy it to your preferred Applications folder.

## Privacy

CodexTokenTracker asks Codex app-server for account and rate-limit status, then reads local `token_count` events from Codex session JSONL files to aggregate weekly and rolling 28-day token stats. It does not read or store Codex auth tokens, local SQLite databases, or prompt text. If app-server is unavailable, the app shows an explicit error instead of scraping local secrets.

## Design

- Menu bar: minimal monochrome status icon with no numeric percentage text.
- Popover: returned limit buckets, reset times, credits, weekly/28-day token stats, freshness, manual refresh, and Codex usage link.
- Refresh: on launch, on popover open, and from the refresh button. Data older than 60 seconds is marked stale.
- Startup: after it has been opened once, the app registers itself to start again at macOS login/restart. If Apple's login-item service is unavailable, it writes a user LaunchAgent fallback.
