#!/usr/bin/env bash
# Signs a built k8sman.app with a Developer ID Application identity and the
# hardened runtime, inside-out (no --deep), so it can be notarized.
#
#   tools/sign-macos.sh <path/to/k8sman.app> "<identity>" [keychain]
#
# <identity> is the certificate's name ("Developer ID Application: …") or its
# SHA-1. Sparkle's helpers are signed the way Sparkle's docs describe
# (Downloader.xpc keeps its own entitlements).
set -euo pipefail

app="$1"
identity="$2"
keychain="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"
entitlements="$here/../frontend/macos/Runner/Release.entitlements"

sign() {
  codesign --force --timestamp --options runtime --sign "$identity" \
    ${keychain:+--keychain "$keychain"} "$@"
}

frameworks="$app/Contents/Frameworks"
sparkle="$frameworks/Sparkle.framework"
if [ -d "$sparkle" ]; then
  sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  sign "$sparkle/Versions/B/Autoupdate"
  sign "$sparkle/Versions/B/Updater.app"
  sign "$sparkle"
fi

# Any loose dylibs, then the other frameworks (Flutter, App, plugins).
while IFS= read -r -d '' lib; do sign "$lib"; done \
  < <(find "$app/Contents" -name '*.dylib' -type f -not -path "$sparkle/*" -print0)
for fw in "$frameworks"/*.framework; do
  [ "$fw" = "$sparkle" ] && continue
  [ -d "$fw" ] && sign "$fw"
done

# The embedded Go backend, then the app itself.
sign "$app/Contents/MacOS/k8sman-server"
sign --entitlements "$entitlements" "$app"

codesign --verify --deep --strict --verbose=2 "$app"
