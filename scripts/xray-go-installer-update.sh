#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/latest/download/xray-failover-go-linux-arm64}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-$REPO_BRANCH}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_UPDATE_URL="${GO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-update.sh}"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_AUTO_UPDATE_URL="${GO_AUTO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-auto-update.sh}"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_FAILOVER_URL="${GO_FAILOVER_URL:-${RAW_BASE}/scripts/vless-go-failover.sh}"
FAILOVER_GO_CMD="/opt/bin/failover-go"
FAILOVER_GO_URL="${FAILOVER_GO_URL:-${RAW_BASE}/scripts/failover-go.sh}"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
XRAY_CORE_UPDATE_URL="${XRAY_CORE_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-xray-core-update.sh}"
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"
LOCK_HELPER_URL="${LOCK_HELPER_URL:-${RAW_BASE}/scripts/vless-go-lock.sh}"
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
LOCK_DIR="${VLESS_GO_LOCK_DIR:-/opt/var/run/vless-go.lock}"
LOCK_WAIT="${VLESS_GO_LOCK_WAIT:-30}"
LOCK_HELD="0"

usage() {
    echo "Usage: xray-go-installer-update [--no-restart] [--no-binary] [--no-watchdog] [--no-doctor] [--no-helpers] [--no-menu] [--no-xray-core-updater] [--first]"
    echo ""
    echo "Updates installed experimental Go edition components without asking for VLESS sources again."
    echo ""
    echo "Options:"
    echo "  --no-restart             Do not restart watchdog/Xray after update."
    echo "  --no-binary              Do not update /opt/bin/xray-failover-go."
    echo "  --no-watchdog            Do not reinstall watchdog helper/init/config."
    echo "  --no-doctor              Do not install/update /opt/bin/vless-go-doctor."
    echo "  --no-helpers             Do not install/update vless-go-update/failover/auto-update helpers."
    echo "  --no-menu                Do not install/update /opt/bin/failover-go."
    echo "  --no-xray-core-updater   Do not install/update /opt/bin/vless-go-xray-core-update."
    echo "  --first                  Rebuild active Xray config using first profile from subscription."
}

is_pid_alive() {
    PID="$1"
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}

cleanup_stale_lock() {
    [ -d "$LOCK_DIR" ] || return 0
    PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if ! is_pid_alive "$PID"; then
        echo "Removing stale VLESS Go lock: $LOCK_DIR"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

acquire_lock() {
    OWNER="${1:-xray-go-installer-update}"

    if [ "${VLESS_GO_LOCK_HELD:-0}" = "1" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null || true
    START="$(date +%s)"

    while true; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            LOCK_HELD="1"
            printf '%s\n' "$$" > "$LOCK_DIR/pid"
            printf '%s\n' "$OWNER" > "$LOCK_DIR/owner"
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOCK_DIR/created_at"
            export VLESS_GO_LOCK_HELD=1
            trap 'release_lock' EXIT INT TERM
            return 0
        fi

        cleanup_stale_lock

        NOW="$(date +%s)"
        ELAPSED="$((NOW - START))"
        if [ "$ELAPSED" -ge "$LOCK_WAIT" ]; then
            OWNER_TEXT="$(cat "$LOCK_DIR/owner" 2>/dev/null || echo unknown)"
            PID_TEXT="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)"
            echo "ERROR: VLESS Go lock is busy: owner=$OWNER_TEXT pid=$PID_TEXT path=$LOCK_DIR" >&2
            return 1
        fi

        sleep 1
    done
}

release_lock() {
    if [ "$LOCK_HELD" = "1" ]; then
        PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ "$PID" = "$$" ]; then
            rm -rf "$LOCK_DIR" 2>/dev/null || true
        fi
        LOCK_HELD="0"
    fi
}

NO_RESTART="0"
NO_BINARY="0"
NO_WATCHDOG="0"
NO_DOCTOR="0"
NO_HELPERS="0"
NO_MENU="0"
NO_XRAY_CORE_UPDATER="0"
FIRST="0"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-restart) NO_RESTART="1"; shift ;;
        --no-binary) NO_BINARY="1"; shift ;;
        --no-watchdog) NO_WATCHDOG="1"; shift ;;
        --no-doctor) NO_DOCTOR="1"; shift ;;
        --no-helpers) NO_HELPERS="1"; shift ;;
        --no-menu) NO_MENU="1"; shift ;;
        --no-xray-core-updater) NO_XRAY_CORE_UPDATER="1"; shift ;;
        --first) FIRST="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

acquire_lock "xray-go-installer-update"

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

mkdir -p /opt/bin /opt/libexec "$XRAY_DIR" "$TMP_DIR"

install_executable() {
    URL="$1"
    DEST="$2"
    NAME="$3"
    TMP_FILE="$TMP_DIR/$(basename "$DEST").$$"
    echo "Updating $NAME..."
    curl -fL -o "$TMP_FILE" "$URL"
    chmod +x "$TMP_FILE"
    mv "$TMP_FILE" "$DEST"
    chmod +x "$DEST"
}

install_readable_helper() {
    URL="$1"
    DEST="$2"
    NAME="$3"
    TMP_FILE="$TMP_DIR/$(basename "$DEST").$$"
    echo "Updating $NAME..."
    curl -fL -o "$TMP_FILE" "$URL"
    chmod 644 "$TMP_FILE"
    mv "$TMP_FILE" "$DEST"
    chmod 644 "$DEST"
}

if [ ! -s "$PRIMARY_STORE" ] && [ -s "$SOURCE_STORE" ]; then
    cp "$SOURCE_STORE" "$PRIMARY_STORE"
    chmod 600 "$PRIMARY_STORE" 2>/dev/null || true
fi

if [ ! -s "$ACTIVE_STORE" ]; then
    echo "primary" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true
fi

if [ ! -s "$XRAY_DIR/vless-go.primary.selector" ]; then
    echo "first" > "$XRAY_DIR/vless-go.primary.selector"
    chmod 600 "$XRAY_DIR/vless-go.primary.selector" 2>/dev/null || true
fi
if [ ! -s "$XRAY_DIR/vless-go.backup.selector" ]; then
    echo "first" > "$XRAY_DIR/vless-go.backup.selector"
    chmod 600 "$XRAY_DIR/vless-go.backup.selector" 2>/dev/null || true
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

if [ "$NO_HELPERS" = "0" ]; then
    install_readable_helper "$LOCK_HELPER_URL" "$LOCK_HELPER" "lock helper"
    install_executable "$GO_UPDATE_URL" "$GO_UPDATE_CMD" "vless-go-update helper"
    install_executable "$GO_FAILOVER_URL" "$GO_FAILOVER_CMD" "vless-go-failover helper"
    install_executable "$GO_AUTO_UPDATE_URL" "$GO_AUTO_UPDATE_CMD" "vless-go-auto-update helper"
fi

if [ "$NO_MENU" = "0" ]; then
    install_executable "$FAILOVER_GO_URL" "$FAILOVER_GO_CMD" "failover-go menu"
fi

if [ "$NO_XRAY_CORE_UPDATER" = "0" ]; then
    install_executable "$XRAY_CORE_UPDATE_URL" "$XRAY_CORE_UPDATE_CMD" "Xray-core updater helper"
fi

if [ "$NO_DOCTOR" = "0" ]; then
    install_executable "$DOCTOR_URL" "$DOCTOR_CMD" "doctor helper"
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
    [ "$FIRST" = "0" ] || UPDATE_ARGS="$UPDATE_ARGS --selector first"
    VLESS_GO_LOCK_HELD=1 vless-go-failover update-active $UPDATE_ARGS
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
echo "Primary selector: $(sed -n '1p' "$XRAY_DIR/vless-go.primary.selector" 2>/dev/null || echo first)"
echo "Backup selector: $(sed -n '1p' "$XRAY_DIR/vless-go.backup.selector" 2>/dev/null || echo first)"
echo "Watchdog config: $WATCHDOG_CONF"
echo "Doctor command: $DOCTOR_CMD"
echo "Lock helper: $LOCK_HELPER"
echo "Menu command: $FAILOVER_GO_CMD"
echo "Xray-core updater command: $XRAY_CORE_UPDATE_CMD"
