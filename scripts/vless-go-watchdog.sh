#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
FAILOVER_CMD="/opt/bin/vless-go-failover"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-https://api.ipify.org}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
MAX_TIME="${MAX_TIME:-15}"
CHECK_RETRIES="${CHECK_RETRIES:-5}"
CHECK_RETRY_DELAY="${CHECK_RETRY_DELAY:-2}"
LOG_FILE="${LOG_FILE:-/opt/var/log/vless-go-watchdog.log}"
DETAIL_LOG_FILE="${DETAIL_LOG_FILE:-/opt/var/log/vless-go-watchdog-detail.log}"
MARKER="vless-go-watchdog"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
DEFAULT_SCHEDULE="*/5 * * * *"

usage() {
    echo "Usage: vless-go-watchdog check | status | enable [CRON_SCHEDULE] | disable | run-primary | run-backup"
    echo ""
    echo "Commands:"
    echo "  check        Check current SOCKS. If it fails on primary, switch to backup."
    echo "  status       Show active slot, backup availability, and cron status."
    echo "  enable       Add cron entry. Default schedule: */5 * * * *"
    echo "  disable      Remove cron entry."
    echo "  run-primary  Manually switch to primary and test."
    echo "  run-backup   Manually switch to backup and test."
    echo ""
    echo "Environment:"
    echo "  CHECK_URL=$CHECK_URL"
    echo "  SOCKS_HOST=$SOCKS_HOST"
    echo "  SOCKS_PORT=$SOCKS_PORT"
    echo "  CONNECT_TIMEOUT=$CONNECT_TIMEOUT"
    echo "  MAX_TIME=$MAX_TIME"
    echo "  CHECK_RETRIES=$CHECK_RETRIES"
    echo "  CHECK_RETRY_DELAY=$CHECK_RETRY_DELAY"
    echo "  LOG_FILE=$LOG_FILE"
    echo "  DETAIL_LOG_FILE=$DETAIL_LOG_FILE"
}

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_detail() {
    mkdir -p "$(dirname "$DETAIL_LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DETAIL_LOG_FILE"
}

active_slot() {
    if [ -s "$ACTIVE_STORE" ]; then
        sed -n '1p' "$ACTIVE_STORE"
    else
        echo "unknown"
    fi
}

ensure_failover_cmd() {
    if [ ! -x "$FAILOVER_CMD" ]; then
        log "ERROR: failover command not found: $FAILOVER_CMD"
        exit 1
    fi
}

check_socks_once() {
    TMP_OUT="/tmp/vless-go-watchdog.check.$$"
    TMP_ERR="/tmp/vless-go-watchdog.err.$$"

    set +e
    curl -fsS \
        --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$CHECK_URL" >"$TMP_OUT" 2>"$TMP_ERR"
    RC="$?"
    set -e

    if [ "$RC" -eq 0 ]; then
        rm -f "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true
        return 0
    fi

    ERR_MSG="$(tr '\n' ' ' < "$TMP_ERR" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g')"
    rm -f "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true
    [ -n "$ERR_MSG" ] && log "Health check curl error rc=$RC: $ERR_MSG"
    return "$RC"
}

check_socks() {
    ATTEMPT="1"
    while [ "$ATTEMPT" -le "$CHECK_RETRIES" ]; do
        if check_socks_once; then
            [ "$ATTEMPT" = "1" ] || log "Health check OK on retry $ATTEMPT/$CHECK_RETRIES"
            return 0
        fi

        if [ "$ATTEMPT" -lt "$CHECK_RETRIES" ]; then
            log "Health check attempt $ATTEMPT/$CHECK_RETRIES failed; retrying in ${CHECK_RETRY_DELAY}s"
            sleep "$CHECK_RETRY_DELAY"
        fi
        ATTEMPT="$((ATTEMPT + 1))"
    done

    return 1
}

switch_to() {
    SLOT="$1"
    ensure_failover_cmd
    log "Switching to $SLOT"

    TMP_SWITCH="/tmp/vless-go-watchdog.switch.$$"
    set +e
    "$FAILOVER_CMD" switch "$SLOT" --first >"$TMP_SWITCH" 2>&1
    RC="$?"
    set -e

    cat "$TMP_SWITCH" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    rm -f "$TMP_SWITCH" 2>/dev/null || true

    if [ "$RC" -ne 0 ]; then
        log "ERROR: switch to $SLOT failed; see detail log."
        return "$RC"
    fi

    log "Switch to $SLOT completed"
    return 0
}

check_and_switch() {
    SLOT="$(active_slot)"
    log "Checking active slot: $SLOT via SOCKS $SOCKS_HOST:$SOCKS_PORT"

    if check_socks; then
        log "Health check OK on $SLOT"
        return 0
    fi

    log "Health check FAILED on $SLOT"

    if [ "$SLOT" = "primary" ]; then
        if [ ! -s "$BACKUP_STORE" ]; then
            log "Backup is not configured; cannot fail over."
            return 1
        fi

        switch_to backup
        if check_socks; then
            log "Health check OK after switching to backup"
            return 0
        fi

        log "Health check still FAILED after switching to backup"
        return 1
    fi

    log "Active slot is not primary; not switching automatically."
    return 1
}

ensure_cron_files() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch "$CRON_FILE" "$LOG_FILE" "$DETAIL_LOG_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

restart_cron_if_needed() {
    if command -v crond >/dev/null 2>&1 && ! ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then
        if [ -x /opt/etc/init.d/S10cron ]; then
            /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
        elif [ -x /opt/etc/init.d/S10crond ]; then
            /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
        else
            crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        fi
    fi
}

remove_cron() {
    ensure_cron_files
    TMP_FILE="$CRON_FILE.$$"
    grep -v "# $MARKER" "$CRON_FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

enable_cron() {
    SCHEDULE="${1:-$DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_cron
    printf '%s %s check >> %s 2>&1 # %s\n' "$SCHEDULE" "/opt/bin/vless-go-watchdog" "$LOG_FILE" "$MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    restart_cron_if_needed
    echo "Enabled VLESS Go watchdog: $SCHEDULE"
    echo "Cron file: $CRON_FILE"
    echo "Log file: $LOG_FILE"
    echo "Detail log file: $DETAIL_LOG_FILE"
}

disable_cron() {
    remove_cron
    echo "Disabled VLESS Go watchdog."
}

status() {
    ensure_cron_files
    echo "VLESS Go watchdog status:"
    echo "  active: $(active_slot)"
    if [ -s "$PRIMARY_STORE" ]; then echo "  primary: configured"; else echo "  primary: not configured"; fi
    if [ -s "$BACKUP_STORE" ]; then echo "  backup: configured"; else echo "  backup: not configured"; fi
    echo "  SOCKS: $SOCKS_HOST:$SOCKS_PORT"
    echo "  retries: $CHECK_RETRIES"
    echo "  retry delay: ${CHECK_RETRY_DELAY}s"
    echo "  log: $LOG_FILE"
    echo "  detail log: $DETAIL_LOG_FILE"
    if grep "# $MARKER" "$CRON_FILE" >/dev/null 2>&1; then
        echo "  cron: enabled"
        grep "# $MARKER" "$CRON_FILE"
    else
        echo "  cron: disabled"
    fi
    if ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then
        echo "  crond: running"
    else
        echo "  crond: not running or not visible"
    fi
}

case "${1:-check}" in
    check)
        check_and_switch
        ;;
    status)
        status
        ;;
    enable)
        shift
        enable_cron "${1:-}"
        ;;
    disable)
        disable_cron
        ;;
    run-primary)
        switch_to primary
        check_socks && log "Health check OK on primary" || { log "Health check FAILED on primary"; exit 1; }
        ;;
    run-backup)
        switch_to backup
        check_socks && log "Health check OK on backup" || { log "Health check FAILED on backup"; exit 1; }
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "ERROR: unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
