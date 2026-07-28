#!/bin/sh
set -eu

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
MANIFEST_FILE="${MANIFEST_FILE:-$XRAY_DIR/xray-go.manifest}"
ACTIVE_STORE="${ACTIVE_STORE:-$XRAY_DIR/vless-go.active}"
WATCHDOG_CONF="${WATCHDOG_CONF:-$XRAY_DIR/vless-go-watchdog.conf}"
XRAY_CONFIG="${XRAY_CONFIG:-$XRAY_DIR/config.json}"
XRAY_INIT="${XRAY_INIT:-/opt/etc/init.d/S24xray}"
WATCHDOG_INIT="${WATCHDOG_INIT:-/opt/etc/init.d/S26vless-go-watchdog}"
CRON_FILE="${CRON_FILE:-/opt/var/spool/cron/crontabs/root}"
SOCKS_AUTH_CONF="${SOCKS_AUTH_CONF:-$XRAY_DIR/vless-go-socks-auth.conf}"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
RECOVERY_CRON_MARKER="${RECOVERY_CRON_MARKER:-vless-go-hourly-recover}"
AUTO_UPDATE_MARKER="${AUTO_UPDATE_MARKER:-vless-go-auto-update}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok() { OK_COUNT=$((OK_COUNT + 1)); printf '[OK] %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
read_first() { [ -s "$1" ] && sed -n '1p' "$1" || true; }

manifest_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

init_status_word() {
    init="$1"
    if [ ! -x "$init" ]; then
        echo "missing"
        return 0
    fi
    if "$init" status >/dev/null 2>&1; then
        echo "alive"
    else
        echo "not-alive"
    fi
}

cron_marker_status() {
    marker="$1"
    if [ -s "$CRON_FILE" ] && grep -q "$marker" "$CRON_FILE" 2>/dev/null; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

socks_listener_status() {
    if has_cmd netstat && netstat -lnt 2>/dev/null | grep -E "(^|[.:])${SOCKS_PORT}[[:space:]]" >/dev/null 2>&1; then
        echo "listening"
        return 0
    fi
    if has_cmd ss && ss -lnt 2>/dev/null | grep -E "(^|[.:])${SOCKS_PORT}[[:space:]]" >/dev/null 2>&1; then
        echo "listening"
        return 0
    fi
    echo "missing"
}

socks_health_status() {
    [ -x /opt/bin/curl ] || has_cmd curl || { echo "unknown-no-curl"; return 0; }

    auth_args=""
    if [ -s "$SOCKS_AUTH_CONF" ]; then
        # shellcheck disable=SC1090
        . "$SOCKS_AUTH_CONF"
        if [ "${XRAY_SOCKS_AUTH:-0}" = "1" ] && [ -n "${XRAY_SOCKS_USER:-}" ] && [ -n "${XRAY_SOCKS_PASS:-}" ]; then
            auth_args="--proxy-user ${XRAY_SOCKS_USER}:${XRAY_SOCKS_PASS}"
        fi
    fi

    # Intentionally do not echo credentials.
    # shellcheck disable=SC2086
    if curl -fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" $auth_args --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$CHECK_URL" >/dev/null 2>&1; then
        echo "OK"
    else
        echo "failed"
    fi
}

proxy0_status() {
    if ! has_cmd ndmc; then
        echo "unknown-no-ndmc"
        return 0
    fi
    if ndmc -c "show interface $PROXY_IFACE" >/dev/null 2>&1; then
        echo "exists"
    else
        echo "missing"
    fi
}

xray_config_status() {
    if [ ! -s "$XRAY_CONFIG" ]; then
        echo "missing"
        return 0
    fi
    xray_bin=""
    if has_cmd xray; then
        xray_bin="$(command -v xray)"
    elif [ -x /opt/sbin/xray ]; then
        xray_bin="/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        xray_bin="/opt/bin/xray"
    fi
    [ -n "$xray_bin" ] || { echo "unknown-no-xray"; return 0; }
    if "$xray_bin" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        echo "valid"
    else
        echo "invalid"
    fi
}

manifest_install_mode="unknown"
manifest_edition="unknown"
manifest_version="unknown"
manifest_arch="unknown"
manifest_modules="unknown"
manifest_binary=""
manifest_sha=""
manifest_sha_status="unknown"

if [ -s "$MANIFEST_FILE" ]; then
    manifest_install_mode="$(manifest_value INSTALL_MODE)"
    manifest_edition="$(manifest_value EDITION)"
    manifest_version="$(manifest_value VERSION)"
    manifest_arch="$(manifest_value ARCH)"
    manifest_modules="$(manifest_value MODULES)"
    manifest_binary="$(manifest_value BINARY_PATH)"
    manifest_sha="$(manifest_value BINARY_SHA256)"
    [ -n "$manifest_install_mode" ] || manifest_install_mode="unknown"
    [ -n "$manifest_edition" ] || manifest_edition="unknown"
    [ -n "$manifest_version" ] || manifest_version="unknown"
    [ -n "$manifest_arch" ] || manifest_arch="unknown"
    [ -n "$manifest_modules" ] || manifest_modules="unknown"

    if [ -n "$manifest_binary" ] && [ -s "$manifest_binary" ] && [ -n "$manifest_sha" ]; then
        actual_sha="$(sha256_file "$manifest_binary")"
        if [ -n "$actual_sha" ] && [ "$actual_sha" = "$manifest_sha" ]; then
            manifest_sha_status="match"
        elif [ -n "$actual_sha" ]; then
            manifest_sha_status="mismatch"
        else
            manifest_sha_status="unknown-no-sha-tool"
        fi
    fi
fi

active_slot="$(read_first "$ACTIVE_STORE")"
[ -n "$active_slot" ] || active_slot="unknown"

xray_init_status="$(init_status_word "$XRAY_INIT")"
watchdog_init_status="$(init_status_word "$WATCHDOG_INIT")"
recovery_cron_status="$(cron_marker_status "$RECOVERY_CRON_MARKER")"
auto_update_status="$(cron_marker_status "$AUTO_UPDATE_MARKER")"
socks_listener="$(socks_listener_status)"
socks_health="$(socks_health_status)"
proxy0="$(proxy0_status)"
xray_config="$(xray_config_status)"

printf '%s\n' "== Summary =="
printf 'Install mode: %s\n' "$manifest_install_mode"
printf 'Edition: %s\n' "$manifest_edition"
printf 'Version: %s\n' "$manifest_version"
printf 'Architecture: %s\n' "$manifest_arch"
printf 'Modules: %s\n' "$manifest_modules"
printf 'Active slot: %s\n' "$active_slot"
printf 'Xray init: %s\n' "$xray_init_status"
printf 'Xray config: %s\n' "$xray_config"
printf 'Proxy0: %s\n' "$proxy0"
printf 'SOCKS listener: %s:%s %s\n' "$SOCKS_HOST" "$SOCKS_PORT" "$socks_listener"
printf 'SOCKS health: %s\n' "$socks_health"
printf 'Watchdog init: %s\n' "$watchdog_init_status"
printf 'Recovery cron: %s\n' "$recovery_cron_status"
printf 'Auto-update cron: %s\n' "$auto_update_status"
printf 'Manifest sha256: %s\n' "$manifest_sha_status"

printf '\n== Checks ==\n'
[ -s "$MANIFEST_FILE" ] && ok "manifest present" || warn "manifest missing"
case "$manifest_install_mode" in direct|opkg) ok "install mode known: $manifest_install_mode" ;; *) warn "install mode unknown" ;; esac
case "$manifest_edition" in full|minimal) ok "edition known: $manifest_edition" ;; *) warn "edition unknown" ;; esac
case "$active_slot" in primary|backup) ok "active slot valid: $active_slot" ;; *) warn "active slot unknown or invalid" ;; esac
[ "$xray_init_status" = "alive" ] && ok "Xray init alive" || warn "Xray init: $xray_init_status"
[ "$xray_config" = "valid" ] && ok "Xray config valid" || warn "Xray config: $xray_config"
[ "$proxy0" = "exists" ] && ok "$PROXY_IFACE exists" || warn "$PROXY_IFACE: $proxy0"
[ "$socks_listener" = "listening" ] && ok "SOCKS listener present" || warn "SOCKS listener: $socks_listener"
[ "$socks_health" = "OK" ] && ok "SOCKS health OK" || warn "SOCKS health: $socks_health"
[ "$watchdog_init_status" = "alive" ] && ok "watchdog init alive" || warn "watchdog init: $watchdog_init_status"
[ "$recovery_cron_status" = "enabled" ] && ok "recovery cron enabled" || warn "recovery cron disabled"
[ "$manifest_sha_status" = "match" ] && ok "manifest binary sha256 match" || warn "manifest binary sha256: $manifest_sha_status"

printf '\n== Result ==\n'
printf 'OK=%s WARN=%s FAIL=%s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -gt 0 ] && exit 2
exit 0
