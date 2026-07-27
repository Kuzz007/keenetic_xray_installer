#!/bin/sh
set -e

# Xray VLESS Failover Go/Entware public entrypoint.
# Installs/updates the Entware feed package, then performs first-run setup by
# asking for primary/backup VLESS or subscription URLs. No embedded gzip/base64.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
PLAIN_URL="${GO_PLAIN_URL:-${REPO_BASE}/scripts/install-entware-feed.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/xray_vless_failover_go.feed.$$"
XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"

DO_SETUP="1"
NO_RESTART="0"
FORCE_SETUP="0"
ASSUME_YES="0"
FEED_ARGS=""

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_go.sh [options]

Default mode:
  Install/update Go/Entware edition, ask for primary and optionally backup VLESS/subscription URLs,
  apply primary profile, start watchdog and enable hourly recovery.

Options:
  --no-setup             Install/update package only; do not ask for links
  --repair-only          Alias for --no-setup, intended for update/repair paths
  --update-only          Alias for --no-setup, intended for update/repair paths
  --force-setup          Ask for links even if primary and backup are already configured
  --no-restart           Do not restart/switch Xray while applying primary
  -y, --yes              Use defaults for yes/no prompts where possible
  -h, --help             Show help

Environment overrides:
  PRIMARY_URL            Primary VLESS link or subscription URL
  BACKUP_URL             Optional backup VLESS link or subscription URL
  PRIMARY_SELECTOR       Primary selector: first, index:N, or N
  BACKUP_SELECTOR        Backup selector: first, index:N, or N
  GO_PLAIN_URL           Feed bootstrap URL override
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-setup|--repair-only|--update-only) DO_SETUP="0"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        --force-setup) FORCE_SETUP="1"; shift ;;
        --no-restart) NO_RESTART="1"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        -y|--yes) ASSUME_YES="1"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) FEED_ARGS="$FEED_ARGS $1"; shift ;;
    esac
done

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

read_tty() {
    prompt="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
}

fetch_plain() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$PLAIN_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        # No unverified-TLS retry here: the download is executed right away, so a
        # skipped certificate check means running whatever the network returns.
        wget --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL" || {
            echo "ERROR: download over verified TLS failed: $PLAIN_URL" >&2
            echo "Hint: opkg update && opkg install curl ca-certificates" >&2
            return 1
        }
        return 0
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

need_exec() {
    if [ ! -x "$1" ]; then
        echo "ERROR: required command not found or not executable: $1" >&2
        exit 1
    fi
}

normalize_selector() {
    value="$1"
    case "$value" in
        ''|first) echo first ;;
        index:[1-9]*[!0-9]*) return 1 ;;
        index:[1-9]*) echo "$value" ;;
        [1-9]*[!0-9]*) return 1 ;;
        [1-9]*) echo "index:$value" ;;
        *) return 1 ;;
    esac
}

show_profiles_hint() {
    slot="$1"
    source_value="$2"
    [ -n "$source_value" ] || return 0
    case "$source_value" in
        http://*|https://*)
            echo
            echo "Subscription profile listing is not available in this installer build."
            echo "For $slot selector use 'first' or a profile number, e.g. 1 = index:1."
            echo
            ;;
    esac
}

prompt_source() {
    slot="$1"
    env_value="$2"
    required="${3:-1}"
    if [ -n "$env_value" ]; then
        printf '%s' "$env_value"
        return 0
    fi

    while true; do
        if [ "$required" = "1" ]; then
            read_tty "Enter $slot VLESS link or subscription URL: "
        else
            read_tty "Enter $slot VLESS link or subscription URL [empty = skip]: "
        fi
        if [ -n "$REPLY" ]; then
            printf '%s' "$REPLY"
            return 0
        fi
        if [ "$required" != "1" ]; then
            printf '%s' ""
            return 0
        fi
        echo "ERROR: $slot URL cannot be empty." >&2
    done
}

prompt_selector() {
    slot="$1"
    source_value="$2"
    env_value="$3"
    default="first"

    show_profiles_hint "$slot" "$source_value" >&2

    if [ -n "$env_value" ]; then
        normalize_selector "$env_value"
        return $?
    fi

    while true; do
        echo "Selector for $slot supports: first, index:N, or just N. Default: $default" >&2
        read_tty "Enter $slot selector [$default]: "
        value="$REPLY"
        [ -n "$value" ] || value="$default"
        if selector="$(normalize_selector "$value")"; then
            printf '%s' "$selector"
            return 0
        fi
        echo "ERROR: invalid selector: $value" >&2
    done
}

already_configured() {
    [ -s "$XRAY_DIR/vless-go.primary" ] && [ -s "$XRAY_DIR/vless-go.backup" ]
}

ensure_xray_backup_dir() {
    mkdir -p "$XRAY_DIR/backups"
    chmod 700 "$XRAY_DIR/backups" 2>/dev/null || true
}

normalize_watchdog_auto_recover() {
    [ -s "$WATCHDOG_CONF" ] || return 0
    if grep -q '^AUTO_RECOVER_PRIMARY=' "$WATCHDOG_CONF" 2>/dev/null; then
        sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY="1"/' "$WATCHDOG_CONF" 2>/dev/null || true
    else
        printf '%s\n' 'AUTO_RECOVER_PRIMARY="1"' >> "$WATCHDOG_CONF"
    fi
    chmod 600 "$WATCHDOG_CONF" 2>/dev/null || true
}

ensure_watchdog_conf() {
    mkdir -p "$XRAY_DIR"
    if [ -s "$WATCHDOG_CONF" ]; then
        normalize_watchdog_auto_recover
        return 0
    fi

    cat > "$WATCHDOG_CONF" <<'EOF_CONF'
SOCKS_HOST="127.0.0.1"
SOCKS_PORT="10808"
CHECK_URLS="http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204"
CHECK_RETRIES="2"
CHECK_RETRY_DELAY="2"
WATCHDOG_INTERVAL="15"
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
AUTO_RECOVER_PRIMARY="1"
RECOVERY_TEST_PORT="18080"
RECOVERY_COOLDOWN_CYCLES="2"
POST_SWITCH_DELAY="5"
PROXY0_REFRESH="1"
PROXY_IFACE="Proxy0"
EOF_CONF
    chmod 600 "$WATCHDOG_CONF" 2>/dev/null || true
    echo "Default VLESS Go watchdog config created: $WATCHDOG_CONF"
}

restart_watchdog_if_present() {
    [ -x "$WATCHDOG_INIT" ] || return 0
    if "$WATCHDOG_INIT" restart >/dev/null 2>&1 || "$WATCHDOG_INIT" start >/dev/null 2>&1; then
        echo "VLESS Go watchdog restarted to apply script/config updates"
    else
        echo "WARN: failed to restart VLESS Go watchdog: $WATCHDOG_INIT" >&2
    fi
}

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
        *) return 1 ;;
    esac
}

find_router_lan_ip() {
    # Prefer Keenetic LAN/Home interfaces. Do not use default-route source; on 4G it can be CGNAT WAN.
    if command -v ndmc >/dev/null 2>&1; then
        for iface in Home Bridge0 br0; do
            ip="$(ndmc -c "show interface $iface" 2>/dev/null | awk '/^[[:space:]]*address:/ {print $2; exit}')"
            if is_private_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    fi

    if command -v ip >/dev/null 2>&1; then
        for iface in Home Bridge0 br0; do
            ip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')"
            if is_private_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    fi

    if [ -s "$XRAY_DIR/router-lan-ip" ]; then
        ip="$(sed -n '1p' "$XRAY_DIR/router-lan-ip" 2>/dev/null | tr -d '\r')"
        if is_private_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi

    return 1
}

ensure_proxy0_lan_upstream() {
    command -v ndmc >/dev/null 2>&1 || return 0
    lan_ip="$(find_router_lan_ip 2>/dev/null || true)"
    [ -n "$lan_ip" ] || { echo "WARN: could not detect LAN/Home IP for Proxy0 upstream" >&2; return 0; }

    mkdir -p "$XRAY_DIR" 2>/dev/null || true
    printf '%s\n' "$lan_ip" > "$XRAY_DIR/router-lan-ip" 2>/dev/null || true

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

ensure_xray_init() {
    [ -s "$XRAY_CONFIG" ] || return 0
    if [ -x "$XRAY_INIT" ]; then
        return 0
    fi

    mkdir -p /opt/etc/init.d
    cat > "$XRAY_INIT" <<EOF_INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
EOF_INIT
    chmod 755 "$XRAY_INIT"
    echo "Xray init installed: $XRAY_INIT"
}

ensure_xray_ready() {
    ensure_xray_init
    [ -x "$XRAY_INIT" ] || return 0
    if "$XRAY_INIT" status >/dev/null 2>&1; then
        return 0
    fi
    "$XRAY_INIT" start >/dev/null 2>&1 || "$XRAY_INIT" restart >/dev/null 2>&1 || true
    sleep 2
}

run_feed_install() {
    mkdir -p "$TMP_DIR"
    echo "Downloading Go/Entware feed installer..."
    fetch_plain || { echo "ERROR: failed to download Go/Entware feed installer: $PLAIN_URL" >&2; exit 1; }

    if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
        echo "ERROR: downloaded Go/Entware feed installer does not look like a shell script: $PLAIN_URL" >&2
        head -n 3 "$OUT" >&2 || true
        exit 1
    fi

    if ! sh -n "$OUT"; then
        echo "ERROR: downloaded Go/Entware feed installer failed shell syntax check: $PLAIN_URL" >&2
        exit 1
    fi

    chmod +x "$OUT"
    sh "$OUT" $FEED_ARGS
}

print_final_summary() {
    echo
    echo "Final non-interactive status summary:"
    echo

    if [ -x /opt/bin/vless-go-failover ]; then
        /opt/bin/vless-go-failover status || true
    else
        echo "WARN: /opt/bin/vless-go-failover not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-watchdog ]; then
        /opt/bin/vless-go-watchdog status || true
    else
        echo "WARN: /opt/bin/vless-go-watchdog not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-recover ]; then
        /opt/bin/vless-go-recover --mode full status || true
    else
        echo "WARN: /opt/bin/vless-go-recover not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-doctor ]; then
        /opt/bin/vless-go-doctor || true
    else
        echo "WARN: /opt/bin/vless-go-doctor not found"
    fi
}

run_first_setup() {
    if [ "$FORCE_SETUP" != "1" ] && already_configured; then
        echo "Existing primary and backup profiles detected; skipping first-run setup."
        echo "Use --force-setup to replace them, or run failover-go for menu management."
        ensure_watchdog_conf
        restart_watchdog_if_present
        return 0
    fi

    need_exec /opt/bin/vless-go-failover
    need_exec /opt/bin/vless-go-watchdog
    need_exec /opt/bin/vless-go-recover
    need_exec /opt/bin/vless-go-doctor

    echo
    echo "Go/Entware first-run setup"
    echo "Private links are stored under /opt/etc/xray and are not printed back."
    echo

    primary_value="$(prompt_source primary "${PRIMARY_URL:-}" 1)"
    primary_selector="$(prompt_selector primary "$primary_value" "${PRIMARY_SELECTOR:-}")" || { echo "ERROR: invalid primary selector" >&2; exit 1; }

    backup_value="$(prompt_source backup "${BACKUP_URL:-}" 0)"
    if [ -n "$backup_value" ]; then
        backup_selector="$(prompt_selector backup "$backup_value" "${BACKUP_SELECTOR:-}")" || { echo "ERROR: invalid backup selector" >&2; exit 1; }
    else
        backup_selector=""
        echo "Backup profile skipped. You can add it later with: failover-go set-backup URL --selector first"
    fi

    echo
    echo "Saving primary profile..."
    /opt/bin/vless-go-failover set-primary "$primary_value" --selector "$primary_selector"

    if [ -n "$backup_value" ]; then
        echo "Saving backup profile..."
        /opt/bin/vless-go-failover set-backup "$backup_value" --selector "$backup_selector"
    fi

    echo "Applying primary profile..."
    if [ "$NO_RESTART" = "1" ]; then
        /opt/bin/vless-go-failover switch primary --no-restart
    else
        /opt/bin/vless-go-failover switch primary
    fi

    ensure_xray_backup_dir
    ensure_watchdog_conf
    ensure_xray_ready
    ensure_proxy0_lan_upstream

    echo "Starting watchdog..."
    restart_watchdog_if_present

    echo "Enabling hourly recovery..."
    /opt/bin/vless-go-recover --mode full enable-hourly || true

    ensure_xray_ready

    echo
    echo "Installation and first-run setup complete."
    print_final_summary
    echo
    echo "Use 'failover-go' later to open the management menu."
}

run_feed_install

if [ "$DO_SETUP" = "1" ]; then
    run_first_setup
else
    ensure_watchdog_conf
    ensure_proxy0_lan_upstream
    restart_watchdog_if_present
    echo "Setup skipped. Use 'failover-go' for menu management or rerun with --force-setup."
fi
