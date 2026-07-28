#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
GO_EXPERIMENTAL_TAG="${GO_EXPERIMENTAL_TAG:-latest}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-$REPO_BRANCH}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
GO_RESOLVER="/opt/bin/xray-failover-go"
XRAY_GO_CMD="/opt/bin/xray-go"
XRAY_GO_URL="${XRAY_GO_URL:-${RAW_BASE}/scripts/xray-go.sh}"
MANIFEST_CMD="/opt/bin/xray-go-manifest"
MANIFEST_URL="${MANIFEST_URL:-${RAW_BASE}/scripts/xray-go-manifest.sh}"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_UPDATE_URL="${GO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-update.sh}"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_AUTO_UPDATE_URL="${GO_AUTO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-auto-update.sh}"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_FAILOVER_URL="${GO_FAILOVER_URL:-${RAW_BASE}/scripts/vless-go-failover.sh}"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_HISTORY_URL="${GO_HISTORY_URL:-${RAW_BASE}/scripts/vless-go-history.sh}"
GO_CLEANUP_CMD="/opt/bin/vless-go-cleanup"
GO_CLEANUP_URL="${GO_CLEANUP_URL:-${RAW_BASE}/scripts/vless-go-cleanup.sh}"
GO_RECOVER_CMD="/opt/bin/vless-go-recover"
GO_RECOVER_URL="${GO_RECOVER_URL:-${RAW_BASE}/scripts/vless-go-recover.sh}"
GO_SOCKS_AUTH_CMD="/opt/bin/vless-go-socks-auth"
GO_SOCKS_AUTH_URL="${GO_SOCKS_AUTH_URL:-${RAW_BASE}/scripts/vless-go-socks-auth.sh}"
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
ENABLE_HOURLY_RECOVERY="${ENABLE_HOURLY_RECOVERY:-1}"
HOURLY_RECOVERY_SCHEDULE="${HOURLY_RECOVERY_SCHEDULE:-7 * * * *}"


detect_entware_arch() {
    OPKG_BIN=""
    if command -v opkg >/dev/null 2>&1; then OPKG_BIN="$(command -v opkg)"; elif [ -x /opt/bin/opkg ]; then OPKG_BIN="/opt/bin/opkg"; fi
    if [ -n "$OPKG_BIN" ]; then "$OPKG_BIN" print-architecture 2>/dev/null | awk '$2 != "all" && ($3 + 0) >= max { arch = $2; max = $3 + 0 } END { if (arch != "") print arch }'; fi
}

asset_name_for_arch() {
    ARCH="$1"
    case "$ARCH" in aarch64-3.10|aarch64*|arm64) echo "xray-failover-go-linux-arm64" ;; mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*) echo "xray-failover-go-linux-mipsle" ;; *) echo "" ;; esac
}

ENTWARE_ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ENTWARE_ARCH" ] || ENTWARE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
GO_ASSET_NAME="${GO_ASSET_NAME:-$(asset_name_for_arch "$ENTWARE_ARCH")}" 
[ -n "$GO_ASSET_NAME" ] || { echo "ERROR: unsupported architecture for Go resolver: $ENTWARE_ARCH" >&2; exit 1; }
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_EXPERIMENTAL_TAG}/${GO_ASSET_NAME}}"

usage() {
    echo "Usage: xray-go-installer-update [--no-restart] [--no-binary] [--no-watchdog] [--no-doctor] [--no-helpers] [--no-menu] [--no-xray-core-updater] [--first]"
    echo ""
    echo "Обновляет установленные компоненты experimental Go edition без повторного ввода VLESS-ссылок."
    echo ""
    echo "Options:"
    echo "  --no-restart             Не перезапускать watchdog/Xray после обновления."
    echo "  --no-binary              Не обновлять /opt/bin/xray-failover-go."
    echo "  --no-watchdog            Не переустанавливать watchdog helper/init/config."
    echo "  --no-doctor              Не устанавливать/обновлять /opt/bin/vless-go-doctor."
    echo "  --no-helpers             Не устанавливать/обновлять helper-команды."
    echo "  --no-menu                Не устанавливать/обновлять /opt/bin/failover-go."
    echo "  --no-xray-core-updater   Не устанавливать/обновлять /opt/bin/vless-go-xray-core-update."
    echo "  --first                  Пересобрать активный Xray config с первым профилем подписки."
    echo ""
    echo "Environment:"
    echo "  ENABLE_HOURLY_RECOVERY=0 disables automatic hourly recovery enablement."
    echo "  HOURLY_RECOVERY_SCHEDULE='7 * * * *' overrides recovery cron schedule."
}

is_pid_alive() { PID="$1"; [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; }
cleanup_stale_lock() { [ -d "$LOCK_DIR" ] || return 0; PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"; if ! is_pid_alive "$PID"; then echo "Removing stale VLESS Go lock: $LOCK_DIR"; rm -rf "$LOCK_DIR" 2>/dev/null || true; fi; }

acquire_lock() {
    OWNER="${1:-xray-go-installer-update}"
    if [ "${VLESS_GO_LOCK_HELD:-0}" = "1" ]; then return 0; fi
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
        NOW="$(date +%s)"; ELAPSED="$((NOW - START))"
        if [ "$ELAPSED" -ge "$LOCK_WAIT" ]; then
            OWNER_TEXT="$(cat "$LOCK_DIR/owner" 2>/dev/null || echo unknown)"; PID_TEXT="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo unknown)"
            echo "ERROR: VLESS Go lock is busy: owner=$OWNER_TEXT pid=$PID_TEXT path=$LOCK_DIR" >&2
            return 1
        fi
        sleep 1
    done
}

release_lock() { if [ "$LOCK_HELD" = "1" ]; then PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"; [ "$PID" = "$$" ] && rm -rf "$LOCK_DIR" 2>/dev/null || true; LOCK_HELD="0"; fi; }

update_manifest() {
    [ -x "$MANIFEST_CMD" ] || return 0
    BINARY_SHA256="$(sha256_file "$GO_RESOLVER")"
    "$MANIFEST_CMD" init \
        --install-mode opkg \
        --edition full \
        --version "$GO_EXPERIMENTAL_TAG" \
        --arch "$ENTWARE_ARCH" \
        --channel "$REPO_BRANCH" \
        --source "$GO_BINARY_URL" \
        --binary-path "$GO_RESOLVER" \
        --binary-sha256 "$BINARY_SHA256" \
        --modules "subscriptions,cron,watchdog,recovery,doctor,history,cleanup,update-core" >/dev/null 2>&1 || echo "WARNING: failed to update xray-go manifest." >&2
}

NO_RESTART="0"; NO_BINARY="0"; NO_WATCHDOG="0"; NO_DOCTOR="0"; NO_HELPERS="0"; NO_MENU="0"; NO_XRAY_CORE_UPDATER="0"; FIRST="0"
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

if ! command -v opkg >/dev/null 2>&1; then echo "ERROR: opkg not found. Entware is required." >&2; exit 1; fi
if ! command -v curl >/dev/null 2>&1; then opkg update; opkg install curl ca-bundle; else opkg install ca-bundle >/dev/null 2>&1 || true; fi
mkdir -p /opt/bin /opt/libexec "$XRAY_DIR" "$TMP_DIR"

install_executable() { URL="$1"; DEST="$2"; NAME="$3"; TMP_FILE="$TMP_DIR/$(basename "$DEST").$$"; echo "Updating $NAME..."; curl -fL -o "$TMP_FILE" "$URL"; chmod +x "$TMP_FILE"; mv "$TMP_FILE" "$DEST"; chmod +x "$DEST"; }
install_readable_helper() { URL="$1"; DEST="$2"; NAME="$3"; TMP_FILE="$TMP_DIR/$(basename "$DEST").$$"; echo "Updating $NAME..."; curl -fL -o "$TMP_FILE" "$URL"; chmod 644 "$TMP_FILE"; mv "$TMP_FILE" "$DEST"; chmod 644 "$DEST"; }

if [ ! -s "$PRIMARY_STORE" ] && [ -s "$SOURCE_STORE" ]; then cp "$SOURCE_STORE" "$PRIMARY_STORE"; chmod 600 "$PRIMARY_STORE" 2>/dev/null || true; fi
if [ ! -s "$ACTIVE_STORE" ]; then echo "primary" > "$ACTIVE_STORE"; chmod 600 "$ACTIVE_STORE" 2>/dev/null || true; fi
if [ ! -s "$XRAY_DIR/vless-go.primary.selector" ]; then echo "first" > "$XRAY_DIR/vless-go.primary.selector"; chmod 600 "$XRAY_DIR/vless-go.primary.selector" 2>/dev/null || true; fi
if [ ! -s "$XRAY_DIR/vless-go.backup.selector" ]; then echo "first" > "$XRAY_DIR/vless-go.backup.selector"; chmod 600 "$XRAY_DIR/vless-go.backup.selector" 2>/dev/null || true; fi
if [ ! -s "$PRIMARY_STORE" ]; then echo "ERROR: no saved primary source found. Re-run xray_vless_failover_go.sh once." >&2; exit 1; fi

if [ "$NO_BINARY" = "0" ]; then
    TMP_BIN="$TMP_DIR/xray-failover-go.$$"
    echo "Updating Go resolver/generator for $ENTWARE_ARCH ($GO_ASSET_NAME)..."
    curl -fL -o "$TMP_BIN" "$GO_BINARY_URL"
    chmod +x "$TMP_BIN"
    mv "$TMP_BIN" "$GO_RESOLVER"
    chmod +x "$GO_RESOLVER"
fi

if [ "$NO_HELPERS" = "0" ]; then
    install_readable_helper "$LOCK_HELPER_URL" "$LOCK_HELPER" "lock helper"
    install_executable "$XRAY_GO_URL" "$XRAY_GO_CMD" "xray-go wrapper"
    install_executable "$MANIFEST_URL" "$MANIFEST_CMD" "xray-go manifest helper"
    install_executable "$GO_UPDATE_URL" "$GO_UPDATE_CMD" "vless-go-update helper"
    install_executable "$GO_FAILOVER_URL" "$GO_FAILOVER_CMD" "vless-go-failover helper"
    install_executable "$GO_AUTO_UPDATE_URL" "$GO_AUTO_UPDATE_CMD" "vless-go-auto-update helper"
    install_executable "$GO_HISTORY_URL" "$GO_HISTORY_CMD" "vless-go-history helper"
    install_executable "$GO_CLEANUP_URL" "$GO_CLEANUP_CMD" "vless-go-cleanup helper"
    install_executable "$GO_RECOVER_URL" "$GO_RECOVER_CMD" "vless-go-recover helper"
    install_executable "$GO_SOCKS_AUTH_URL" "$GO_SOCKS_AUTH_CMD" "vless-go-socks-auth helper"
fi

[ "$NO_MENU" = "0" ] && install_executable "$FAILOVER_GO_URL" "$FAILOVER_GO_CMD" "failover-go menu"
[ "$NO_XRAY_CORE_UPDATER" = "0" ] && install_executable "$XRAY_CORE_UPDATE_URL" "$XRAY_CORE_UPDATE_CMD" "Xray-core updater helper"
[ "$NO_DOCTOR" = "0" ] && install_executable "$DOCTOR_URL" "$DOCTOR_CMD" "doctor helper"

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

update_manifest

if [ "$NO_RESTART" = "0" ]; then
    [ -x "$XRAY_INIT" ] && "$XRAY_INIT" restart || "$XRAY_INIT" start || true
    [ -x "$WATCHDOG_INIT" ] && "$WATCHDOG_INIT" restart || "$WATCHDOG_INIT" start || true
fi

if [ "$ENABLE_HOURLY_RECOVERY" = "1" ] && [ -x "$GO_RECOVER_CMD" ]; then
    echo "Ensuring hourly recovery is enabled..."
    "$GO_RECOVER_CMD" --mode full enable-hourly "$HOURLY_RECOVERY_SCHEDULE" >/dev/null 2>&1 || echo "WARNING: failed to enable hourly recovery. Run: xray-go recover enable-hourly" >&2
fi

echo "Experimental Go edition updated."
echo "Detected architecture: $ENTWARE_ARCH"
echo "Go resolver asset: $GO_ASSET_NAME"
echo "Primary source: $PRIMARY_STORE"
echo "Backup source: $BACKUP_STORE"
echo "Active slot: $(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
echo "Primary selector: $(sed -n '1p' "$XRAY_DIR/vless-go.primary.selector" 2>/dev/null || echo first)"
echo "Backup selector: $(sed -n '1p' "$XRAY_DIR/vless-go.backup.selector" 2>/dev/null || echo first)"
echo "Watchdog config: $WATCHDOG_CONF"
echo "Unified command: $XRAY_GO_CMD"
echo "Manifest command: $MANIFEST_CMD"
echo "Doctor command: $DOCTOR_CMD"
echo "Lock helper: $LOCK_HELPER"
echo "History command: $GO_HISTORY_CMD"
echo "Cleanup command: $GO_CLEANUP_CMD"
echo "Recovery command: $GO_RECOVER_CMD"
echo "SOCKS auth command: $GO_SOCKS_AUTH_CMD"
echo "Menu command: $FAILOVER_GO_CMD"
echo "Xray-core updater command: $XRAY_CORE_UPDATE_CMD"
