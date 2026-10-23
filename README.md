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

## Claude accounts across Macs

The Claude pane and menu bar show every Claude account, team left and personal right, each with its 5h and weekly limits. Accounts come from:

- every Claude Code login on this Mac: the default keychain item `Claude Code-credentials`, plus `Claude Code-credentials-<sha256(dir)[:8]>` for each `CLAUDE_CONFIG_DIR=<dir> claude` login;
- the other Mac: each app writes its own logins' usage to `~/Library/Application Support/CodexTokenTracker/claude-accounts-published.json` (usage and organization only, no tokens) and reads the peer's copy with `ssh <host> cat …`.

Peers are the SSH aliases in `claude-peers.txt` in the same folder (one per line), defaulting to `home` and `pro`. A Mac skips its own file by `machine-id`. Accounts are matched by organization UUID, so the same team login on both Macs shows once. A login's numbers stay fresh only while Claude Code on that machine keeps its token refreshed; older data is labeled "as of <time>".

## Privacy

CodexTokenTracker asks Codex app-server for account, rate-limit, and exact `/usage` token stats. Daily and weekly token rows are anchored to the newest daily usage bucket returned by Codex, not the local wall-clock day, so they stay aligned with `/usage` when the server has not published a bucket for the current date yet. It reads local `token_count` events from Codex session JSONL files only as an estimated device fallback when exact usage is unavailable. It does not read or store Codex auth tokens, local SQLite databases, or prompt text. If app-server is unavailable, the app shows an explicit error instead of scraping local secrets.

## Design

- Menu bar: minimal monochrome status icon with no numeric percentage text.
- Popover: returned limit buckets, reset times, credits, exact daily/weekly/cumulative usage stats, freshness, manual refresh, and Codex usage link.
- Refresh: on launch, on popover open, and from the refresh button. Data older than 60 seconds is marked stale.
- Startup: after it has been opened once, the app registers itself to start again at macOS login/restart. If Apple's login-item service is unavailable, it writes a user LaunchAgent fallback.
