#!/bin/bash
# Builds the Go backend (k8sman-server) for embedding in the macOS app.
#
#   tools/build-backend.sh <output-path> [arch ...]
#
# Architectures are Xcode names (arm64, x86_64). With none given, $ARCHS (set
# by Xcode) is used, else the host architecture. Several architectures produce
# a universal binary via lipo. Run from Xcode's "Build k8sman-server" phase in
# frontend/macos/Runner.xcodeproj, and from `make release`.
set -euo pipefail

out="${1:?usage: build-backend.sh <output-path> [arch ...]}"
shift
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

archs=("$@")
if [ ${#archs[@]} -eq 0 ]; then
  # shellcheck disable=SC2206
  archs=(${ARCHS:-$(uname -m)})
fi

# Xcode runs scripts with a minimal PATH; look in the usual install places.
go_bin="$(command -v go || true)"
if [ -z "$go_bin" ]; then
  for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go "$HOME/go/bin/go" /opt/local/bin/go; do
    if [ -x "$candidate" ]; then go_bin="$candidate"; break; fi
  done
fi
if [ -z "$go_bin" ]; then
  echo "error: Go toolchain not found (install Go, e.g. brew install go)" >&2
  exit 1
fi

export GOTOOLCHAIN=local
export CGO_ENABLED=0
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

ldflags="-s -w"
if [ "${CONFIGURATION:-Release}" = "Debug" ]; then ldflags=""; fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

slices=()
for arch in "${archs[@]}"; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
    *) echo "warning: skipping unsupported arch $arch" >&2; continue ;;
  esac
  echo "Building k8sman-server ($goarch) with $go_bin"
  (cd "$root/backend" && GOOS=darwin GOARCH="$goarch" "$go_bin" build -trimpath -ldflags "$ldflags" \
    -o "$tmp/k8sman-server-$goarch" ./cmd/k8sman-server)
  slices+=("$tmp/k8sman-server-$goarch")
done
if [ ${#slices[@]} -eq 0 ]; then
  echo "error: no supported architectures in: ${archs[*]}" >&2
  exit 1
fi

mkdir -p "$(dirname "$out")"
rm -f "$out"
if [ ${#slices[@]} -eq 1 ]; then
  cp "${slices[0]}" "$out"
else
  lipo -create -output "$out" "${slices[@]}"
fi
chmod 755 "$out"

# Sign nested code before Xcode signs the bundle ("-" = ad-hoc).
if [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  [ -z "$identity" ] && identity="-"
  if [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ]; then
    codesign --force --sign "$identity" --options runtime --timestamp=none "$out"
  else
    codesign --force --sign "$identity" --timestamp=none "$out"
  fi
fi
echo "Built $out"
