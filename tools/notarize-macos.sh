#!/usr/bin/env bash
# Notarizes a signed k8sman.app (or a signed .dmg) with an App Store Connect
# API key and staples the ticket to it, so Gatekeeper accepts it offline too.
#
#   NOTARY_KEY_FILE=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… \
#     tools/notarize-macos.sh <path/to/k8sman.app | path/to/k8sman.dmg>
set -euo pipefail

target="$1"
: "${NOTARY_KEY_FILE:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
case "$target" in
  *.dmg) submit="$target" ;; # disk images are submitted as they are
  *)
    submit="$tmp/submit.zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$submit"
    ;;
esac

if ! xcrun notarytool submit "$submit" \
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

xcrun stapler staple "$target"
xcrun stapler validate "$target"
case "$target" in
  *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$target" ;;
  *) spctl --assess --type execute --verbose=2 "$target" ;;
esac
