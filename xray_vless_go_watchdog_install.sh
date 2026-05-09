#!/bin/sh
set -e

WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-main}"
WATCHDOG_URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/scripts/vless-go-watchdog.sh}"
WATCHDOG_CMD="/opt/bin/vless-go-watchdog"

if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg not found. Entware is required." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle
else
    opkg install ca-bundle >/dev/null 2>&1 || true
fi

mkdir -p /opt/bin /opt/var/log /opt/var/spool/cron/crontabs

echo "Installing VLESS Go watchdog from: $WATCHDOG_URL"
if ! curl -fL -o "$WATCHDOG_CMD" "$WATCHDOG_URL"; then
    echo "ERROR: failed to download watchdog script." >&2
    exit 1
fi

chmod +x "$WATCHDOG_CMD"

echo "Installed: $WATCHDOG_CMD"
echo ""
echo "Commands:"
echo "  vless-go-watchdog status"
echo "  vless-go-watchdog check"
echo "  vless-go-watchdog enable"
echo "  vless-go-watchdog disable"
echo ""
echo "Default behavior:"
echo "  - checks SOCKS 127.0.0.1:10808 via https://api.ipify.org"
echo "  - if active slot is primary and health-check fails, switches to backup"
echo "  - does not automatically switch from backup back to primary"
