#!/bin/bash
# Local end-to-end test of in-app updates, without GitHub (docs/UPDATES.md).
#
#   make release && tools/update-e2e.sh      (or: make update-e2e)
#
# From the Release build it makes two versions (0.1.0 and 0.1.1) signed with a
# throwaway EdDSA key, serves signed appcasts from a local HTTP server, and
# drives the app's own Sparkle framework headlessly (tools/update-e2e/
# UpdateProbe.swift) against an "installed" copy of 0.1.0:
#
#   1. archive modified after signing          -> rejected, 0.1.0 untouched
#   2. feed + archive signed with another key  -> rejected
#   3. feed edited after signing               -> rejected
#   4. good feed                               -> 0.1.1 installed: bundle
#      replaced (k8sman-server included), signature valid, no quarantine
#
# The test copies use the bundle id dev.k8sman.e2e, so the real app's
# preferences and caches are not touched. The app is never launched.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
work="${UPDATE_E2E_DIR:-$root/build/update-e2e}"
port="${UPDATE_E2E_PORT:-8765}"
app="$root/frontend/build/macos/Build/Products/Release/k8sman.app"
test_id=dev.k8sman.e2e
export GOTOOLCHAIN=local

[ -d "$app" ] || { echo "error: $app missing; run make release first" >&2; exit 1; }
bin="$(tools/sparkle-tools.sh)"

rm -rf -- "${work:?}"
mkdir -p "$work/keys" "$work/www" "$work/fw"

echo "== keys (throwaway, local test only)"
pub="$(go run tools/update-e2e/keygen.go "$work/keys/test.key")"
go run tools/update-e2e/keygen.go "$work/keys/other.key" >/dev/null
echo "test public key: $pub"

plist_set() { plutil -replace "$2" -string "$3" "$1/Contents/Info.plist"; }
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }

# make_version <version> <dir> [marker]
make_version() {
  local v="$1" dest="$2/k8sman.app"
  mkdir -p "$2"
  ditto "$app" "$dest"
  plist_set "$dest" CFBundleShortVersionString "$v"
  plist_set "$dest" CFBundleVersion "$v"
  plist_set "$dest" SUPublicEDKey "$pub"
  plist_set "$dest" CFBundleIdentifier "$test_id"
  echo "${3:-$v}" > "$dest/Contents/Resources/e2e-marker"
  codesign --force --deep --sign - "$dest" 2>/dev/null
  codesign --verify --deep --strict "$dest"
}

echo "== building test versions"
make_version 0.1.0 "$work/v0.1.0"
make_version 0.1.1 "$work/v0.1.1"
# An attacker's 0.1.1: different content, validly (ad-hoc) code signed.
make_version 0.1.1 "$work/evil" "evil"

zip_app() { ditto -c -k --sequesterRsrc --keepParent "$1/k8sman.app" "$2"; }

# feed <name> <app-dir> <key>: a served directory with a zip and signed appcast
feed() {
  local dir="$work/www/$1"
  mkdir -p "$dir"
  zip_app "$2" "$dir/k8sman-0.1.1-macos.zip"
  python3 tools/appcast.py --zip "$dir/k8sman-0.1.1-macos.zip" --version 0.1.1 \
    --download-url "http://127.0.0.1:$port/$1/k8sman-0.1.1-macos.zip" \
    --release-url "http://127.0.0.1:$port/$1/notes.html" \
    --sparkle-bin "$bin" --ed-key-file "$3" --out "$dir/appcast.xml" >/dev/null
}

echo "== feeds"
feed good "$work/v0.1.1" "$work/keys/test.key"
feed wrong-key "$work/v0.1.1" "$work/keys/other.key"
# 1. Signed for the real 0.1.1, but the archive is swapped afterwards.
feed tampered-zip "$work/v0.1.1" "$work/keys/test.key"
zip_app "$work/evil" "$work/www/tampered-zip/k8sman-0.1.1-macos.zip.new"
mv "$work/www/tampered-zip/k8sman-0.1.1-macos.zip.new" "$work/www/tampered-zip/k8sman-0.1.1-macos.zip"
# 3. Feed edited after signing (points at another archive).
feed tampered-feed "$work/v0.1.1" "$work/keys/test.key"
sed -i '' 's|/tampered-feed/k8sman-0.1.1-macos.zip|/tampered-zip/k8sman-0.1.1-macos.zip|' "$work/www/tampered-feed/appcast.xml"
"$bin/sign_update" --verify --ed-key-file "$work/keys/test.key" "$work/www/good/appcast.xml" >/dev/null
echo "good feed signature verifies with sign_update"

echo "== probe (links the app's own Sparkle.framework)"
# Compile against the SPM build's copy (the app's embedded one has no
# headers); run against a copy of the framework embedded in the app.
ditto "$app/Contents/Frameworks/Sparkle.framework" "$work/fw/Sparkle.framework"
swiftc -O -F "$(dirname "$app")" -framework Sparkle -Xlinker -rpath -Xlinker "$work/fw" \
  tools/update-e2e/UpdateProbe.swift -o "$work/update-probe"

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/www" >"$work/http.log" 2>&1 &
server=$!
cleanup() {
  kill "$server" 2>/dev/null || true
  defaults delete "$test_id" >/dev/null 2>&1 || true
  rm -rf -- "$HOME/Library/Caches/$test_id"
}
trap cleanup EXIT
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$port/good/appcast.xml" >/dev/null && break; sleep 0.1; done

installed="$work/installed/k8sman.app"
install_fresh() {
  rm -rf -- "${work:?}/installed"
  mkdir -p "$work/installed"
  ditto "$work/v0.1.0/k8sman.app" "$installed"
  # As if downloaded with a browser and opened once.
  xattr -w com.apple.quarantine "0081;00000000;Safari;" "$installed"
  defaults delete "$test_id" >/dev/null 2>&1 || true
  rm -rf -- "$HOME/Library/Caches/$test_id"
}

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
pass() { echo "PASS: $*"; }

expect_rejected() {
  local name="$1"
  install_fresh
  set +e
  "$work/update-probe" "$installed" "http://127.0.0.1:$port/$name/appcast.xml" 2>&1 | sed 's/^/  /'
  local rc=${PIPESTATUS[0]}
  set -e
  sleep 2
  if [ "$rc" -eq 0 ]; then fail "$name: probe reported an install"; return; fi
  if [ "$(plist_get "$installed" CFBundleShortVersionString)" != 0.1.0 ] || [ "$(cat "$installed/Contents/Resources/e2e-marker")" != 0.1.0 ]; then
    fail "$name: installed app changed"
    return
  fi
  pass "$name rejected (exit $rc), 0.1.0 untouched"
}

echo "== 1. tampered archive"
expect_rejected tampered-zip
echo "== 2. wrong signing key"
expect_rejected wrong-key
echo "== 3. tampered feed"
expect_rejected tampered-feed

echo "== 4. good update 0.1.0 -> 0.1.1"
install_fresh
set +e
"$work/update-probe" "$installed" "http://127.0.0.1:$port/good/appcast.xml" 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}
set -e
for _ in $(seq 60); do
  [ "$(plist_get "$installed" CFBundleShortVersionString 2>/dev/null)" = 0.1.1 ] && break
  sleep 1
done
v="$(plist_get "$installed" CFBundleShortVersionString 2>/dev/null || echo missing)"
if [ "$v" = 0.1.1 ] && [ "$(cat "$installed/Contents/Resources/e2e-marker")" = 0.1.1 ]; then
  pass "installed 0.1.1 (probe exit $rc)"
  codesign --verify --deep --strict "$installed" && pass "code signature valid" || fail "code signature invalid"
  [ -x "$installed/Contents/MacOS/k8sman-server" ] && pass "k8sman-server replaced with the bundle" || fail "k8sman-server missing"
  if xattr -p com.apple.quarantine "$installed" >/dev/null 2>&1; then fail "update is quarantined"; else pass "update not quarantined"; fi
  grep -q "GET /good/k8sman-0.1.1-macos.zip" "$work/http.log" && pass "downloaded from the local feed" || fail "no download in http.log"
else
  fail "good update not installed (version $v, probe exit $rc)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All update checks passed."
