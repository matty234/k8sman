#!/bin/sh
# Installs k8sman for the current user from this unpacked folder:
# a launcher in ~/.local/share/applications (app menu) and
# ~/.local/bin/k8sman. Re-run after moving the folder. No root needed.
# Remove with: ./install.sh --uninstall
set -eu
here=$(cd "$(dirname "$0")" && pwd)
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
bin="$HOME/.local/bin"
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$apps/k8sman.desktop" "$icons/k8sman.png" "$bin/k8sman"
  echo "Removed the k8sman launcher (this folder is untouched)."
  exit 0
fi
mkdir -p "$apps" "$icons" "$bin"
cp "$here/k8sman.png" "$icons/k8sman.png"
sed -e "s|@EXEC@|\"$here/k8sman\"|" -e "s|@ICON@|k8sman|" "$here/k8sman.desktop.in" > "$apps/k8sman.desktop"
ln -sf "$here/k8sman" "$bin/k8sman"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" >/dev/null 2>&1 || true
echo "Installed: k8sman is in your app menu, and ~/.local/bin/k8sman runs it."
