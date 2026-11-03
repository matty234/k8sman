#!/bin/bash
# Fetches Sparkle's command-line tools (sign_update, generate_keys, …) for
# release signing, pinned by version and SHA-256, and prints their bin dir.
#
#   tools/sparkle-tools.sh [dest-dir]     (default: build/sparkle)
#
# Keep SPARKLE_VERSION in step with the Sparkle package in
# frontend/macos/Runner.xcodeproj (Package.resolved).
set -euo pipefail

SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="${1:-$root/build/sparkle}"
stamp="$dest/.version"

if [ -x "$dest/bin/sign_update" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$SPARKLE_VERSION" ]; then
  echo "$dest/bin"
  exit 0
fi

rm -rf "$dest"
mkdir -p "$dest"
archive="$dest/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -fsSL -o "$archive" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $archive" | shasum -a 256 -c - >&2
tar -xf "$archive" -C "$dest" bin
rm -f "$archive"
echo "$SPARKLE_VERSION" > "$stamp"
echo "$dest/bin"
