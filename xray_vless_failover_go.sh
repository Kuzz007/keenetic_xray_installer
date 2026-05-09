#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
PROXY_IFACE="Proxy0"
PROXY_UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
TMP_DIR="/opt/tmp"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/latest/download/xray-failover-go-linux-arm64}"

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

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

ensure_cron() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log 2>/dev/null || true
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true

    if ! command -v crond >/dev/null 2>&1; then
        echo "Installing cron for optional auto-update..."
        opkg install cron >/dev/null 2>&1 \
            || opkg install cronie >/dev/null 2>&1 \
            || opkg install busybox-cron >/dev/null 2>&1 \
            || echo "WARNING: cron could not be installed. vless-go-auto-update enable may need manual cron setup."
    fi

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

ensure_packages() {
    echo "[1/9] Checking Entware packages..."
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is required." >&2
        exit 1
    fi

    NEED_UPDATE="0"
    command -v curl >/dev/null 2>&1 || NEED_UPDATE="1"
    command -v crond >/dev/null 2>&1 || NEED_UPDATE="1"
    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        NEED_UPDATE="1"
    fi

    [ "$NEED_UPDATE" = "0" ] || opkg update

    if ! command -v curl >/dev/null 2>&1; then
        opkg install curl ca-bundle
    else
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        opkg install xray-core || opkg install xray
    fi

    ensure_cron
}

install_go_resolver() {
    echo "[2/9] Installing experimental Go resolver/generator..."
    mkdir -p "$(dirname "$GO_RESOLVER")" "$TMP_DIR"

    if [ -x "$GO_RESOLVER" ]; then
        echo "Existing binary found: $GO_RESOLVER"
        return 0
    fi

    if ! curl -fL -o "$GO_RESOLVER" "$GO_BINARY_URL"; then
        echo "ERROR: failed to download Go binary: $GO_BINARY_URL" >&2
        echo "Create a GitHub release with xray-failover-go-linux-arm64 or build it locally with scripts/build-go-installers.sh and copy it to $GO_RESOLVER" >&2
        exit 1
    fi

    chmod +x "$GO_RESOLVER"
}

create_xray_init() {
    echo "[7/9] Creating Xray init script..."
    cat > "$INIT_SCRIPT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
INIT
    chmod +x "$INIT_SCRIPT"
}

create_update_command() {
    echo "[4/9] Creating vless-go-update command..."
    mkdir -p "$(dirname "$GO_UPDATE_CMD")" "$XRAY_DIR" "$TMP_DIR"

    cat > "$GO_UPDATE_CMD" <<'UPDATE'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
TMP_DIR="/opt/tmp"

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

usage() {
    echo "Usage: vless-go-update [--source URL_OR_VLESS] [--first] [--no-restart]"
    echo ""
    echo "Options:"
    echo "  --source VALUE   Replace saved VLESS/subscription source before updating."
    echo "  --first          Select first profile without interactive prompt."
    echo "  --no-restart     Generate and validate config, but do not restart Xray."
}

FIRST="0"
NO_RESTART="0"
NEW_SOURCE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { echo "ERROR: --source requires value" >&2; exit 1; }
            NEW_SOURCE="$2"
            shift 2
            ;;
        --first)
            FIRST="1"
            shift
            ;;
        --no-restart)
            NO_RESTART="1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

mkdir -p "$XRAY_DIR" "$TMP_DIR"

if [ -n "$NEW_SOURCE" ]; then
    printf '%s\n' "$NEW_SOURCE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
fi

if [ ! -s "$SOURCE_STORE" ]; then
    echo "ERROR: source is not saved. Re-run xray_vless_failover_go.sh or use: vless-go-update --source URL_OR_VLESS" >&2
    exit 1
fi

if [ ! -x "$GO_RESOLVER" ]; then
    echo "ERROR: Go resolver/generator not found: $GO_RESOLVER" >&2
    exit 1
fi

SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE")"
TMP_CONFIG="$TMP_DIR/config.vless-go-update.$$.$RANDOM.json"
trap 'rm -f "$TMP_CONFIG" 2>/dev/null || true' EXIT INT TERM

ARGS=""
[ "$FIRST" = "0" ] || ARGS="-first"

# shellcheck disable=SC2086
"$GO_RESOLVER" \
    -input "$SOURCE_VALUE" \
    -output "$TMP_CONFIG" \
    -listen "$SOCKS_LISTEN" \
    -port "$SOCKS_PORT" \
    -profile "vless-out" \
    $ARGS

XRAY_BIN="$(get_xray_bin)"
if [ -z "$XRAY_BIN" ]; then
    echo "ERROR: xray binary not found." >&2
    exit 1
fi

if ! "$XRAY_BIN" run -test -config "$TMP_CONFIG" >/dev/null 2>&1; then
    "$XRAY_BIN" test -config "$TMP_CONFIG"
fi

cp "$TMP_CONFIG" "$XRAY_CONFIG"
chmod 600 "$XRAY_CONFIG" 2>/dev/null || true

if [ "$NO_RESTART" = "1" ]; then
    echo "Updated and validated config: $XRAY_CONFIG"
    echo "Xray restart skipped."
    exit 0
fi

if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" restart || "$INIT_SCRIPT" start
else
    echo "WARNING: init script not found: $INIT_SCRIPT" >&2
    echo "Config updated, restart Xray manually." >&2
fi

echo "Updated VLESS config from saved source."
UPDATE

    chmod +x "$GO_UPDATE_CMD"
}

create_auto_update_command() {
    echo "[5/9] Creating vless-go-auto-update command..."
    mkdir -p "$(dirname "$GO_AUTO_UPDATE_CMD")" /opt/var/spool/cron/crontabs /opt/var/log

    cat > "$GO_AUTO_UPDATE_CMD" <<'AUTO'
#!/bin/sh
set -e

GO_UPDATE_CMD="/opt/bin/vless-go-update"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
LOG_FILE="/opt/var/log/vless-go-auto-update.log"
MARKER="vless-go-auto-update"
DEFAULT_SCHEDULE="17 4 * * *"

usage() {
    echo "Usage: vless-go-auto-update enable [CRON_SCHEDULE] | disable | status | run"
}

ensure_cron_files() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch "$CRON_FILE" "$LOG_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

restart_cron() {
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

remove_existing() {
    ensure_cron_files
    TMP_FILE="$CRON_FILE.$$"
    grep -v "# $MARKER" "$CRON_FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

enable_auto() {
    SCHEDULE="${1:-$DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_existing
    printf '%s %s --first >> %s 2>&1 # %s\n' "$SCHEDULE" "$GO_UPDATE_CMD" "$LOG_FILE" "$MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    restart_cron
    echo "Enabled VLESS Go auto-update: $SCHEDULE"
    echo "Cron file: $CRON_FILE"
    echo "Log file: $LOG_FILE"
}

disable_auto() {
    remove_existing
    echo "Disabled VLESS Go auto-update."
}

status_auto() {
    ensure_cron_files
    if grep "# $MARKER" "$CRON_FILE" >/dev/null 2>&1; then
        echo "VLESS Go auto-update is enabled:"
        grep "# $MARKER" "$CRON_FILE"
    else
        echo "VLESS Go auto-update is disabled."
    fi

    if ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then
        echo "crond: running"
    else
        echo "crond: not running or not visible"
    fi
}

run_now() {
    [ -x "$GO_UPDATE_CMD" ] || { echo "ERROR: update command not found: $GO_UPDATE_CMD" >&2; exit 1; }
    "$GO_UPDATE_CMD" --first
}

case "${1:-status}" in
    enable) shift; enable_auto "${1:-}" ;;
    disable) disable_auto ;;
    status) status_auto ;;
    run) run_now ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
AUTO

    chmod +x "$GO_AUTO_UPDATE_CMD"
}

create_failover_command() {
    echo "[6/9] Creating vless-go-failover command..."
    mkdir -p "$(dirname "$GO_FAILOVER_CMD")" "$XRAY_DIR"

    cat > "$GO_FAILOVER_CMD" <<'FAILOVER'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_UPDATE_CMD="/opt/bin/vless-go-update"

usage() {
    echo "Usage: vless-go-failover COMMAND [ARGS]"
    echo "Commands: status | set-primary SRC | set-backup SRC | switch primary|backup [--first] [--no-restart] | update-active [--first] [--no-restart] | sync-primary"
}

slot_file() {
    case "$1" in
        primary) echo "$PRIMARY_STORE" ;;
        backup) echo "$BACKUP_STORE" ;;
        *) return 1 ;;
    esac
}

slot_source() {
    FILE="$(slot_file "$1")" || return 1
    [ -s "$FILE" ] || return 2
    sed -n '1p' "$FILE"
}

save_source() {
    SLOT="$1"
    VALUE="$2"
    FILE="$(slot_file "$SLOT")" || { echo "ERROR: invalid slot: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Saved $SLOT source: $FILE"
}

parse_update_flags() {
    FIRST="0"
    NO_RESTART="0"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --first) FIRST="1"; shift ;;
            --no-restart) NO_RESTART="1"; shift ;;
            *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
}

run_update() {
    SOURCE_VALUE="$1"
    SLOT="$2"
    shift 2
    parse_update_flags "$@"

    [ -x "$GO_UPDATE_CMD" ] || { echo "ERROR: update command not found: $GO_UPDATE_CMD" >&2; exit 1; }

    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$SOURCE_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
    printf '%s\n' "$SLOT" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true

    ARGS="--source $SOURCE_VALUE"
    [ "$FIRST" = "0" ] || ARGS="$ARGS --first"
    [ "$NO_RESTART" = "0" ] || ARGS="$ARGS --no-restart"

    # shellcheck disable=SC2086
    "$GO_UPDATE_CMD" $ARGS
    echo "Active VLESS slot: $SLOT"
}

status() {
    echo "Failover-lite status:"
    [ -s "$ACTIVE_STORE" ] && echo "  active: $(sed -n '1p' "$ACTIVE_STORE")" || echo "  active: unknown"
    [ -s "$PRIMARY_STORE" ] && echo "  primary: configured" || echo "  primary: not configured"
    [ -s "$BACKUP_STORE" ] && echo "  backup: configured" || echo "  backup: not configured"
    [ -s "$SOURCE_STORE" ] && echo "  current source: configured" || echo "  current source: not configured"
}

case "${1:-status}" in
    status) status ;;
    set-primary) shift; [ "$#" -ge 1 ] || { echo "ERROR: set-primary requires source" >&2; exit 1; }; save_source primary "$1" ;;
    set-backup) shift; [ "$#" -ge 1 ] || { echo "ERROR: set-backup requires source" >&2; exit 1; }; save_source backup "$1" ;;
    switch) shift; [ "$#" -ge 1 ] || { echo "ERROR: switch requires primary or backup" >&2; exit 1; }; SLOT="$1"; shift; SOURCE_VALUE="$(slot_source "$SLOT")" || { echo "ERROR: $SLOT source is not configured" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    update-active) shift; if [ -s "$ACTIVE_STORE" ]; then SLOT="$(sed -n '1p' "$ACTIVE_STORE")"; SOURCE_VALUE="$(slot_source "$SLOT" 2>/dev/null || true)"; else SLOT="current"; SOURCE_VALUE=""; fi; [ -n "$SOURCE_VALUE" ] || SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE" 2>/dev/null || true)"; [ -n "$SOURCE_VALUE" ] || { echo "ERROR: no active source found" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    sync-primary) [ -s "$SOURCE_STORE" ] || { echo "ERROR: current source is not configured" >&2; exit 1; }; save_source primary "$(sed -n '1p' "$SOURCE_STORE")"; printf '%s\n' primary > "$ACTIVE_STORE"; chmod 600 "$ACTIVE_STORE" 2>/dev/null || true ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
FAILOVER

    chmod +x "$GO_FAILOVER_CMD"
}

valid_auto_lan_ip() {
    awk 'NF && ($1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print; exit }'
}

detect_lan_router_ip() {
    if [ -n "$PROXY_UPSTREAM_HOST" ]; then
        echo "$PROXY_UPSTREAM_HOST"
        return 0
    fi

    # Prefer explicit Keenetic Home/bridge interfaces, but never auto-pick 10.x.
    {
        ndmc -c "show interface Home" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        ndmc -c "show interface Bridge0" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        for dev in Home home Bridge0 bridge0 br0 br-lan lan0 lan1; do
            ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / { gsub(/\/.*/, "", $2); print $2 }'
        done
        ip -4 route show scope link 2>/dev/null | awk '/ src / { for (i=1; i<=NF; i++) if ($i == "src") print $(i+1) }'
    } | valid_auto_lan_ip
}

configure_proxy0() {
    echo "[8/9] Configuring Proxy0..."
    if ! command -v ndmc >/dev/null 2>&1; then
        echo "WARNING: ndmc not found. Configure Proxy0 manually to SOCKS5 $SOCKS_LISTEN:$SOCKS_PORT."
        return 0
    fi

    ROUTER_IP="$(detect_lan_router_ip | awk 'NF { print; exit }')"
    ROUTER_IP="${ROUTER_IP:-127.0.0.1}"

    ndmc -c "interface $PROXY_IFACE" || true
    ndmc -c "interface $PROXY_IFACE proxy protocol socks5" || true
    ndmc -c "interface $PROXY_IFACE proxy socks5-udp" || true
    ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_IP $SOCKS_PORT" || true
    ndmc -c "interface $PROXY_IFACE description Xray-Go-Experimental" || true
    ndmc -c "interface $PROXY_IFACE no ip global" || true
    ndmc -c "interface $PROXY_IFACE up" || true
    ndmc -c "system configuration save" || true

    echo "$PROXY_IFACE -> SOCKS5 $ROUTER_IP:$SOCKS_PORT"
}

start_xray() {
    echo "[9/9] Testing and starting Xray..."
    XRAY_BIN="$(get_xray_bin)"
    if [ -z "$XRAY_BIN" ]; then
        echo "ERROR: xray binary not found." >&2
        exit 1
    fi

    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        "$XRAY_BIN" test -config "$XRAY_CONFIG"
    fi

    "$INIT_SCRIPT" restart || "$INIT_SCRIPT" start
}

main() {
    echo "Experimental Xray VLESS Go installer for Keenetic"
    echo "This does not replace the full failover installer."
    echo

    ensure_packages
    install_go_resolver

    mkdir -p "$XRAY_DIR"
    read_tty "Enter primary VLESS link or subscription URL: "
    INPUT_VALUE="$REPLY"
    if [ -z "$INPUT_VALUE" ]; then
        echo "ERROR: empty primary input." >&2
        exit 1
    fi

    printf '%s\n' "$INPUT_VALUE" > "$SOURCE_STORE"
    printf '%s\n' "$INPUT_VALUE" > "$PRIMARY_STORE"
    printf '%s\n' primary > "$ACTIVE_STORE"
    chmod 600 "$SOURCE_STORE" "$PRIMARY_STORE" "$ACTIVE_STORE" 2>/dev/null || true

    read_tty "Enter backup VLESS link or subscription URL (optional, press Enter to skip): "
    BACKUP_VALUE="$REPLY"
    if [ -n "$BACKUP_VALUE" ]; then
        printf '%s\n' "$BACKUP_VALUE" > "$BACKUP_STORE"
        chmod 600 "$BACKUP_STORE" 2>/dev/null || true
        echo "Backup source saved: $BACKUP_STORE"
    else
        echo "Backup source skipped. You can add it later with: vless-go-failover set-backup URL_OR_VLESS"
    fi

    echo "[3/9] Resolving subscription and generating Xray config..."
    "$GO_RESOLVER" \
        -input "$INPUT_VALUE" \
        -output "$XRAY_CONFIG" \
        -listen "$SOCKS_LISTEN" \
        -port "$SOCKS_PORT" \
        -profile "vless-out"

    create_update_command
    create_auto_update_command
    create_failover_command
    create_xray_init
    configure_proxy0
    start_xray

    echo
    echo "Done. Experimental Go edition installed."
    echo "Config: $XRAY_CONFIG"
    echo "Resolver/generator: $GO_RESOLVER"
    echo "Saved source: $SOURCE_STORE"
    echo "Primary source: $PRIMARY_STORE"
    echo "Backup source: $BACKUP_STORE"
    echo "Update command: $GO_UPDATE_CMD"
    echo "Auto-update command: $GO_AUTO_UPDATE_CMD"
    echo "Failover-lite command: $GO_FAILOVER_CMD"
    echo "Enable daily auto-update: vless-go-auto-update enable"
    echo "Configure backup: vless-go-failover set-backup URL_OR_VLESS"
    echo "Switch manually: vless-go-failover switch backup --first"
    echo "Override Proxy0 upstream host if needed: PROXY_UPSTREAM_HOST=192.168.1.1 sh xray_vless_failover_go.sh"
    echo "Note: failover daemon is intentionally not included yet."
}

main "$@"
