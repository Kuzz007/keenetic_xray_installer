#!/bin/sh
set -eu

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
LAN_IP_FILE="${LAN_IP_FILE:-$XRAY_DIR/router-lan-ip}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
SOCKS_PORT="${SOCKS_PORT:-10808}"

LAN_IP_LIB="${LAN_IP_LIB:-/opt/libexec/vless-go-lan-ip.sh}"
ROUTER_IP_STORE="$LAN_IP_FILE"
export ROUTER_IP_STORE

if [ -r "$LAN_IP_LIB" ]; then
    . "$LAN_IP_LIB"
else
    echo "ERROR: shared LAN detection not found: $LAN_IP_LIB" >&2
    echo "Hint: reinstall or update helpers so the library is deployed." >&2
    exit 1
fi

main() {
    command -v ndmc >/dev/null 2>&1 || { echo "WARN: ndmc not found, skip Proxy0 LAN upstream fix" >&2; exit 0; }

    lan_ip="$(detect_router_lan_ip 2>/dev/null || true)"
    if [ -z "$lan_ip" ]; then
        echo "WARN: could not detect LAN IP for $PROXY_IFACE upstream" >&2
        echo "Hint: check Bridge0/Home LAN address or echo 192.168.X.1 > $LAN_IP_FILE and rerun this helper" >&2
        exit 0
    fi

    mkdir -p "$XRAY_DIR" 2>/dev/null || true
    printf '%s\n' "$lan_ip" > "$LAN_IP_FILE" 2>/dev/null || true

    echo "Setting $PROXY_IFACE upstream to LAN IP: $lan_ip:$SOCKS_PORT"
    ndmc -c "interface $PROXY_IFACE proxy upstream $lan_ip $SOCKS_PORT"
    ndmc -c "interface $PROXY_IFACE down" || true
    sleep 2
    ndmc -c "interface $PROXY_IFACE up"
    ndmc -c "system configuration save"

    applied="$(proxy0_current_upstream "$PROXY_IFACE" 2>/dev/null || true)"
    if [ -n "$applied" ] && [ "$applied" != "$lan_ip" ]; then
        echo "ERROR: $PROXY_IFACE upstream reads back as $applied, expected $lan_ip" >&2
        exit 1
    fi

    echo "Proxy0 LAN upstream fix complete: $lan_ip:$SOCKS_PORT"
}

main "$@"
