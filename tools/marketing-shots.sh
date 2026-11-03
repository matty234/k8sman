#!/bin/bash
# Renders the README screenshots headlessly and writes them, compressed, to
# docs/images/. Demo data only (frontend/test/marketing/marketing_shots_test.dart).
#
#   tools/marketing-shots.sh            # all shots
#   tools/marketing-shots.sh hero       # one shot (test name)
#
# Compresses with pngquant or oxipng if installed, else ImageMagick (256-colour
# PNG8), else copies the raw PNGs.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
raw="$root/frontend/build/marketing"
out="$root/docs/images"

rm -rf "$raw"
(
  cd "$root/frontend"
  args=(test test/marketing/marketing_shots_test.dart)
  if [ $# -gt 0 ]; then args+=(--plain-name "$1"); fi
  K8SMAN_MARKETING=1 flutter "${args[@]}"
)

mkdir -p "$out"
for f in "$raw"/*.png; do
  name="$(basename "$f")"
  dst="$out/$name"
  if command -v pngquant >/dev/null; then
    pngquant --force --quality 80-95 --strip --output "$dst" "$f"
  elif command -v magick >/dev/null; then
    # No dithering: flat UI colours and the backdrop gradient stay clean.
    magick "$f" -strip -dither None -colors 256 "PNG8:$dst"
  else
    cp "$f" "$dst"
  fi
  if command -v oxipng >/dev/null; then oxipng -q -o 4 --strip safe "$dst"; fi
  printf '%-18s %6s KB\n' "$name" "$(( $(wc -c <"$dst") / 1024 ))"
done
