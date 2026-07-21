#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
AUTH_CONF="$XRAY_DIR/vless-go-socks-auth.conf"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
LAN_IP_LIB="${LAN_IP_LIB:-/opt/libexec/vless-go-lan-ip.sh}"

[ -s "$WATCHDOG_CONF" ] && . "$WATCHDOG_CONF" 2>/dev/null || true
# Shared LAN detection. When it is missing we refuse to guess an upstream
# rather than fall back to loopback, which used to break Proxy0 silently.
[ -r "$LAN_IP_LIB" ] && . "$LAN_IP_LIB" 2>/dev/null || true
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"

usage() {
    cat <<'USAGE'
Usage: vless-go-socks-auth COMMAND [args]

Commands:
  status                         Show SOCKS auth state without printing password
  enable USER PASS [--skip-proxy0]
                                 Enable Xray SOCKS username/password auth and reapply active config
  disable                        Disable Xray SOCKS auth and reapply active config
  apply-proxy0                   Re-apply Proxy0 with saved credentials when supported by firmware

Credential characters are intentionally restricted to: A-Z a-z 0-9 . _ @ : -
Use a generated/unique password and keep Web UI LAN-only.
USAGE
}

valid_credential() {
    value="$1"
    case "$value" in
        ''|*[!A-Za-z0-9._@:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

load_auth() {
    XRAY_SOCKS_AUTH="0"
    XRAY_SOCKS_USER=""
    XRAY_SOCKS_PASS=""
    if [ -s "$AUTH_CONF" ]; then
        . "$AUTH_CONF"
    fi
    XRAY_SOCKS_AUTH="${XRAY_SOCKS_AUTH:-0}"
    XRAY_SOCKS_USER="${XRAY_SOCKS_USER:-}"
    XRAY_SOCKS_PASS="${XRAY_SOCKS_PASS:-}"
    case "$XRAY_SOCKS_AUTH" in 1|yes|true|on) XRAY_SOCKS_AUTH="1" ;; *) XRAY_SOCKS_AUTH="0" ;; esac
}

save_auth() {
    enabled="$1"
    user="$2"
    pass="$3"
    mkdir -p "$XRAY_DIR"
    tmp="$AUTH_CONF.$$"
    {
        printf 'XRAY_SOCKS_AUTH="%s"\n' "$enabled"
        printf 'XRAY_SOCKS_USER="%s"\n' "$user"
        printf 'XRAY_SOCKS_PASS="%s"\n' "$pass"
    } > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$AUTH_CONF"
}

proxy_upstream_host() {
    command -v detect_router_lan_ip >/dev/null 2>&1 || return 1
    detect_router_lan_ip
}

apply_proxy0() {
    load_auth
    command -v ndmc >/dev/null 2>&1 || { echo "WARN: ndmc not found; Proxy0 auth not applied." >&2; return 1; }

    # The watchdog calls this on a timer. Writing a guessed upstream here is
    # what used to overwrite a working LAN address with 127.0.0.1, so when the
    # LAN IP is unknown we leave the interface exactly as it is.
    upstream_host="$(proxy_upstream_host 2>/dev/null || true)"
    if [ -z "$upstream_host" ]; then
        echo "WARN: router LAN IP unknown; leaving the current $PROXY_IFACE upstream untouched." >&2
        echo "Hint: check Bridge0/Home, or set PROXY_UPSTREAM_HOST=192.168.X.1 in $WATCHDOG_CONF" >&2
        return 1
    fi

    ndmc -c "interface $PROXY_IFACE" >/dev/null 2>&1 || return 1
    ndmc -c "interface $PROXY_IFACE proxy protocol socks5" >/dev/null 2>&1 || return 1
    ndmc -c "interface $PROXY_IFACE proxy socks5-udp" >/dev/null 2>&1 || true

    if [ "$XRAY_SOCKS_AUTH" = "1" ]; then
        if ndmc -c "interface $PROXY_IFACE proxy upstream $upstream_host $SOCKS_PORT $XRAY_SOCKS_USER $XRAY_SOCKS_PASS" >/dev/null 2>&1; then
            :
        else
            echo "WARN: firmware did not accept 'proxy upstream HOST PORT USER PASS'." >&2
            echo "WARN: Proxy0 credentials may need manual configuration in Keenetic UI/CLI." >&2
            return 1
        fi
    else
        ndmc -c "interface $PROXY_IFACE proxy upstream $upstream_host $SOCKS_PORT" >/dev/null 2>&1 || return 1
    fi

    ndmc -c "interface $PROXY_IFACE description Xray-Go-Experimental" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE no ip global" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE up" >/dev/null 2>&1 || true
    ndmc -c "system configuration save" >/dev/null 2>&1 || true

    # Remember a known-good value, and verify the firmware actually took it
    # instead of reporting success blindly.
    printf '%s\n' "$upstream_host" > "$ROUTER_IP_STORE" 2>/dev/null || true
    if command -v proxy0_current_upstream >/dev/null 2>&1; then
        applied="$(proxy0_current_upstream "$PROXY_IFACE" 2>/dev/null || true)"
        if [ -n "$applied" ] && [ "$applied" != "$upstream_host" ]; then
            echo "WARN: $PROXY_IFACE upstream reads back as $applied, expected $upstream_host" >&2
        fi
    fi

    echo "$PROXY_IFACE -> SOCKS5 $upstream_host:$SOCKS_PORT"
    [ "$XRAY_SOCKS_AUTH" = "1" ] && echo "Proxy0 SOCKS credentials: configured/sent to firmware" || echo "Proxy0 SOCKS credentials: disabled"
}

reapply_active_config() {
    if [ -x "$GO_FAILOVER_CMD" ]; then
        "$GO_FAILOVER_CMD" update-active
    else
        echo "WARN: $GO_FAILOVER_CMD not found; reapply active config manually." >&2
    fi
}

restore_conf() {
    backup="$1"
    if [ -s "$backup" ]; then
        mv "$backup" "$AUTH_CONF"
    else
        rm -f "$AUTH_CONF" 2>/dev/null || true
    fi
}

status() {
    load_auth
    echo "SOCKS auth config: $AUTH_CONF"
    if [ "$XRAY_SOCKS_AUTH" = "1" ]; then
        echo "SOCKS auth: enabled"
        echo "SOCKS user: $XRAY_SOCKS_USER"
        echo "SOCKS pass: <hidden>"
        echo "curl test: curl --proxy-user '$XRAY_SOCKS_USER:<password>' --socks5-hostname 127.0.0.1:$SOCKS_PORT https://www.gstatic.com/generate_204"
    else
        echo "SOCKS auth: disabled"
    fi
}

case "${1:-status}" in
    status)
        status
        ;;
    enable)
        [ "$#" -ge 3 ] || { echo "ERROR: enable requires USER PASS" >&2; usage >&2; exit 2; }
        user="$2"
        pass="$3"
        shift 3
        skip_proxy0="0"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --skip-proxy0) skip_proxy0="1"; shift ;;
                *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
            esac
        done
        valid_credential "$user" || { echo "ERROR: invalid username. Allowed: A-Z a-z 0-9 . _ @ : -" >&2; exit 1; }
        valid_credential "$pass" || { echo "ERROR: invalid password. Allowed: A-Z a-z 0-9 . _ @ : -" >&2; exit 1; }

        mkdir -p "$XRAY_DIR"
        backup="$AUTH_CONF.bak.$$"
        [ -s "$AUTH_CONF" ] && cp "$AUTH_CONF" "$backup" || rm -f "$backup"
        save_auth 1 "$user" "$pass"

        if [ "$skip_proxy0" != "1" ]; then
            if ! apply_proxy0; then
                restore_conf "$backup"
                echo "ERROR: Proxy0 auth apply failed; SOCKS auth was not enabled." >&2
                echo "Use --skip-proxy0 only if you will configure Proxy0 credentials manually." >&2
                exit 1
            fi
        fi

        if ! reapply_active_config; then
            restore_conf "$backup"
            reapply_active_config >/dev/null 2>&1 || true
            echo "ERROR: failed to reapply active config with SOCKS auth; restored previous auth config." >&2
            exit 1
        fi
        rm -f "$backup" 2>/dev/null || true
        echo "SOCKS auth enabled."
        ;;
    disable)
        backup="$AUTH_CONF.bak.$$"
        [ -s "$AUTH_CONF" ] && cp "$AUTH_CONF" "$backup" || rm -f "$backup"
        save_auth 0 "" ""
        apply_proxy0 || true
        if ! reapply_active_config; then
            restore_conf "$backup"
            reapply_active_config >/dev/null 2>&1 || true
            echo "ERROR: failed to reapply active config after disabling SOCKS auth; restored previous auth config." >&2
            exit 1
        fi
        rm -f "$backup" 2>/dev/null || true
        echo "SOCKS auth disabled."
        ;;
    apply-proxy0)
        apply_proxy0
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "ERROR: unknown command: $1" >&2
        usage >&2
        exit 2
        ;;
esac
