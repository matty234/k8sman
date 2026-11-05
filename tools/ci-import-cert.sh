#!/usr/bin/env bash
# CI only: imports the Developer ID certificate into a temporary keychain and
# writes the notary key, for tools/sign-macos.sh and tools/notarize-macos.sh.
#
# Reads MACOS_CERT_P12 (base64), MACOS_CERT_PASSWORD, NOTARY_KEY_P8 and
# TEAM_ID, and appends identity=, keychain= and notary_key= to $GITHUB_OUTPUT.
set -euo pipefail
: "${MACOS_CERT_P12:?}" "${MACOS_CERT_PASSWORD:?}" "${NOTARY_KEY_P8:?}" "${TEAM_ID:?}"

tmp="${RUNNER_TEMP:?}"
kc="$tmp/signing.keychain-db"
kcpass="$(openssl rand -hex 16)"
security create-keychain -p "$kcpass" "$kc"
security set-keychain-settings -lut 21600 "$kc"
security unlock-keychain -p "$kcpass" "$kc"

printf %s "$MACOS_CERT_P12" | base64 --decode > "$tmp/cert.p12"
security import "$tmp/cert.p12" -k "$kc" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
rm -f "$tmp/cert.p12"
security set-key-partition-list -S apple-tool:,apple: -s -k "$kcpass" "$kc" >/dev/null
# shellcheck disable=SC2046
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')

identity="$(security find-identity -v -p codesigning "$kc" |
  sed -nE 's/.*"(Developer ID Application: .*\('"$TEAM_ID"'\))".*/\1/p' | head -1)"
if [ -z "$identity" ]; then
  echo "::error::no Developer ID Application identity for team $TEAM_ID in MACOS_CERT_P12"
  exit 1
fi

( umask 077; printf %s "$NOTARY_KEY_P8" > "$tmp/notary.p8" )
{
  echo "identity=$identity"
  echo "keychain=$kc"
  echo "notary_key=$tmp/notary.p8"
} >> "$GITHUB_OUTPUT"
echo "Signing as: $identity"
