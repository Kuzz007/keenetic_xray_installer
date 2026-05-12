#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
FAILOVER_CMD="/opt/bin/vless-go-failover"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
HISTORY_CMD="/opt/bin/vless-go-history"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URLS="${CHECK_URLS:-http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
LOG_FILE="${LOG_FILE:-/opt/var/log/vless-go-recover.log}"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
MARKER="vless-go-hourly-recover"
DEFAULT_SCHEDULE="7 * * * *"
QUIET="0"

usage() {
    cat <<EOF
Usage: vless-go-recover check|run|proxy0|xray|watchdog|enable-hourly [CRON]|disable-hourly|status [--quiet]

Commands:
  check          Silent health check only. Prints nothing when OK.
  run            Recovery ladder: check -> Proxy0 refresh -> Xray restart -> watchdog restart -> failover.
  proxy0         Refresh Proxy0 down/up.
  xray           Restart Xray init service.
  watchdog       Restart watchdog init service.
  enable-hourly  Install hourly cron recovery check. Default: '$DEFAULT_SCHEDULE'.
  disable-hourly Remove hourly cron recovery check.
  status         Show hourly recovery cron status.

Notes:
  - Healthy hourly checks are silent.
  - Recovery actions are logged to $LOG_FILE.
  - Router reboot is intentionally not automatic.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET="1"; shift ;;
        *) break ;;
    esac
done

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    LINE="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$LINE" >> "$LOG_FILE"
    [ "$QUIET" = "1" ] || printf '%s\n' "$LINE"
}

history_log() {
    [ -x "$HISTORY_CMD" ] || return 0
    "$HISTORY_CMD" log "$@" >/dev/null 2>&1 || true
}

active_slot() {
    [ -s "$ACTIVE_STORE" ] && sed -n '1p' "$ACTIVE_STORE" || echo "unknown"
}

health_check() {
    command -v curl >/dev/null 2>&1 || return 1
    for URL in $CHECK_URLS; do
        if curl -fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time "$MAX_TIME" \
            "$URL" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

refresh_proxy0() {
    command -v ndmc >/dev/null 2>&1 || { log "Proxy0 refresh skipped: ndmc not found"; return 1; }
    log "Recovery step: refresh $PROXY_IFACE"
    ndmc -c "interface $PROXY_IFACE down" >/dev/null 2>&1 || true
    sleep 2
    ndmc -c "interface $PROXY_IFACE up" >/dev/null 2>&1 || true
    history_log proxy0_refresh source=recover iface="$PROXY_IFACE" result=ok
}

restart_xray() {
    [ -x "$XRAY_INIT" ] || { log "Xray restart skipped: init not found: $XRAY_INIT"; return 1; }
    log "Recovery step: restart Xray"
    "$XRAY_INIT" restart >/dev/null 2>&1 || "$XRAY_INIT" start >/dev/null 2>&1 || return 1
    sleep 5
    history_log xray_restart source=recover result=ok
}

restart_watchdog() {
    [ -x "$WATCHDOG_INIT" ] || { log "Watchdog restart skipped: init not found: $WATCHDOG_INIT"; return 1; }
    log "Recovery step: restart watchdog"
    "$WATCHDOG_INIT" restart >/dev/null 2>&1 || "$WATCHDOG_INIT" start >/dev/null 2>&1 || return 1
    history_log watchdog_restart source=recover result=ok
}

try_failover() {
    SLOT="$(active_slot)"
    if [ "$SLOT" != "primary" ]; then
        log "Recovery step: failover skipped, active slot is $SLOT"
        return 1
    fi
    [ -s "$BACKUP_STORE" ] || { log "Recovery step: failover skipped, backup is not configured"; return 1; }
    [ -x "$FAILOVER_CMD" ] || { log "Recovery step: failover skipped, command not found: $FAILOVER_CMD"; return 1; }

    log "Recovery step: switch primary -> backup"
    if VLESS_GO_HISTORY_SUPPRESS=1 "$FAILOVER_CMD" switch backup --first >/dev/null 2>&1; then
        sleep 5
        history_log recover_failover from=primary to=backup result=ok
        return 0
    fi

    log "Recovery step failed: switch primary -> backup"
    history_log failed_switch source=recover from=primary to=backup reason=recover_switch_failed
    return 1
}

run_recovery() {
    if health_check; then
        return 0
    fi

    log "Recovery started: SOCKS health failed on $(active_slot)"

    refresh_proxy0 || true
    if health_check; then
        log "Recovery OK after Proxy0 refresh"
        history_log recover_ok step=proxy0 result=ok
        return 0
    fi

    restart_xray || true
    if health_check; then
        log "Recovery OK after Xray restart"
        history_log recover_ok step=xray_restart result=ok
        return 0
    fi

    restart_watchdog || true
    if health_check; then
        log "Recovery OK after watchdog restart"
        history_log recover_ok step=watchdog_restart result=ok
        return 0
    fi

    try_failover || true
    if health_check; then
        log "Recovery OK after failover"
        history_log recover_ok step=failover result=ok
        return 0
    fi

    log "Recovery failed: manual intervention may be required; router reboot is not automatic"
    history_log recover_failed result=failed active="$(active_slot)"
    return 1
}

ensure_cron_files() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch "$CRON_FILE" "$LOG_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

remove_cron() {
    ensure_cron_files
    TMP_FILE="$CRON_FILE.$$"
    grep -v "# $MARKER" "$CRON_FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

enable_hourly() {
    SCHEDULE="${1:-$DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_cron
    printf '%s %s --quiet run # %s\n' "$SCHEDULE" "/opt/bin/vless-go-recover" "$MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    echo "Hourly recovery enabled: $SCHEDULE"
    echo "Healthy checks are silent; recovery actions are logged to $LOG_FILE"
}

disable_hourly() {
    remove_cron
    echo "Hourly recovery disabled."
}

status() {
    ensure_cron_files
    echo "VLESS Go recovery status:"
    echo "  command: /opt/bin/vless-go-recover"
    echo "  health: $(health_check && echo OK || echo FAILED)"
    echo "  active slot: $(active_slot)"
    echo "  socks: $SOCKS_HOST:$SOCKS_PORT"
    echo "  proxy iface: $PROXY_IFACE"
    echo "  log: $LOG_FILE"
    if grep "# $MARKER" "$CRON_FILE" >/dev/null 2>&1; then
        echo "  hourly recovery: enabled"
        grep "# $MARKER" "$CRON_FILE"
    else
        echo "  hourly recovery: disabled"
    fi
    if ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then echo "  crond: running"; else echo "  crond: not running or not visible"; fi
}

CMD="${1:-run}"
shift 2>/dev/null || true
case "$CMD" in
    check) health_check ;;
    run|recover) run_recovery ;;
    proxy0|refresh-proxy0) refresh_proxy0 ;;
    xray|restart-xray) restart_xray ;;
    watchdog|restart-watchdog) restart_watchdog ;;
    enable-hourly|enable) enable_hourly "${1:-}" ;;
    disable-hourly|disable) disable_hourly ;;
    status) status ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
