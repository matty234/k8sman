#!/usr/bin/env bash
# Packs k8sman.app into a compressed disk image with an Applications shortcut
# beside it (drag to install). With an identity the image is signed too, so
# it can be notarized and stapled (tools/notarize-macos.sh --dmg).
#
#   tools/make-dmg.sh <path/to/k8sman.app> <out.dmg> ["<identity>" [keychain]]
set -euo pipefail

app="$1"
out="$2"
identity="${3:-}"
keychain="${4:-}"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/k8sman.app"
ln -s /Applications "$stage/Applications"

rm -f "$out"
# UDZO: zlib-compressed, read-only; opens with Finder by default.
hdiutil create -quiet -volname "k8sman" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$out"

if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" ${keychain:+--keychain "$keychain"} "$out"
  codesign --verify --verbose=2 "$out"
fi
echo "$out"
