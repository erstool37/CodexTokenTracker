#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="CodexTokenTracker"
TMP_ROOT="${TMPDIR:-/tmp}"
SWIFTPM_ROOT_KEY="${ROOT_DIR//[^A-Za-z0-9]/_}"
SWIFTPM_DIR="${CODEX_TOKEN_TRACKER_SWIFTPM_DIR:-$TMP_ROOT/CodexTokenTracker.swiftpm.$SWIFTPM_ROOT_KEY}"
SWIFT_SCRATCH_DIR="$SWIFTPM_DIR/build"
SWIFT_MODULE_CACHE_DIR="$SWIFTPM_DIR/clang-module-cache"
case "$ROOT_DIR" in
  /Applications/*)
    DEFAULT_APP_OUTPUT_ROOT="$TMP_ROOT/CodexTokenTracker.bundle.$SWIFTPM_ROOT_KEY"
    ;;
  *)
    DEFAULT_APP_OUTPUT_ROOT="$ROOT_DIR"
    ;;
esac
APP_OUTPUT_ROOT="${CODEX_TOKEN_TRACKER_APP_OUTPUT_ROOT:-$DEFAULT_APP_OUTPUT_ROOT}"
APP_DIR="$APP_OUTPUT_ROOT/dist/$APP_NAME.app"
ROOT_APP_DIR="$APP_OUTPUT_ROOT/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build \
  --disable-sandbox \
  --scratch-path "$SWIFT_SCRATCH_DIR" \
  --cache-path "$SWIFTPM_DIR/cache" \
  --config-path "$SWIFTPM_DIR/config" \
  --security-path "$SWIFTPM_DIR/security" \
  -c "$CONFIGURATION"

BINARY_PATH="$SWIFT_SCRATCH_DIR/$CONFIGURATION/$APP_NAME"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$SWIFT_MODULE_CACHE_DIR"

ditto "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
cp "AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"
swift -module-cache-path "$SWIFT_MODULE_CACHE_DIR" "Scripts/make_icon.swift" "$RESOURCES_DIR/$APP_NAME.icns"

chmod +x "$MACOS_DIR/$APP_NAME"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

rm -rf "$ROOT_APP_DIR"
cp -R "$APP_DIR" "$ROOT_APP_DIR"

echo "$APP_DIR"
echo "$ROOT_APP_DIR"
