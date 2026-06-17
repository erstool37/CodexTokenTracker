#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
SWIFTPM_ROOT_KEY="${ROOT_DIR//[^A-Za-z0-9]/_}"
SWIFTPM_DIR="${CODEX_TOKEN_TRACKER_SWIFTPM_DIR:-$TMP_ROOT/CodexTokenTracker.swiftpm.$SWIFTPM_ROOT_KEY}"
cd "$ROOT_DIR"

swift run \
  --disable-sandbox \
  --scratch-path "$SWIFTPM_DIR/build" \
  --cache-path "$SWIFTPM_DIR/cache" \
  --config-path "$SWIFTPM_DIR/config" \
  --security-path "$SWIFTPM_DIR/security" \
  CodexTokenTrackerChecks
