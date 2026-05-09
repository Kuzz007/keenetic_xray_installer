#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/latest/download/xray-failover-go-linux-arm64}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-$REPO_BRANCH}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
GO_RESOLVER="/opt/bin/xray-failover-go"
DOCTOR_CMD="/opt/bin/vless-go-doctor"
DOCTOR_URL="${DOCTOR_URL:-${RAW_BASE}/scripts/vless-go-doctor.sh}"
WATCHDOG_INSTALLER_URL="${WATCHDOG_INSTALLER_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/xray_vless_go_watchdog_install.sh}"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
XRAY_INIT="/opt/etc/init.d/S24xray"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
TMP_DIR="/opt/tmp"

usage() {
    echo "Usage: xray-go-installer-update [--no-restart] [--no-binary] [--no-watchdog] [--no-doctor] [--first]"
    echo ""
    echo "Updates installed experimental Go edition components without asking for VLESS sources again."
    echo ""
    echo "Options:"
    echo "  --no-restart   Do not restart watchdog/Xray after update."
    echo "  --no-binary    Do not update /opt/bin/xray-failover-go."
    echo "  --no-watchdog  Do not reinstall watchdog helper/init/config."
    echo "  --no-doctor    Do not install/update /opt/bin/vless-go-doctor."
    echo "  --first        Rebuild active Xray config using first profile from subscription."
}

NO_RESTART="0"
NO_BINARY="0"
NO_WATCHDOG="0"
NO_DOCTOR="0"
FIRST="0"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-restart) NO_RESTART="1"; shift ;;
        --no-binary) NO_BINARY="1"; shift ;;
        --no-watchdog) NO_WATCHDOG="1"; shift ;;
        --no-doctor) NO_DOCTOR="1"; shift ;;
        --first) FIRST="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

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

mkdir -p /opt/bin "$XRAY_DIR" "$TMP_DIR"

if [ ! -s "$PRIMARY_STORE" ] && [ -s "$SOURCE_STORE" ]; then
    cp "$SOURCE_STORE" "$PRIMARY_STORE"
    chmod 600 "$PRIMARY_STORE" 2>/dev/null || true
fi

if [ ! -s "$ACTIVE_STORE" ]; then
    echo "primary" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true
fi

if [ ! -s "$PRIMARY_STORE" ]; then
    echo "ERROR: no saved primary source found. Re-run xray_vless_failover_go.sh once." >&2
    exit 1
fi

if [ "$NO_BINARY" = "0" ]; then
    TMP_BIN="$TMP_DIR/xray-failover-go.$$"
    echo "Updating Go resolver/generator..."
    curl -fL -o "$TMP_BIN" "$GO_BINARY_URL"
    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$GO_RESOLVER"
    chmod +x "$GO_RESOLVER"
fi

if [ "$NO_DOCTOR" = "0" ]; then
    TMP_DOCTOR="$TMP_DIR/vless-go-doctor.$$"
    echo "Updating doctor helper..."
    curl -fL -o "$TMP_DOCTOR" "$DOCTOR_URL"
    chmod +x "$TMP_DOCTOR"
    mv "$TMP_DOCTOR" "$DOCTOR_CMD"
    chmod +x "$DOCTOR_CMD"
fi

if [ "$NO_WATCHDOG" = "0" ]; then
    TMP_WATCHDOG_INSTALLER="$TMP_DIR/xray_vless_go_watchdog_install.$$"
    echo "Updating watchdog helper/init/config..."
    curl -fL -o "$TMP_WATCHDOG_INSTALLER" "$WATCHDOG_INSTALLER_URL"
    chmod +x "$TMP_WATCHDOG_INSTALLER"
    WATCHDOG_BRANCH="$WATCHDOG_BRANCH" sh "$TMP_WATCHDOG_INSTALLER"
    rm -f "$TMP_WATCHDOG_INSTALLER" 2>/dev/null || true
fi

if command -v vless-go-update >/dev/null 2>&1; then
    echo "Regenerating active Xray config from saved source..."
    UPDATE_ARGS="--no-restart"
    [ "$FIRST" = "0" ] || UPDATE_ARGS="$UPDATE_ARGS --first"
    vless-go-failover update-active $UPDATE_ARGS
else
    echo "WARNING: vless-go-update not found; Xray config was not regenerated." >&2
fi

if [ "$NO_RESTART" = "0" ]; then
    if [ -x "$XRAY_INIT" ]; then
        "$XRAY_INIT" restart || "$XRAY_INIT" start || true
    fi
    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" restart || "$WATCHDOG_INIT" start || true
    fi
fi

echo "Experimental Go edition updated."
echo "Primary source: $PRIMARY_STORE"
echo "Backup source: $BACKUP_STORE"
echo "Active slot: $(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
echo "Watchdog config: $WATCHDOG_CONF"
echo "Doctor command: $DOCTOR_CMD"
