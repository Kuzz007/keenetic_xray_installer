#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_DETAIL_LOG="/opt/var/log/vless-go-watchdog-detail.log"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"

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

xray_bin() {
    if has_cmd xray; then
        command -v xray
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
        if netstat -lnt 2>/dev/null | grep -E '(^|[.:])10808[[:space:]]' >/dev/null 2>&1; then
            ok "SOCKS listener found on port $SOCKS_PORT"
            return 0
        fi
    fi

    if has_cmd ss; then
        if ss -lnt 2>/dev/null | grep -E '(^|[.:])10808[[:space:]]' >/dev/null 2>&1; then
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

section "Commands"
for CMD in opkg curl xray vless-go-update vless-go-failover vless-go-watchdog xray-go-installer-update; do
    if has_cmd "$CMD"; then
        ok "$CMD found: $(command -v "$CMD")"
    else
        fail "$CMD not found"
    fi
done

section "Saved state"
check_file_present "$SOURCE_STORE" "current source"
check_file_present "$PRIMARY_STORE" "primary source"
check_file_present "$BACKUP_STORE" "backup source"
ACTIVE="$(read_first "$ACTIVE_STORE")"
if [ -n "$ACTIVE" ]; then
    ok "active slot: $ACTIVE"
else
    warn "active slot is not set"
fi
[ -s "$WATCHDOG_CONF" ] && ok "watchdog config present: $WATCHDOG_CONF" || warn "watchdog config missing: $WATCHDOG_CONF"

section "Xray"
XRAY_BIN="$(xray_bin)"
if [ -n "$XRAY_BIN" ]; then
    ok "xray binary: $XRAY_BIN"
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
check_init_status "$XRAY_INIT" "Xray"
check_socks_listener
check_socks_health

section "Watchdog"
check_init_status "$WATCHDOG_INIT" "VLESS Go watchdog"
show_watchdog_summary

section "Logs"
show_tail_safe "$WATCHDOG_LOG" "watchdog main log"
show_tail_safe "$WATCHDOG_DETAIL_LOG" "watchdog detail log"

section "Summary"
printf 'OK=%s WARN=%s FAIL=%s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 2
fi

if [ "$WARN_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
