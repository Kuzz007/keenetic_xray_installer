#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_SELECTOR="$XRAY_DIR/vless-go.primary.selector"
BACKUP_SELECTOR="$XRAY_DIR/vless-go.backup.selector"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
XRAY_BACKUP_DIR="$XRAY_DIR/backups"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_DETAIL_LOG="/opt/var/log/vless-go-watchdog-detail.log"
AUTO_UPDATE_LOG="/opt/var/log/vless-go-auto-update.log"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
VERBOSE="0"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose|-v)
            VERBOSE="1"
            shift
            ;;
        -h|--help|help)
            echo "Usage: vless-go-doctor [--verbose]"
            echo ""
            echo "Default mode avoids printing verbose detail logs that can contain profile/server metadata."
            echo "Use --verbose only for local debugging."
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Usage: vless-go-doctor [--verbose]" >&2
            exit 2
            ;;
    esac
done

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok() {
    OK_COUNT=$((OK_COUNT + 1))
    printf '[OK] %s\n' "$*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf '[WARN] %s\n' "$*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$*"
}

info() {
    printf '[INFO] %s\n' "$*"
}

section() {
    printf '\n== %s ==\n' "$*"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

read_first() {
    [ -s "$1" ] && sed -n '1p' "$1" || true
}

mask_source_type() {
    VALUE="$1"
    case "$VALUE" in
        vless://*) echo "vless link" ;;
        http://*|https://*) echo "subscription URL" ;;
        '') echo "empty" ;;
        *) echo "custom source" ;;
    esac
}

check_file_present() {
    FILE="$1"
    LABEL="$2"
    if [ -s "$FILE" ]; then
        ok "$LABEL configured ($(mask_source_type "$(read_first "$FILE")"))"
    else
        warn "$LABEL not configured"
    fi
}

valid_selector() {
    VALUE="$1"
    case "$VALUE" in
        first) return 0 ;;
        index:[1-9]*[!0-9]*) return 1 ;;
        index:[1-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

check_selector() {
    FILE="$1"
    LABEL="$2"
    VALUE="$(read_first "$FILE")"
    if [ -z "$VALUE" ]; then
        warn "$LABEL selector missing: $FILE"
        return 0
    fi
    if valid_selector "$VALUE"; then
        ok "$LABEL selector: $VALUE"
    else
        fail "$LABEL selector invalid: $VALUE"
    fi
}

xray_bin() {
    if has_cmd xray; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo /opt/sbin/xray
    elif [ -x /opt/bin/xray ]; then
        echo /opt/bin/xray
    else
        echo ""
    fi
}

check_init_status() {
    INIT="$1"
    LABEL="$2"
    if [ ! -x "$INIT" ]; then
        warn "$LABEL init script not found: $INIT"
        return 0
    fi

    if "$INIT" status >/tmp/vless-go-doctor.status.$$ 2>&1; then
        ok "$LABEL init status: alive"
    else
        warn "$LABEL init status is not alive"
        sed 's/^/  /' /tmp/vless-go-doctor.status.$$
    fi
    rm -f /tmp/vless-go-doctor.status.$$ 2>/dev/null || true
}

check_socks_listener() {
    if has_cmd netstat; then
        if netstat -lnt 2>/dev/null | grep -E "(^|[.:])$SOCKS_PORT[[:space:]]" >/dev/null 2>&1; then
            ok "SOCKS listener found on port $SOCKS_PORT"
            return 0
        fi
    fi

    if has_cmd ss; then
        if ss -lnt 2>/dev/null | grep -E "(^|[.:])$SOCKS_PORT[[:space:]]" >/dev/null 2>&1; then
            ok "SOCKS listener found on port $SOCKS_PORT"
            return 0
        fi
    fi

    warn "SOCKS listener not detected on port $SOCKS_PORT"
}

check_socks_health() {
    if ! has_cmd curl; then
        warn "curl not found; cannot check SOCKS health"
        return 0
    fi

    if curl -fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        "$CHECK_URL" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then
        ok "SOCKS health-check OK via $CHECK_URL"
    else
        warn "SOCKS health-check failed via $CHECK_URL"
        sed 's/^/  /' /tmp/vless-go-doctor.curl.$$
    fi
    rm -f /tmp/vless-go-doctor.curl.$$ 2>/dev/null || true
}

show_watchdog_summary() {
    if has_cmd vless-go-watchdog; then
        vless-go-watchdog status 2>/dev/null | sed 's/^/  /'
    else
        warn "vless-go-watchdog command not found"
    fi
}

show_tail_safe() {
    FILE="$1"
    LABEL="$2"
    if [ -s "$FILE" ]; then
        echo "-- $LABEL --"
        tail -n 20 "$FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "-- $LABEL: empty or missing --"
    fi
}

check_cron_auto_update() {
    if [ ! -s "$CRON_FILE" ]; then
        ok "cron file empty or missing; auto-update disabled"
        return 0
    fi

    LINES="$(grep 'vless-go-auto-update' "$CRON_FILE" 2>/dev/null || true)"
    if [ -z "$LINES" ]; then
        ok "auto-update cron entry not installed"
        return 0
    fi

    if echo "$LINES" | grep -- '--first' >/dev/null 2>&1; then
        warn "auto-update cron still contains legacy --first"
        echo "$LINES" | sed 's/^/  /'
        return 0
    fi

    if echo "$LINES" | grep '/opt/bin/vless-go-auto-update run' >/dev/null 2>&1; then
        ok "auto-update cron uses selector-aware runner"
        echo "$LINES" | sed 's/^/  /'
    else
        warn "auto-update cron entry found, but runner format is unexpected"
        echo "$LINES" | sed 's/^/  /'
    fi
}

check_backups() {
    if [ ! -d "$XRAY_BACKUP_DIR" ]; then
        warn "Xray backup directory missing: $XRAY_BACKUP_DIR"
        return 0
    fi

    COUNT="$(find "$XRAY_BACKUP_DIR" -type f -name 'xray.*.bak' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${COUNT:-0}" -gt 0 ]; then
        ok "Xray backup binaries found: $COUNT"
        find "$XRAY_BACKUP_DIR" -type f -name 'xray.*.bak' 2>/dev/null | tail -n 3 | sed 's/^/  /'
    else
        warn "no Xray backup binaries found in $XRAY_BACKUP_DIR"
    fi
}

section "Commands"
for CMD in opkg curl xray vless-go-update vless-go-failover vless-go-watchdog vless-go-auto-update vless-go-xray-core-update xray-go-installer-update failover-go; do
    if has_cmd "$CMD"; then
        ok "$CMD found: $(command -v "$CMD")"
    else
        fail "$CMD not found"
    fi
done

section "Updater dependencies"
for CMD in python3 unzip; do
    if has_cmd "$CMD"; then
        ok "$CMD found: $(command -v "$CMD")"
    else
        warn "$CMD not found; vless-go-xray-core-update can install it via opkg when needed"
    fi
done

if has_cmd vless-go-xray-core-update; then
    if vless-go-xray-core-update --help >/tmp/vless-go-doctor.corehelp.$$ 2>&1; then
        ok "Xray-core updater help works"
    else
        warn "Xray-core updater help returned non-zero"
        sed 's/^/  /' /tmp/vless-go-doctor.corehelp.$$
    fi
    rm -f /tmp/vless-go-doctor.corehelp.$$ 2>/dev/null || true
fi

section "Saved state"
check_file_present "$SOURCE_STORE" "current source"
check_file_present "$PRIMARY_STORE" "primary source"
check_file_present "$BACKUP_STORE" "backup source"
ACTIVE="$(read_first "$ACTIVE_STORE")"
case "$ACTIVE" in
    primary|backup) ok "active slot: $ACTIVE" ;;
    '') warn "active slot is not set" ;;
    *) fail "active slot invalid: $ACTIVE" ;;
esac
check_selector "$PRIMARY_SELECTOR" "primary"
check_selector "$BACKUP_SELECTOR" "backup"
[ -s "$WATCHDOG_CONF" ] && ok "watchdog config present: $WATCHDOG_CONF" || warn "watchdog config missing: $WATCHDOG_CONF"

section "Xray"
XRAY_BIN="$(xray_bin)"
if [ -n "$XRAY_BIN" ]; then
    ok "xray binary: $XRAY_BIN"
    XRAY_VERSION="$($XRAY_BIN version 2>/dev/null | sed -n '1p')"
    [ -n "$XRAY_VERSION" ] && ok "Xray version: $XRAY_VERSION" || warn "failed to read Xray version"
    if [ -s "$XRAY_CONFIG" ]; then
        ok "Xray config present: $XRAY_CONFIG"
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/tmp/vless-go-doctor.xray.$$ 2>&1; then
            ok "Xray config validation OK"
        else
            fail "Xray config validation failed"
            sed 's/^/  /' /tmp/vless-go-doctor.xray.$$
        fi
        rm -f /tmp/vless-go-doctor.xray.$$ 2>/dev/null || true
    else
        fail "Xray config missing: $XRAY_CONFIG"
    fi
else
    fail "xray binary not found"
fi
check_backups
check_init_status "$XRAY_INIT" "Xray"
check_socks_listener
check_socks_health

section "Auto-update"
if has_cmd vless-go-auto-update; then
    vless-go-auto-update status 2>/dev/null | sed 's/^/  /'
fi
check_cron_auto_update
[ -s "$AUTO_UPDATE_LOG" ] && show_tail_safe "$AUTO_UPDATE_LOG" "auto-update log" || info "auto-update log empty or missing: $AUTO_UPDATE_LOG"

section "Watchdog"
check_init_status "$WATCHDOG_INIT" "VLESS Go watchdog"
show_watchdog_summary

section "Logs"
show_tail_safe "$WATCHDOG_LOG" "watchdog main log"
if [ "$VERBOSE" = "1" ]; then
    echo "-- watchdog detail log --"
    echo "  WARNING: verbose detail log may contain profile/server metadata."
    show_tail_safe "$WATCHDOG_DETAIL_LOG" "watchdog detail log"
else
    echo "-- watchdog detail log skipped --"
    echo "  Use: vless-go-doctor --verbose"
fi

section "Summary"
printf 'OK=%s WARN=%s FAIL=%s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 2
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
