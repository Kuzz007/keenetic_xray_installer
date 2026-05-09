#!/bin/sh
set -e

PKG_NAME="${PKG_NAME:-keenetic-xray-go-experimental}"
PKG_VERSION="${PKG_VERSION:-0.1.0}"
PKG_ARCH="${PKG_ARCH:-all}"
REPO_URL="${REPO_URL:-https://github.com/Kuzz007/keenetic_xray_installer.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
OUT_DIR="${OUT_DIR:-dist/opkg/all}"
WORK_DIR="${WORK_DIR:-dist/opkg-build}"

PKG_FILE="${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk"
PKG_PATH="$OUT_DIR/$PKG_FILE"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/control" "$WORK_DIR/data/opt/bin" "$OUT_DIR"

cat > "$WORK_DIR/control/control" <<CONTROL
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $PKG_ARCH
Maintainer: Kuzz007
Depends: git, git-http, curl, ca-bundle
Section: net
Priority: optional
Description: Experimental Keenetic Xray VLESS Go installer helpers.
 Provides xray-go-install and xray-go-repo-update wrappers that clone/update
 Kuzz007/keenetic_xray_installer and run the experimental Go installer.
CONTROL

cat > "$WORK_DIR/data/opt/bin/xray-go-install" <<INSTALL
#!/bin/sh
set -e

REPO_URL="\${REPO_URL:-$REPO_URL}"
REPO_BRANCH="\${REPO_BRANCH:-$REPO_BRANCH}"
REPO_DIR="\${REPO_DIR:-/opt/root/keenetic_xray_installer}"
INSTALLER_SCRIPT="xray_vless_failover_go.sh"

if ! command -v git >/dev/null 2>&1; then
    opkg update
    opkg install git git-http ca-bundle || opkg install git ca-bundle
fi
if ! command -v curl >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle
fi

mkdir -p "\$(dirname "\$REPO_DIR")"
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    git fetch origin "\$REPO_BRANCH"
    git checkout "\$REPO_BRANCH"
    git reset --hard "origin/\$REPO_BRANCH"
    git clean -fd
else
    if [ -e "\$REPO_DIR" ]; then
        echo "ERROR: \$REPO_DIR exists but is not a git repository." >&2
        exit 1
    fi
    git clone --depth 1 --branch "\$REPO_BRANCH" "\$REPO_URL" "\$REPO_DIR"
fi

cd "\$REPO_DIR"
chmod +x "\$INSTALLER_SCRIPT"
sh "\$INSTALLER_SCRIPT"
INSTALL

cat > "$WORK_DIR/data/opt/bin/xray-go-repo-update" <<UPDATE
#!/bin/sh
set -e

REPO_URL="\${REPO_URL:-$REPO_URL}"
REPO_BRANCH="\${REPO_BRANCH:-$REPO_BRANCH}"
REPO_DIR="\${REPO_DIR:-/opt/root/keenetic_xray_installer}"
INSTALLER_SCRIPT="xray_vless_failover_go.sh"
INTERACTIVE="0"

case "\${1:-}" in
    --interactive)
        INTERACTIVE="1"
        shift
        ;;
    -h|--help)
        echo "Usage: xray-go-repo-update [--interactive]"
        echo "  default: update repo and run installer with --reuse-saved"
        echo "  --interactive: ask for primary/backup sources again"
        exit 0
        ;;
    "")
        ;;
    *)
        echo "ERROR: unknown argument: \$1" >&2
        exit 1
        ;;
esac

if ! command -v git >/dev/null 2>&1; then
    opkg update
    opkg install git git-http ca-bundle || opkg install git ca-bundle
fi

mkdir -p "\$(dirname "\$REPO_DIR")"
if [ -d "\$REPO_DIR/.git" ]; then
    cd "\$REPO_DIR"
    git fetch origin "\$REPO_BRANCH"
    git checkout "\$REPO_BRANCH"
    git reset --hard "origin/\$REPO_BRANCH"
    git clean -fd
else
    git clone --depth 1 --branch "\$REPO_BRANCH" "\$REPO_URL" "\$REPO_DIR"
fi

cd "\$REPO_DIR"
chmod +x "\$INSTALLER_SCRIPT"
if [ "\$INTERACTIVE" = "1" ]; then
    sh "\$INSTALLER_SCRIPT"
else
    sh "\$INSTALLER_SCRIPT" --reuse-saved
fi
UPDATE

chmod 0755 "$WORK_DIR/data/opt/bin/xray-go-install" "$WORK_DIR/data/opt/bin/xray-go-repo-update"

echo "2.0" > "$WORK_DIR/debian-binary"
(
    cd "$WORK_DIR/control"
    tar --owner=0 --group=0 -czf ../control.tar.gz .
)
(
    cd "$WORK_DIR/data"
    tar --owner=0 --group=0 -czf ../data.tar.gz .
)

rm -f "$PKG_PATH"
(
    cd "$WORK_DIR"
    ar r "$OLDPWD/$PKG_PATH" debian-binary control.tar.gz data.tar.gz >/dev/null 2>&1 || ar -r "$OLDPWD/$PKG_PATH" debian-binary control.tar.gz data.tar.gz
)

PKG_SIZE="$(wc -c < "$PKG_PATH" | tr -d ' ')"
PKG_MD5="$(md5sum "$PKG_PATH" | awk '{print $1}')"
PKG_SHA256="$(sha256sum "$PKG_PATH" | awk '{print $1}')"

cat > "$OUT_DIR/Packages" <<PACKAGES
Package: $PKG_NAME
Version: $PKG_VERSION
Architecture: $PKG_ARCH
Maintainer: Kuzz007
Depends: git, git-http, curl, ca-bundle
Section: net
Priority: optional
Filename: $PKG_FILE
Size: $PKG_SIZE
MD5Sum: $PKG_MD5
SHA256sum: $PKG_SHA256
Description: Experimental Keenetic Xray VLESS Go installer helpers.
 Provides xray-go-install and xray-go-repo-update wrappers that clone/update
 Kuzz007/keenetic_xray_installer and run the experimental Go installer.

PACKAGES

gzip -9c "$OUT_DIR/Packages" > "$OUT_DIR/Packages.gz"

echo "Created: $PKG_PATH"
echo "Created: $OUT_DIR/Packages"
echo "Created: $OUT_DIR/Packages.gz"
