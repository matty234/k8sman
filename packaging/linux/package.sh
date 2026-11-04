#!/usr/bin/env bash
# Packages a `flutter build linux --release` bundle (with k8sman-server next
# to k8sman) as:
#   <out>/k8sman-<version>-linux-x64.tar.gz   unpack anywhere, run ./k8sman
#                                             (./install.sh adds a launcher)
#   <out>/k8sman_<version>_amd64.deb          /opt/k8sman + /usr/bin/k8sman
# Usage: package.sh <version> <bundle dir> <out dir>
set -euo pipefail
version=$1 bundle=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
out=$(cd "$out" && pwd)
test -x "$bundle/k8sman" && test -x "$bundle/k8sman-server"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Tarball.
mkdir "$work/k8sman"
cp -a "$bundle/." "$work/k8sman/"
cp "$here/k8sman.png" "$here/install.sh" "$work/k8sman/"
cp "$here/k8sman.desktop" "$work/k8sman/k8sman.desktop.in"
tar -C "$work" -czf "$out/k8sman-$version-linux-x64.tar.gz" k8sman

# Debian package. Versions must start with a digit; 0.2.0-rc.1 -> 0.2.0~rc.1
# so pre-releases sort before the release.
deb_version=${version/-/\~}
root="$work/deb"
mkdir -p "$root/DEBIAN" "$root/opt/k8sman" "$root/usr/bin" \
  "$root/usr/share/applications" "$root/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle/." "$root/opt/k8sman/"
ln -s /opt/k8sman/k8sman "$root/usr/bin/k8sman"
cp "$here/k8sman.png" "$root/usr/share/icons/hicolor/256x256/apps/k8sman.png"
sed -e 's|@EXEC@|/opt/k8sman/k8sman|' -e 's|@ICON@|k8sman|' "$here/k8sman.desktop" > "$root/usr/share/applications/k8sman.desktop"
size=$(du -sk "$root" | cut -f1)
cat > "$root/DEBIAN/control" <<CONTROL
Package: k8sman
Version: $deb_version
Section: devel
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 | libgtk-3-0t64, libglib2.0-0 | libglib2.0-0t64, libstdc++6
Installed-Size: $size
Maintainer: The k8sman authors <https://github.com/matty234/k8sman>
Homepage: https://github.com/matty234/k8sman
Description: Native Kubernetes IDE
 Browse and edit cluster resources with live tables, logs, terminals,
 port-forwards, metrics, Helm, Argo and RBAC tools. Uses your kubeconfig.
CONTROL
# Files root-owned regardless of who built them.
dpkg-deb --root-owner-group --build "$root" "$out/k8sman_${deb_version}_amd64.deb"
ls -la "$out"
