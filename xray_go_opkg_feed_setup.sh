#!/bin/sh
set -e

FEED_NAME="${FEED_NAME:-keenetic-xray-go-experimental}"
FEED_URL="${FEED_URL:-https://kuzz007.github.io/keenetic_xray_installer/opkg/all}"
FEED_FILE="/opt/etc/opkg/${FEED_NAME}.conf"

if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg not found. Entware is required." >&2
    exit 1
fi

mkdir -p /opt/etc/opkg
printf 'src/gz %s %s\n' "$FEED_NAME" "$FEED_URL" > "$FEED_FILE"

echo "Added opkg feed: $FEED_FILE"
cat "$FEED_FILE"

echo "Updating opkg indexes..."
opkg update

echo "Install command:"
echo "  opkg install keenetic-xray-go-experimental"

echo "After package install:"
echo "  xray-go-install"
echo "  xray-go-repo-update"
