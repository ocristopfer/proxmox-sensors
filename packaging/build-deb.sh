#!/usr/bin/env bash
# build-deb.sh — builds the pve-sensors_<version>_all.deb package
#
#   packaging/build-deb.sh [version] [output-dir]
#
#   Without a version, uses git describe (v1.2.0 -> 1.2.0). Default output: dist/
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PKG="$ROOT/packaging"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # v1.2.0 -> 1.2.0; v1.2.0-3-gabc123 -> 1.2.0+3+gabc123; no tag -> 0.0.0~gitabc123
  VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' 2>/dev/null \
    || echo "0.0.0~git$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)")"
fi
VERSION="${VERSION#v}"
VERSION="${VERSION//-/+}"
case "$VERSION" in [0-9]*) ;; *) echo "invalid version: $VERSION" >&2; exit 1 ;; esac
OUT="${2:-$ROOT/dist}"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
D="$BUILD/pve-sensors"

install -d "$D/DEBIAN"
sed "s/@VERSION@/$VERSION/" "$PKG/debian/control.in" > "$D/DEBIAN/control"
install -m 0644 "$PKG/debian/conffiles" "$PKG/debian/triggers" "$D/DEBIAN/"
install -m 0755 "$PKG/debian/postinst" "$PKG/debian/prerm" "$PKG/debian/postrm" "$D/DEBIAN/"

# the whole src/ tree, keeping the executable bits
install -d "$D/usr/share/pve-sensors"
cp -R "$ROOT/src/." "$D/usr/share/pve-sensors/"
chmod -R u=rwX,go=rX "$D/usr/share/pve-sensors"
install -D -m 0755 "$PKG/pve-sensors"                "$D/usr/sbin/pve-sensors"
install -D -m 0644 "$PKG/modules-load.conf"          "$D/etc/modules-load.d/pve-sensors.conf"
install -D -m 0644 "$ROOT/LICENSE"                   "$D/usr/share/doc/pve-sensors/copyright"
install -D -m 0644 "$ROOT/README.md"                 "$D/usr/share/doc/pve-sensors/README.md"

mkdir -p "$OUT"
DEB="$OUT/pve-sensors_${VERSION}_all.deb"
dpkg-deb --root-owner-group -Zxz --build "$D" "$DEB" >/dev/null
echo "$DEB"
