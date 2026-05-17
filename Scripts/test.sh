#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift run \
  --disable-sandbox \
  --cache-path .swiftpm-cache/cache \
  --config-path .swiftpm-cache/config \
  --security-path .swiftpm-cache/security \
  CodexTokenTrackerChecks
