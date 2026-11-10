#!/usr/bin/env bash
# Packs k8sman.app into a compressed disk image with the branded drag-to-
# Applications window (background, icon positions, volume icon), laid out by
# dmgbuild without Finder so it works headless on CI. With an identity the
# image is signed too, so it can be notarized and stapled
# (tools/notarize-macos.sh --dmg).
#
#   tools/make-dmg.sh <path/to/k8sman.app> <out.dmg> ["<identity>" [keychain]]
#
# Needs dmgbuild:  pip3 install dmgbuild   (or: pipx install dmgbuild)
# Layout and artwork live in packaging/dmg/ (settings.py, background.tiff,
# regenerated with: swift packaging/dmg/make-background.swift).
set -euo pipefail

app="$1"
out="$2"
identity="${3:-}"
keychain="${4:-}"

if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "error: dmgbuild not found; it lays out the installer window. Install it with: pip3 install dmgbuild (or pipx install dmgbuild)" >&2
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"
settings="$here/../packaging/dmg/settings.py"

rm -f "$out"
dmgbuild -s "$settings" -D app="$app" -D settings="$settings" "k8sman" "$out" >/dev/null

if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" ${keychain:+--keychain "$keychain"} "$out"
  codesign --verify --verbose=2 "$out"
fi
echo "$out"
