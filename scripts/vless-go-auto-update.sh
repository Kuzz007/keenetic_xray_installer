#!/bin/sh
set -e

GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
AWG_RUNTIME_STATE="/opt/etc/xray/awg/runtime.json"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
LOG_FILE="/opt/var/log/vless-go-auto-update.log"
MARKER="vless-go-auto-update"
DEFAULT_SCHEDULE="17 4 * * *"

usage() {
    echo "Usage: vless-go-auto-update enable [CRON_SCHEDULE] | disable | status | run"
    echo ""
    echo "Auto-update uses the saved selector for the active slot."
    echo "Selectors are stored in:"
    echo "  /opt/etc/xray/vless-go.primary.selector"
    echo "  /opt/etc/xray/vless-go.backup.selector"
}

cron_running() {
    ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1
}

ensure_cron_files() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch "$CRON_FILE" "$LOG_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

restart_cron() {
    if command -v crond >/dev/null 2>&1 && ! cron_running; then
        if [ -x /opt/etc/init.d/S10cron ]; then
            /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
        elif [ -x /opt/etc/init.d/S10crond ]; then
            /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
        else
            crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        fi
    fi
}

remove_existing() {
    ensure_cron_files
    TMP_FILE="$CRON_FILE.$$"
    grep -v "# $MARKER" "$CRON_FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

enable_auto() {
    SCHEDULE="${1:-$DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_existing
    printf '%s %s run >> %s 2>&1 # %s\n' "$SCHEDULE" "$0" "$LOG_FILE" "$MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    restart_cron
    echo "Enabled VLESS Go auto-update: $SCHEDULE"
    echo "Cron file: $CRON_FILE"
    echo "Log file: $LOG_FILE"
    echo "Mode: active slot with saved selector"
}

disable_auto() {
    remove_existing
    echo "Disabled VLESS Go auto-update."
}

status_auto() {
    ensure_cron_files
    if grep "# $MARKER" "$CRON_FILE" >/dev/null 2>&1; then
        echo "VLESS Go auto-update is enabled:"
        grep "# $MARKER" "$CRON_FILE"
    else
        echo "VLESS Go auto-update is disabled."
    fi

    if [ -x "$GO_FAILOVER_CMD" ]; then
        "$GO_FAILOVER_CMD" status || true
    fi

    if cron_running; then
        echo "cron: running"
    else
        echo "cron: not running or not visible"
    fi
}

run_now() {
    if [ -s "$AWG_RUNTIME_STATE" ]; then
        echo "ERROR: isolated AWG slot owns Xray; auto-update skipped." >&2
        return 1
    fi
    if [ -x "$GO_FAILOVER_CMD" ]; then
        "$GO_FAILOVER_CMD" update-active --no-restart
        if [ -x /opt/etc/init.d/S24xray ]; then
            /opt/etc/init.d/S24xray restart || /opt/etc/init.d/S24xray start || true
        fi
        exit 0
    fi

    [ -x "$GO_UPDATE_CMD" ] || { echo "ERROR: update command not found: $GO_UPDATE_CMD" >&2; exit 1; }
    "$GO_UPDATE_CMD"
}

case "${1:-status}" in
    enable) shift; enable_auto "${1:-}" ;;
    disable) disable_auto ;;
    status) status_auto ;;
    run) run_now ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
