#!/bin/sh
set -e

PKG_NAME="failover-go"
PKG_VERSION="${PKG_VERSION:-0.1.2-go-experimental}"
PKG_ARCH="${PKG_ARCH:-aarch64-3.10}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/dist/ipk-build"
OUT_DIR="$ROOT_DIR/dist"
PKG_DIR="$BUILD_DIR/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}"
CONTROL_SRC="$ROOT_DIR/packaging/entware/failover-go/control"
POSTINST_SRC="$ROOT_DIR/packaging/entware/failover-go/postinst"
PRERM_SRC="$ROOT_DIR/packaging/entware/failover-go/prerm"
OUT_IPK="$OUT_DIR/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"

mkdir -p "$OUT_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_DIR/CONTROL" "$PKG_DIR/opt/bin" "$PKG_DIR/opt/libexec" "$PKG_DIR/opt/etc/init.d"

copy_exec() {
    src="$1"
    dst="$2"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod 755 "$dst"
}

copy_readable() {
    src="$1"
    dst="$2"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod 644 "$dst"
}

copy_exec "$ROOT_DIR/xray_vless_failover_go.sh" "$PKG_DIR/opt/bin/xray_vless_failover_go.sh"
copy_exec "$ROOT_DIR/scripts/failover-go.sh" "$PKG_DIR/opt/bin/failover-go"
copy_exec "$ROOT_DIR/scripts/vless-go-update.sh" "$PKG_DIR/opt/bin/vless-go-update"
copy_exec "$ROOT_DIR/scripts/vless-go-auto-update.sh" "$PKG_DIR/opt/bin/vless-go-auto-update"
copy_exec "$ROOT_DIR/scripts/vless-go-failover.sh" "$PKG_DIR/opt/bin/vless-go-failover"
copy_exec "$ROOT_DIR/scripts/vless-go-watchdog.sh" "$PKG_DIR/opt/bin/vless-go-watchdog"
copy_exec "$ROOT_DIR/scripts/vless-go-history.sh" "$PKG_DIR/opt/bin/vless-go-history"
copy_exec "$ROOT_DIR/scripts/vless-go-cleanup.sh" "$PKG_DIR/opt/bin/vless-go-cleanup"
copy_exec "$ROOT_DIR/scripts/vless-go-doctor.sh" "$PKG_DIR/opt/bin/vless-go-doctor"
copy_exec "$ROOT_DIR/scripts/vless-go-xray-core-update.sh" "$PKG_DIR/opt/bin/vless-go-xray-core-update"
copy_exec "$ROOT_DIR/scripts/xray-go-installer-update.sh" "$PKG_DIR/opt/bin/xray-go-installer-update"
copy_readable "$ROOT_DIR/scripts/vless-go-lock.sh" "$PKG_DIR/opt/libexec/vless-go-lock.sh"
copy_exec "$ROOT_DIR/packaging/entware/failover-go/postinst" "$PKG_DIR/CONTROL/postinst"
copy_exec "$ROOT_DIR/packaging/entware/failover-go/prerm" "$PKG_DIR/CONTROL/prerm"

sed \
    -e "s/^Version:.*/Version: $PKG_VERSION/" \
    -e "s/^Architecture:.*/Architecture: $PKG_ARCH/" \
    "$CONTROL_SRC" > "$PKG_DIR/CONTROL/control"
chmod 644 "$PKG_DIR/CONTROL/control"

# Build data.tar.gz and control.tar.gz from inside package root.
(
    cd "$PKG_DIR"
    tar --numeric-owner --owner=0 --group=0 -czf "$BUILD_DIR/data.tar.gz" ./opt
    cd CONTROL
    tar --numeric-owner --owner=0 --group=0 -czf "$BUILD_DIR/control.tar.gz" ./control ./postinst ./prerm
)

echo '2.0' > "$BUILD_DIR/debian-binary"
(
    cd "$BUILD_DIR"
    tar -czf "$OUT_IPK" ./debian-binary ./control.tar.gz ./data.tar.gz
)

sha256sum "$OUT_IPK" > "$OUT_IPK.sha256"
ls -lh "$OUT_IPK" "$OUT_IPK.sha256"
