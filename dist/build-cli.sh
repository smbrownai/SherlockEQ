#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Build the standalone `sherlockeq` command-line tool as a universal
# (arm64 + x86_64) release binary, to match the app's universal build.
#
# Called by dist/release.sh, which embeds the result into
# SherlockEQ.app/Contents/Helpers/ and signs it with the app. Can also be run
# on its own for local testing.
#
# Usage:
#   dist/build-cli.sh
#
# Output:
#   cli/.build/apple/Products/Release/sherlockeq   (universal Mach-O)
#
# The CLI's reported version (`sherlockeq --version`) is the `cliVersion`
# constant in cli/Sources/sherlockeq/Root.swift, bumped in PREP by
# dist/ship.sh alongside the app version — this script does not touch sources.
# -----------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI_DIR="$REPO_ROOT/cli"
BIN="$CLI_DIR/.build/apple/Products/Release/sherlockeq"

cd "$CLI_DIR"
echo "==> building sherlockeq CLI (universal release)"
swift build -c release --arch arm64 --arch x86_64

if [[ ! -f "$BIN" ]]; then
  echo "error: CLI binary not produced at $BIN" >&2
  exit 1
fi

# Sanity: confirm both slices are present.
if ! lipo -archs "$BIN" | grep -q "arm64" || ! lipo -archs "$BIN" | grep -q "x86_64"; then
  echo "error: $BIN is not a universal arm64+x86_64 binary (got: $(lipo -archs "$BIN"))" >&2
  exit 1
fi

echo "$BIN"
