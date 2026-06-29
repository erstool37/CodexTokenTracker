# CodexTokenTracker WidgetKit Desktop Widget Design

## Goal

Build a real macOS WidgetKit desktop widget for CodexTokenTracker. The widget should feel like the current compact CLI-style status UI, but live on the macOS desktop/wallpaper widget surface. The large widget is the full-status target.

## Constraints

- Keep the existing SwiftPM package, menu bar app source, and `Scripts/test.sh` workflow intact.
- Use full Xcode only for the app-extension packaging path.
- Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so the global `xcode-select` setting does not need to change.
- Treat Codex app-server `/usage` as the exact source for token usage.
- Do not make the widget extension spawn `codex app-server` itself.
- Do not read Codex auth files or prompt/session text.

## Architecture

Add an Xcode project beside the existing SwiftPM package. The Xcode project will define a macOS app target and a WidgetKit extension target while reusing the current Swift source where practical.

The menu bar app remains the active refresher. It already talks to:

- `account/read`
- `account/rateLimits/read`
- `account/usage/read`

After every successful refresh, the app writes a compact widget snapshot JSON file to Application Support. The WidgetKit extension reads that file in its timeline provider and renders the latest available status. This avoids expensive process launch and app-server calls inside WidgetKit.

## Components

- `CodexTokenTracker.xcodeproj`
  - macOS app target for packaging the existing app with an embedded widget extension.
  - Widget extension target named `CodexTokenTrackerWidgetExtension`.
- `WidgetSnapshot`
  - Codable, compact, extension-safe display model.
  - Contains rendered labels and numbers, not raw app-server DTOs.
- `WidgetSnapshotStore`
  - Shared core utility for writing and reading the snapshot atomically.
  - Stores only display-safe status data.
- `CodexTokenTrackerWidget`
  - WidgetKit timeline provider.
  - Reads the latest snapshot.
  - Supplies placeholder, snapshot, stale, and error entries.
- `CodexStatusWidgetView`
  - SwiftUI view optimized for `.systemLarge`.
  - Medium/small families can render summaries later, but the first complete pass targets large.

## Large Widget Content

The large widget should show:

- Title: `Codex`
- Rate limits first, matching `/status` priority:
  - `5h limit`
  - `Weekly limit`
  - percent left
  - reset time
  - warning color when low
- Credits and reached-limit/status text when present.
- Exact `/usage` token rows:
  - `Daily`
  - `Weekly`
  - `Cumulative`
- Cumulative uses `summary.lifetimeTokens`, which is the whole account-history token total returned by `account/usage/read`.
- Freshness:
  - last refresh time
  - stale marker when older than the existing stale threshold
- Error state:
  - show last good data if available
  - show concise unavailable message when no snapshot exists

## Visual Direction

Use the current popover's compact, work-focused style as the source:

- Dense vertical layout.
- Monospaced digits for percentages and token counts.
- Small native typography.
- No large hero treatment.
- No decorative gradients or blobs.
- Widget background should use native WidgetKit container styling where supported, with a quiet translucent panel feel.

The widget must fit inside large desktop widget bounds without scrolling. If content pressure appears, abbreviate labels before widening the information hierarchy.

## Data Flow

1. App launches or refreshes.
2. `StatusStore` receives a `CodexStatusSnapshot`.
3. The app maps the snapshot into `WidgetSnapshot`.
4. `WidgetSnapshotStore` writes JSON atomically in Application Support.
5. The app asks WidgetKit to reload timelines.
6. The widget timeline provider reads the snapshot.
7. The widget renders the latest snapshot, stale snapshot, or placeholder/error entry.

## Refresh Behavior

- App refresh cadence remains the source of truth.
- Widget timeline should request periodic reloads, but must tolerate WidgetKit throttling.
- Manual refresh remains in the menu bar popover, not the widget.
- Widget display should clearly show stale data rather than implying live polling.

## Error Handling

- Missing snapshot: show placeholder with `Open CodexTokenTracker`.
- Stale snapshot: show data with a muted stale timestamp.
- App-server error with previous data: show previous data plus concise status text.
- App-server error with no previous data: show unavailable state.
- Invalid/corrupt snapshot JSON: ignore it and show unavailable state.

## Testing

Keep existing checks and add focused coverage:

- `WidgetSnapshot` mapping from `CodexStatusSnapshot`.
- Atomic snapshot read/write round trip.
- Exact usage rows include `Daily`, `Weekly`, and `Cumulative`.
- Cumulative maps to `summary.lifetimeTokens`.
- Rate-limit windows preserve percent-left and reset labels.
- Source inspection checks that the widget reads snapshots and does not spawn `codex app-server`.

Build verification after implementation:

- `Scripts/test.sh`
- `Scripts/build_app.sh`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project CodexTokenTracker.xcodeproj -scheme CodexTokenTracker -configuration Release build`
- Verify the built app embeds the widget extension.
- Verify the app bundle still launches as a menu bar app.

## Open Operational Notes

- This checkout is not a git repository. Commit/push must happen from a real clone or the documented temp-clone publish path.
- `open /Applications/Xcode.app` currently fails from this Codex process with LaunchServices `kLSNoExecutableErr`, but the Xcode command-line toolchain works when `DEVELOPER_DIR` is set.
- The visual companion could not run because `node` is not on PATH. This does not block the WidgetKit implementation.
