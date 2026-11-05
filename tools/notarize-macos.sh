#!/usr/bin/env bash
# Notarizes a signed k8sman.app with an App Store Connect API key and staples
# the ticket to it, so Gatekeeper accepts it offline too.
#
#   NOTARY_KEY_FILE=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… \
#     tools/notarize-macos.sh <path/to/k8sman.app>
set -euo pipefail

app="$1"
: "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$tmp/submit.zip"

if ! xcrun notarytool submit "$tmp/submit.zip" \
    --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
    --wait --timeout 30m --output-format json > "$tmp/result.json"; then
  cat "$tmp/result.json" >&2 || true
fi
cat "$tmp/result.json"
status="$(plutil -extract status raw "$tmp/result.json" 2>/dev/null || true)"
if [ "$status" != "Accepted" ]; then
  id="$(plutil -extract id raw "$tmp/result.json" 2>/dev/null || true)"
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" \
      --key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" >&2 || true
  fi
  echo "error: notarization status: ${status:-unknown}" >&2
  exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
