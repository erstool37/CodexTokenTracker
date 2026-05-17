# CodexTokenTracker Agent Workflow

This repository builds a macOS menu bar widget that mirrors the Codex `/status` slash command as closely as the local Codex app-server API allows.

## Product Contract

- The app must be usable by double-clicking `CodexTokenTracker.app`.
- The menu bar item must stay minimal and open Codex token/status information without requiring Terminal.
- The popover must expose the same substantive usage information as Codex `/status`: token usage, rate-limit windows, reset timing, and any reached-limit/error state. Account identity and plan text may be omitted when the user asks for a cleaner widget.
- The app must stay minimal and native-feeling on macOS, following Apple menu bar and popover conventions.
- The icon must be minimal, template-friendly, and legible in light/dark menu bar modes.
- Refresh behavior must be accurate, visible, and bounded: refresh on launch, refresh when opened, refresh periodically, and mark stale/error states clearly.

## Agent Roles

### Orchestrator

The main chat owns the product plan, integrates research and QA feedback, resolves tradeoffs, and commits/pushes finished work. It must not mark the task complete until the built app has passed the QA checklist below.

### Research Agent

Use a research subagent when planning design or product behavior. It should research token-usage and quota-tracking widgets/apps online, then report:

- What information each product surfaces.
- How each product organizes usage, limits, resets, alerts, and history.
- Visual patterns: menu bar text, icons, color/state semantics, popover density, charts, and empty/error states.
- What to adopt or avoid for this app.

### Builder Agent

Use a builder subagent for implementation work when the scope is not a small local fix. The builder owns code changes in clearly assigned files and must not overwrite unrelated user edits. Prefer `GPT-5.3-Codex-Spark` for this role when available; any current coding model may be used if that model is unavailable or the user has relaxed the requirement.

### QA Agent

Use a QA subagent before final completion and after any launch/usability fix. The QA agent must check the built artifact, not only source files, and return Pass/Fail with evidence against this checklist:

1. Identical information: the widget shows the same substantive token, limit, reset, and error information exposed by Codex `/status` or the closest available app-server status source, excluding account identity when intentionally hidden.
2. Apple UI fit: the menu bar, popover, spacing, typography, colors, and state handling are neat and consistent with Apple menu bar app conventions.
3. Minimal icon: the app bundle includes a small, readable, template-friendly icon.
4. Refresh correctness: launch, open, manual, periodic, stale, and error refresh states behave correctly.
5. Click-to-use: `CodexTokenTracker.app` launches by double-click/Finder semantics, creates a visible menu bar item, and opens a usable popover.
6. Efficiency/refactor: expensive scans, app-server calls, timers, and UI updates are bounded so the widget can stay running without noticeable RAM or CPU impact.

The QA agent also owns efficiency refactor review. When it finds a small, low-risk refactor that materially reduces CPU, RAM, disk scanning, process churn, or unnecessary UI work, it may implement that focused refactor directly and must list the exact files changed. Larger refactors should be reported as Fail with a concrete patch plan.

## Required Build Flow

1. Inspect local instructions and the current git worktree before edits.
2. Keep source-first structure buildable from this repo.
3. Build and test with:

```bash
Scripts/test.sh
Scripts/build_app.sh
```

4. Verify the app bundle contains:

- `Contents/Info.plist`
- `Contents/MacOS/CodexTokenTracker`
- `Contents/Resources/CodexTokenTracker.icns`
- `Contents/PkgInfo`

5. Verify code signing when packaging changes:

```bash
codesign --verify --deep --strict --verbose=2 dist/CodexTokenTracker.app
```

6. Copy the fresh bundle to the repository root only after `Scripts/build_app.sh` succeeds.
7. Commit and push source changes to `https://github.com/erstool37/CodexTokenTracker`.
8. If copying source or artifacts into `/Applications/Utilities` is requested and sandbox permissions block it, report the exact command the user can run from Terminal.

## Launch-Failure Rule

If the user reports that double-clicking the app does nothing, treat that as a release blocker. Check the newest `~/Library/Logs/DiagnosticReports/CodexTokenTracker*.ips`, LaunchServices output, bundle metadata, executable permissions, signing, and actual app startup path before claiming the issue is fixed.

In this Codex sandbox, shell `open` and direct GUI executable launch may report misleading LaunchServices/AppKit errors. When those disagree with visible desktop behavior, verify click-to-use through Finder/Computer Use or another real desktop launch path and treat that as the authoritative user-path check.
