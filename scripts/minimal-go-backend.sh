#!/bin/sh
set -e

# Named Minimal Go backend entrypoint.
# This is the stable backend target for xray_vless_failover_minimal_go.sh.
# It delegates to the last known-good full Minimal Go backend until the large
# backend is re-vendored directly in main.

PINNED_MINIMAL_GO_REF="${PINNED_MINIMAL_GO_REF:-26b5e7b56932260cd8c7831d1985adcbd9059baa}"
REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
UPSTREAM_URL="${MINIMAL_GO_UPSTREAM_URL:-https://raw.githubusercontent.com/${REPO}/${PINNED_MINIMAL_GO_REF}/xray_vless_failover_minimal_old_go.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/minimal-go-backend.$$"

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

fetch_backend() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$UPSTREAM_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --header='Cache-Control: no-cache' -O "$OUT" "$UPSTREAM_URL" || \
            wget --no-check-certificate --header='Cache-Control: no-cache' -O "$OUT" "$UPSTREAM_URL"
        return $?
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

install_minimal_go_menu() {
    [ -x /opt/bin/minimal-go-status ] || return 0
    [ -x /opt/bin/minimal-go-switch ] || return 0
    mkdir -p /opt/bin

    cat > /opt/bin/minimal-go-menu <<'MENU'
#!/bin/sh

XRAY_DIR="/opt/etc/xray"
PRIMARY_STORE="$XRAY_DIR/minimal-go-primary.url"
BACKUP_STORE="$XRAY_DIR/minimal-go-backup.url"
ACTIVE_STORE="$XRAY_DIR/minimal-go-active"
DAEMON_INIT="/opt/etc/init.d/S25xray-minimal-go-failover"
XRAY_INIT="/opt/etc/init.d/S24xray"
RECOVER_CMD="/opt/bin/vless-go-recover"
HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"
DAEMON_LOG="/opt/var/log/xray-minimal-go-failover.log"

pause() {
    echo
    printf 'Press Enter to continue... '
    IFS= read -r _ans
}

active_slot() {
    sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || echo unknown
}

show_header() {
    clear 2>/dev/null || true
    echo '==============================='
    echo ' Minimal Go / Xray SSH menu'
    echo '==============================='
    echo "Active: $(active_slot)"
    echo "Primary: $([ -s "$PRIMARY_STORE" ] && echo configured || echo missing)"
    echo "Backup : $([ -s "$BACKUP_STORE" ] && echo configured || echo missing)"
    echo
}

valid_source() {
    case "$1" in
        vless://*|http://*|https://*) return 0 ;;
        *) return 1 ;;
    esac
}

save_source() {
    slot="$1"
    case "$slot" in
        primary) store="$PRIMARY_STORE" ;;
        backup) store="$BACKUP_STORE" ;;
        *) echo "Invalid slot: $slot"; return 1 ;;
    esac

    echo
    echo "Paste $slot vless:// link or http(s) subscription URL."
    printf '> '
    IFS= read -r src
    [ -n "$src" ] || { echo 'Source is empty.'; return 1; }
    valid_source "$src" || { echo 'Source must start with vless://, http:// or https://'; return 1; }

    mkdir -p "$XRAY_DIR/source-backups"
    if [ -s "$store" ]; then
        cp "$store" "$XRAY_DIR/source-backups/$(date '+%Y%m%d-%H%M%S').minimal-$slot" 2>/dev/null || true
    fi
    printf '%s\n' "$src" > "$store"
    chmod 600 "$store" 2>/dev/null || true
    echo "Saved $slot source."

    if [ "$(active_slot)" = "$slot" ]; then
        printf 'This slot is active. Apply now? [Y/n]: '
        IFS= read -r ans
        case "$ans" in
            n|N|no|NO|нет|Нет) return 0 ;;
        esac
        /opt/bin/minimal-go-switch "$slot"
    fi
}

show_logs() {
    echo '--- switch history ---'
    tail -n 80 "$HISTORY_LOG" 2>/dev/null || echo 'no history log'
    echo
    echo '--- daemon log ---'
    tail -n 80 "$DAEMON_LOG" 2>/dev/null || echo 'no daemon log'
}

recovery_menu() {
    while true; do
        show_header
        echo 'Recovery / Proxy0'
        echo '1) Recovery status'
        echo '2) Run recovery now'
        echo '3) Refresh Proxy0'
        echo '4) Enable hourly recovery'
        echo '5) Disable hourly recovery'
        echo '0) Back'
        echo
        printf 'Select: '
        IFS= read -r r
        case "$r" in
            1) [ -x "$RECOVER_CMD" ] && "$RECOVER_CMD" --mode minimal status || echo 'vless-go-recover not found'; pause ;;
            2) [ -x "$RECOVER_CMD" ] && "$RECOVER_CMD" --mode minimal run || echo 'vless-go-recover not found'; pause ;;
            3) [ -x "$RECOVER_CMD" ] && "$RECOVER_CMD" --mode minimal proxy0 || echo 'vless-go-recover not found'; pause ;;
            4) [ -x "$RECOVER_CMD" ] && "$RECOVER_CMD" --mode minimal enable-hourly || echo 'vless-go-recover not found'; pause ;;
            5) [ -x "$RECOVER_CMD" ] && "$RECOVER_CMD" --mode minimal disable-hourly || echo 'vless-go-recover not found'; pause ;;
            0) return 0 ;;
        esac
    done
}

service_menu() {
    while true; do
        show_header
        echo 'Services'
        echo '1) Xray status'
        echo '2) Restart Xray'
        echo '3) Minimal daemon status'
        echo '4) Restart Minimal daemon'
        echo '0) Back'
        echo
        printf 'Select: '
        IFS= read -r s
        case "$s" in
            1) [ -x "$XRAY_INIT" ] && "$XRAY_INIT" status || echo 'Xray init not found'; pause ;;
            2) [ -x "$XRAY_INIT" ] && "$XRAY_INIT" restart || echo 'Xray init not found'; pause ;;
            3) [ -x "$DAEMON_INIT" ] && "$DAEMON_INIT" status || echo 'Minimal daemon init not found'; pause ;;
            4) [ -x "$DAEMON_INIT" ] && "$DAEMON_INIT" restart || echo 'Minimal daemon init not found'; pause ;;
            0) return 0 ;;
        esac
    done
}

while true; do
    show_header
    echo '1) Status'
    echo '2) Switch to primary'
    echo '3) Switch to backup'
    echo '4) Set primary source'
    echo '5) Set backup source'
    echo '6) Recovery / Proxy0'
    echo '7) Services'
    echo '8) Logs'
    echo '0) Exit'
    echo
    printf 'Select: '
    IFS= read -r choice
    case "$choice" in
        1) /opt/bin/minimal-go-status 2>&1; pause ;;
        2) /opt/bin/minimal-go-switch primary 2>&1; pause ;;
        3) /opt/bin/minimal-go-switch backup 2>&1; pause ;;
        4) save_source primary 2>&1; pause ;;
        5) save_source backup 2>&1; pause ;;
        6) recovery_menu ;;
        7) service_menu ;;
        8) show_logs; pause ;;
        0|q|Q|exit) exit 0 ;;
    esac
done
MENU
    chmod +x /opt/bin/minimal-go-menu
    echo "Minimal Go SSH menu installed: /opt/bin/minimal-go-menu"
}

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
        *) return 1 ;;
    esac
}

find_router_lan_ip() {
    # Prefer Keenetic LAN/Home interfaces, not the default route source address.
    if command -v ndmc >/dev/null 2>&1; then
        for iface in Home Bridge0 br0; do
            ip="$(ndmc -c "show interface $iface" 2>/dev/null | awk '/^[[:space:]]*address:/ {print $2; exit}')"
            if is_private_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    fi

    if [ -s /opt/etc/xray/router-lan-ip ]; then
        ip="$(sed -n '1p' /opt/etc/xray/router-lan-ip 2>/dev/null | tr -d '\r')"
        if is_private_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi

    if command -v ip >/dev/null 2>&1; then
        ip="$(ip -4 addr show scope global 2>/dev/null | awk '
            /inet / {
                ip=$2
                sub(/\/.*/, "", ip)
                if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                    print ip
                    exit
                }
            }')"
        if is_private_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi

    return 1
}

install_proxy0_lan_upstream_fix() {
    command -v ndmc >/dev/null 2>&1 || return 0
    lan_ip="$(find_router_lan_ip 2>/dev/null || true)"
    [ -n "$lan_ip" ] || { echo "WARN: could not detect LAN/Home IP for Proxy0 upstream" >&2; return 0; }

    mkdir -p /opt/etc/xray 2>/dev/null || true
    printf '%s\n' "$lan_ip" > /opt/etc/xray/router-lan-ip 2>/dev/null || true

    if ndmc -c "interface Proxy0 proxy upstream $lan_ip 10808" \
        && ndmc -c "interface Proxy0 down" \
        && sleep 2 \
        && ndmc -c "interface Proxy0 up" \
        && ndmc -c "system configuration save"
    then
        echo "Proxy0 upstream fixed to LAN/Home IP: $lan_ip:10808"
    else
        echo "WARN: failed to set Proxy0 upstream to $lan_ip:10808" >&2
    fi
}

echo "Downloading Minimal Go backend..."
fetch_backend || { echo "ERROR: failed to download Minimal Go backend: $UPSTREAM_URL" >&2; exit 1; }

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal Go backend does not look like a shell script: $UPSTREAM_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal Go backend failed shell syntax check: $UPSTREAM_URL" >&2
    exit 1
fi

chmod +x "$OUT"
set +e
sh "$OUT" "$@"
RC="$?"
set -e

if [ "$RC" -eq 0 ]; then
    install_minimal_go_menu || true
    install_proxy0_lan_upstream_fix || true
fi

exit "$RC"
