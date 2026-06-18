#!/bin/sh
set -eu

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
LAN_IP_FILE="${LAN_IP_FILE:-$XRAY_DIR/router-lan-ip}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
SOCKS_PORT="${SOCKS_PORT:-10808}"

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ipv4() {
    case "$1" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    is_private_ipv4 "$1"
}

stored_lan_ip() {
    [ -s "$LAN_IP_FILE" ] || return 1
    ip="$(sed -n '1p' "$LAN_IP_FILE" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    valid_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

running_config_lan_ip() {
    command -v ndmc >/dev/null 2>&1 || return 1
    for iface in Bridge0 Home; do
        ip="$(ndmc -c 'show running-config' 2>/dev/null | awk -v ifc="$iface" '
            $1=="interface" {p=($2==ifc); next}
            p && $1=="ip" && $2=="address" {print $3; exit}
        ')"
        valid_ipv4 "$ip" || continue
        printf '%s\n' "$ip"
        return 0
    done
    return 1
}

show_interface_lan_ip() {
    command -v ndmc >/dev/null 2>&1 || return 1
    for iface in Bridge0 Home; do
        ip="$(ndmc -c "show interface $iface" 2>/dev/null | awk '/^[[:space:]]*address:/ {print $2; exit}')"
        valid_ipv4 "$ip" || continue
        printf '%s\n' "$ip"
        return 0
    done
    return 1
}

find_lan_ip() {
    # Auto-detect first. Keenetic LAN should be Bridge0/Home, never GigabitEthernet*/Vlan*/MwsMobile*/UsbLte*.
    running_config_lan_ip && return 0
    show_interface_lan_ip && return 0

    # Fallback only for unusual configs where Bridge0/Home cannot be read.
    stored_lan_ip && return 0

    return 1
}

main() {
    command -v ndmc >/dev/null 2>&1 || { echo "WARN: ndmc not found, skip Proxy0 LAN upstream fix" >&2; exit 0; }

    lan_ip="$(find_lan_ip 2>/dev/null || true)"
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

    echo "Proxy0 LAN upstream fix complete: $lan_ip:$SOCKS_PORT"
}

main "$@"
