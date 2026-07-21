#!/bin/sh
# Shared LAN IP detection for the Proxy0 upstream.
#
# Sourced by every helper that writes "interface Proxy0 proxy upstream".
# Each writer used to carry its own detection: they disagreed on interface
# priority (Bridge0 first vs Home first), on whether a 10.x LAN is valid, and
# two of them fell back to 127.0.0.1 when detection failed. Because the
# watchdog re-applies Proxy0 on a timer, that fallback quietly replaced a
# working LAN upstream with a loopback address and the proxy stopped passing
# traffic until someone re-ran an installer.
#
# Contract for detect_router_lan_ip:
#   success -> prints exactly one private IPv4 address, returns 0
#   failure -> prints nothing, returns 1
# It never invents a loopback address. Callers MUST leave the existing
# upstream untouched when it returns 1.

# Keenetic LAN lives on Bridge0/Home. Never probe GigabitEthernet*/Vlan*/
# MwsMobile*/UsbLte* - on 4G those carry a private CGNAT WAN address that
# looks local but routes to the carrier.
VLESS_GO_LAN_INTERFACES="${VLESS_GO_LAN_INTERFACES:-Bridge0 Home br0}"

vless_go_lan_ip_is_private() {
    case "$1" in
        10.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        *) return 1 ;;
    esac
}

# Rejects empties, CIDR suffixes, netmasks glued on by sloppy parsing, and
# anything that is not four in-range octets.
vless_go_lan_ip_valid() {
    case "${1:-}" in
        ''|*/*|*[!0-9.]*) return 1 ;;
    esac
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i == "" || $i + 0 > 255) exit 1 }
    ' || return 1
    vless_go_lan_ip_is_private "$1"
}

vless_go_lan_ip_from_running_config() {
    command -v ndmc >/dev/null 2>&1 || return 1
    ndmc -c 'show running-config' 2>/dev/null | awk -v want="$1" '
        $1 == "interface" { inblock = ($2 == want); next }
        inblock && $1 == "ip" && $2 == "address" { print $3; exit }
    '
}

vless_go_lan_ip_from_show_interface() {
    command -v ndmc >/dev/null 2>&1 || return 1
    ndmc -c "show interface $1" 2>/dev/null | awk '/^[[:space:]]*address:/ { print $2; exit }'
}

vless_go_lan_ip_from_ip_command() {
    command -v ip >/dev/null 2>&1 || return 1
    ip -4 addr show dev "$1" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
}

detect_router_lan_ip() {
    # An explicit operator override wins outright, including a deliberate
    # loopback for unusual setups.
    if [ -n "${PROXY_UPSTREAM_HOST:-}" ]; then
        printf '%s\n' "$PROXY_UPSTREAM_HOST"
        return 0
    fi

    for _lan_iface in $VLESS_GO_LAN_INTERFACES; do
        for _lan_reader in \
            vless_go_lan_ip_from_running_config \
            vless_go_lan_ip_from_show_interface \
            vless_go_lan_ip_from_ip_command
        do
            _lan_candidate="$("$_lan_reader" "$_lan_iface" 2>/dev/null || true)"
            if vless_go_lan_ip_valid "$_lan_candidate"; then
                printf '%s\n' "$_lan_candidate"
                return 0
            fi
        done
    done

    # The stored value is only as good as the run that wrote it, so it is a
    # last resort rather than a shortcut.
    _lan_store="${ROUTER_IP_STORE:-/opt/etc/xray/router-lan-ip}"
    if [ -s "$_lan_store" ]; then
        _lan_candidate="$(sed -n '1p' "$_lan_store" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        if vless_go_lan_ip_valid "$_lan_candidate"; then
            printf '%s\n' "$_lan_candidate"
            return 0
        fi
    fi

    return 1
}

# Reads back what the firmware actually stored, so a write can be verified
# instead of assumed.
proxy0_current_upstream() {
    command -v ndmc >/dev/null 2>&1 || return 1
    ndmc -c 'show running-config' 2>/dev/null | awk -v want="${1:-Proxy0}" '
        $1 == "interface" { inblock = ($2 == want); next }
        inblock && $1 == "proxy" && $2 == "upstream" { print $3; exit }
    '
}
