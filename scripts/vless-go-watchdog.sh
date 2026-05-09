#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_RESOLVER="/opt/bin/xray-failover-go"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-https://www.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
CHECK_RETRIES="${CHECK_RETRIES:-2}"
CHECK_RETRY_DELAY="${CHECK_RETRY_DELAY:-2}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-15}"
FAILOVER_FAILURES_REQUIRED="${FAILOVER_FAILURES_REQUIRED:-2}"
RECOVERY_SUCCESSES_REQUIRED="${RECOVERY_SUCCESSES_REQUIRED:-2}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-0}"
RECOVERY_TEST_PORT="${RECOVERY_TEST_PORT:-18080}"
RECOVERY_COOLDOWN_CYCLES="${RECOVERY_COOLDOWN_CYCLES:-2}"
LOG_FILE="${LOG_FILE:-/opt/var/log/vless-go-watchdog.log}"
DETAIL_LOG_FILE="${DETAIL_LOG_FILE:-/opt/var/log/vless-go-watchdog-detail.log}"
PID_FILE="${PID_FILE:-/opt/var/run/vless-go-watchdog.pid}"
MARKER="vless-go-watchdog"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
DEFAULT_SCHEDULE="*/5 * * * *"

usage() {
    echo "Usage: vless-go-watchdog check | daemon | status | enable [CRON_SCHEDULE] | disable | run-primary | run-backup | probe-primary"
    echo ""
    echo "Commands:"
    echo "  daemon         Run continuous watchdog loop. Default interval: 15s."
    echo "  check          Single check. If it fails on primary, switch to backup."
    echo "  status         Show active slot, daemon, cron, and health-check settings."
    echo "  enable         Add legacy cron entry. Default schedule: */5 * * * *"
    echo "  disable        Remove legacy cron entry."
    echo "  run-primary    Manually switch to primary and test."
    echo "  run-backup     Manually switch to backup and test."
    echo "  probe-primary  Test saved primary through a temporary local Xray instance."
    echo ""
    echo "Environment:"
    echo "  CHECK_URL=$CHECK_URL"
    echo "  SOCKS_HOST=$SOCKS_HOST"
    echo "  SOCKS_PORT=$SOCKS_PORT"
    echo "  CONNECT_TIMEOUT=$CONNECT_TIMEOUT"
    echo "  MAX_TIME=$MAX_TIME"
    echo "  CHECK_RETRIES=$CHECK_RETRIES"
    echo "  CHECK_RETRY_DELAY=$CHECK_RETRY_DELAY"
    echo "  WATCHDOG_INTERVAL=$WATCHDOG_INTERVAL"
    echo "  FAILOVER_FAILURES_REQUIRED=$FAILOVER_FAILURES_REQUIRED"
    echo "  RECOVERY_SUCCESSES_REQUIRED=$RECOVERY_SUCCESSES_REQUIRED"
    echo "  AUTO_RECOVER_PRIMARY=$AUTO_RECOVER_PRIMARY"
    echo "  RECOVERY_TEST_PORT=$RECOVERY_TEST_PORT"
    echo "  RECOVERY_COOLDOWN_CYCLES=$RECOVERY_COOLDOWN_CYCLES"
    echo "  LOG_FILE=$LOG_FILE"
    echo "  DETAIL_LOG_FILE=$DETAIL_LOG_FILE"
    echo "  PID_FILE=$PID_FILE"
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

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

ensure_failover_cmd() {
    if [ ! -x "$FAILOVER_CMD" ]; then
        log "ERROR: failover command not found: $FAILOVER_CMD"
        exit 1
    fi
}

check_socks_target_once() {
    TARGET_HOST="$1"
    TARGET_PORT="$2"
    TMP_OUT="/tmp/vless-go-watchdog.check.$$"
    TMP_ERR="/tmp/vless-go-watchdog.err.$$"

    set +e
    curl -fsS \
        --socks5-hostname "$TARGET_HOST:$TARGET_PORT" \
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

check_socks_target() {
    TARGET_HOST="$1"
    TARGET_PORT="$2"
    ATTEMPT="1"
    while [ "$ATTEMPT" -le "$CHECK_RETRIES" ]; do
        if check_socks_target_once "$TARGET_HOST" "$TARGET_PORT"; then
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

check_socks() {
    check_socks_target "$SOCKS_HOST" "$SOCKS_PORT"
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

probe_primary() {
    if [ ! -s "$PRIMARY_STORE" ]; then
        log "Primary source is not configured; cannot probe primary."
        return 1
    fi

    if [ ! -x "$GO_RESOLVER" ]; then
        log "Go resolver/generator not found: $GO_RESOLVER"
        return 1
    fi

    XRAY_BIN="$(get_xray_bin)"
    if [ -z "$XRAY_BIN" ]; then
        log "Xray binary not found; cannot probe primary."
        return 1
    fi

    PRIMARY_VALUE="$(sed -n '1p' "$PRIMARY_STORE")"
    TMP_CONFIG="/opt/tmp/vless-go-recovery-primary.$$.$RANDOM.json"
    TMP_RESOLVER_LOG="/tmp/vless-go-recovery-resolver.$$"
    TMP_XRAY_LOG="/tmp/vless-go-recovery-xray.$$"
    TEST_PID=""

    mkdir -p /opt/tmp /opt/var/log

    cleanup_probe() {
        if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
            kill "$TEST_PID" 2>/dev/null || true
            sleep 1
            kill -9 "$TEST_PID" 2>/dev/null || true
        fi
        rm -f "$TMP_CONFIG" "$TMP_RESOLVER_LOG" "$TMP_XRAY_LOG" 2>/dev/null || true
    }

    set +e
    "$GO_RESOLVER" \
        -input "$PRIMARY_VALUE" \
        -output "$TMP_CONFIG" \
        -listen "127.0.0.1" \
        -port "$RECOVERY_TEST_PORT" \
        -profile "vless-recovery-test" \
        -first >"$TMP_RESOLVER_LOG" 2>&1
    RC="$?"
    set -e

    cat "$TMP_RESOLVER_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    if [ "$RC" -ne 0 ]; then
        log "Primary recovery probe config generation failed; see detail log."
        cleanup_probe
        return 1
    fi

    set +e
    "$XRAY_BIN" run -test -config "$TMP_CONFIG" >> "$DETAIL_LOG_FILE" 2>&1
    RC="$?"
    set -e
    if [ "$RC" -ne 0 ]; then
        log "Primary recovery probe config validation failed; see detail log."
        cleanup_probe
        return 1
    fi

    "$XRAY_BIN" run -config "$TMP_CONFIG" >"$TMP_XRAY_LOG" 2>&1 &
    TEST_PID="$!"
    sleep 2

    if ! kill -0 "$TEST_PID" 2>/dev/null; then
        cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
        log "Primary recovery probe Xray did not start; see detail log."
        cleanup_probe
        return 1
    fi

    if check_socks_target "127.0.0.1" "$RECOVERY_TEST_PORT"; then
        cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
        cleanup_probe
        return 0
    fi

    cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    cleanup_probe
    return 1
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

handle_daemon_primary() {
    DAEMON_RECOVERY_SUCCESS_COUNT="0"
    DAEMON_RECOVERY_COOLDOWN="0"

    if check_socks; then
        DAEMON_FAIL_COUNT="0"
        log "Daemon health OK on primary"
        return 0
    fi

    DAEMON_FAIL_COUNT="$((DAEMON_FAIL_COUNT + 1))"
    log "Daemon health FAIL on primary: $DAEMON_FAIL_COUNT/$FAILOVER_FAILURES_REQUIRED"

    if [ "$DAEMON_FAIL_COUNT" -ge "$FAILOVER_FAILURES_REQUIRED" ]; then
        if [ -s "$BACKUP_STORE" ]; then
            log "Failover threshold reached; switching primary -> backup"
            if switch_to backup && check_socks; then
                log "Daemon failover to backup OK"
                DAEMON_RECOVERY_COOLDOWN="$RECOVERY_COOLDOWN_CYCLES"
            else
                log "Daemon failover to backup did not pass health check"
            fi
        else
            log "Backup is not configured; cannot fail over."
        fi
        DAEMON_FAIL_COUNT="0"
    fi
}

handle_daemon_backup() {
    if check_socks; then
        DAEMON_BACKUP_FAIL_COUNT="0"
        log "Daemon health OK on backup"
    else
        DAEMON_BACKUP_FAIL_COUNT="$((DAEMON_BACKUP_FAIL_COUNT + 1))"
        log "Daemon health FAIL on backup: $DAEMON_BACKUP_FAIL_COUNT/$FAILOVER_FAILURES_REQUIRED"
    fi

    if [ "$AUTO_RECOVER_PRIMARY" != "1" ]; then
        return 0
    fi

    if [ "$DAEMON_RECOVERY_COOLDOWN" -gt 0 ]; then
        log "Primary recovery probe cooldown: $DAEMON_RECOVERY_COOLDOWN cycles remaining"
        DAEMON_RECOVERY_COOLDOWN="$((DAEMON_RECOVERY_COOLDOWN - 1))"
        return 0
    fi

    log "Probing primary recovery on temporary SOCKS port $RECOVERY_TEST_PORT"
    if probe_primary; then
        DAEMON_RECOVERY_SUCCESS_COUNT="$((DAEMON_RECOVERY_SUCCESS_COUNT + 1))"
        log "Primary recovery probe OK: $DAEMON_RECOVERY_SUCCESS_COUNT/$RECOVERY_SUCCESSES_REQUIRED"
    else
        DAEMON_RECOVERY_SUCCESS_COUNT="0"
        log "Primary recovery probe FAILED"
        return 0
    fi

    if [ "$DAEMON_RECOVERY_SUCCESS_COUNT" -ge "$RECOVERY_SUCCESSES_REQUIRED" ]; then
        log "Recovery threshold reached; switching backup -> primary"
        if switch_to primary && check_socks; then
            log "Daemon recovery to primary OK"
        else
            log "Daemon recovery to primary did not pass health check"
        fi
        DAEMON_RECOVERY_SUCCESS_COUNT="0"
        DAEMON_RECOVERY_COOLDOWN="$RECOVERY_COOLDOWN_CYCLES"
    fi
}

run_daemon() {
    mkdir -p "$(dirname "$PID_FILE")" /opt/var/log
    echo "$$" > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; log "Daemon stopped"; exit 0' INT TERM

    DAEMON_FAIL_COUNT="0"
    DAEMON_BACKUP_FAIL_COUNT="0"
    DAEMON_RECOVERY_SUCCESS_COUNT="0"
    DAEMON_RECOVERY_COOLDOWN="0"

    log "Daemon started: interval=${WATCHDOG_INTERVAL}s failover_failures_required=$FAILOVER_FAILURES_REQUIRED check_retries=$CHECK_RETRIES auto_recover_primary=$AUTO_RECOVER_PRIMARY"

    while true; do
        SLOT="$(active_slot)"
        case "$SLOT" in
            primary)
                handle_daemon_primary
                ;;
            backup)
                handle_daemon_backup
                ;;
            *)
                log "Daemon active slot is unknown: $SLOT"
                ;;
        esac
        sleep "$WATCHDOG_INTERVAL"
    done
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
    echo "Enabled VLESS Go watchdog cron: $SCHEDULE"
    echo "Cron file: $CRON_FILE"
    echo "Log file: $LOG_FILE"
    echo "Detail log file: $DETAIL_LOG_FILE"
    echo "Note: daemon mode is preferred for 15-second checks."
}

disable_cron() {
    remove_cron
    echo "Disabled VLESS Go watchdog cron."
}

daemon_status_line() {
    if [ -s "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "running pid=$PID"
            return 0
        fi
    fi
    echo "not running"
}

status() {
    ensure_cron_files
    echo "VLESS Go watchdog status:"
    echo "  active: $(active_slot)"
    if [ -s "$PRIMARY_STORE" ]; then echo "  primary: configured"; else echo "  primary: not configured"; fi
    if [ -s "$BACKUP_STORE" ]; then echo "  backup: configured"; else echo "  backup: not configured"; fi
    echo "  SOCKS: $SOCKS_HOST:$SOCKS_PORT"
    echo "  check URL: $CHECK_URL"
    echo "  check retries: $CHECK_RETRIES"
    echo "  check retry delay: ${CHECK_RETRY_DELAY}s"
    echo "  daemon interval: ${WATCHDOG_INTERVAL}s"
    echo "  failover failures required: $FAILOVER_FAILURES_REQUIRED"
    echo "  recovery successes required: $RECOVERY_SUCCESSES_REQUIRED"
    echo "  auto recover primary: $AUTO_RECOVER_PRIMARY"
    echo "  recovery test port: $RECOVERY_TEST_PORT"
    echo "  recovery cooldown cycles: $RECOVERY_COOLDOWN_CYCLES"
    echo "  daemon: $(daemon_status_line)"
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
    daemon)
        run_daemon
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
    probe-primary)
        probe_primary && log "Primary recovery probe OK" || { log "Primary recovery probe FAILED"; exit 1; }
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
