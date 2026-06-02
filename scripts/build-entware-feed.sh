#!/bin/sh
set -e

PKG_NAME="failover-go"
PKG_VERSION="${PKG_VERSION:-0.1.7-go-experimental}"
PKG_ARCH="${PKG_ARCH:-aarch64-3.10}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
FEED_DIR="$DIST_DIR/entware-feed"
IPK_NAME="${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"
IPK_PATH="$DIST_DIR/$IPK_NAME"
CONTROL_SRC="$ROOT_DIR/packaging/entware/failover-go/control"
PACKAGES_FILE="$FEED_DIR/Packages"
PACKAGES_GZ="$FEED_DIR/Packages.gz"

mkdir -p "$FEED_DIR"

chmod +x "$ROOT_DIR/scripts/build-entware-ipk.sh"
PKG_VERSION="$PKG_VERSION" PKG_ARCH="$PKG_ARCH" "$ROOT_DIR/scripts/build-entware-ipk.sh"

if [ ! -s "$IPK_PATH" ]; then
    echo "ERROR: built package not found: $IPK_PATH" >&2
    exit 1
fi

cp "$IPK_PATH" "$FEED_DIR/$IPK_NAME"
[ -s "$IPK_PATH.sha256" ] && cp "$IPK_PATH.sha256" "$FEED_DIR/$IPK_NAME.sha256"

SIZE="$(wc -c < "$IPK_PATH" | tr -d ' ')"
SHA256="$(sha256sum "$IPK_PATH" | awk '{print $1}')"

sed \
    -e "s/^Version:.*/Version: $PKG_VERSION/" \
    -e "s/^Architecture:.*/Architecture: $PKG_ARCH/" \
    "$CONTROL_SRC" > "$PACKAGES_FILE"
{
    echo "Filename: $IPK_NAME"
    echo "Size: $SIZE"
    echo "SHA256sum: $SHA256"
    echo
} >> "$PACKAGES_FILE"

gzip -c "$PACKAGES_FILE" > "$PACKAGES_GZ"

ls -lh "$FEED_DIR"
echo
echo "Feed files:"
echo "  $FEED_DIR/$IPK_NAME"
echo "  $PACKAGES_FILE"
echo "  $PACKAGES_GZ"
echo
echo "Packages entry:"
cat "$PACKAGES_FILE"
