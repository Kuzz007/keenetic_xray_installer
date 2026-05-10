#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
GO_WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
DOCTOR_CMD="/opt/bin/vless-go-doctor"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
PROXY_IFACE="Proxy0"
PROXY_UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
TMP_DIR="/opt/tmp"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_EXPERIMENTAL_TAG="${GO_EXPERIMENTAL_TAG:-0.1.2-go-experimental}"
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_EXPERIMENTAL_TAG}/xray-failover-go-linux-arm64}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-$REPO_BRANCH}"
WATCHDOG_INSTALL_URL="${WATCHDOG_INSTALL_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/xray_vless_go_watchdog_install.sh}"
GO_INSTALLER_UPDATE_URL="${GO_INSTALLER_UPDATE_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}/scripts/xray-go-installer-update.sh}"
DOCTOR_URL="${DOCTOR_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}/scripts/vless-go-doctor.sh}"
INSTALL_WATCHDOG="${INSTALL_WATCHDOG:-1}"
START_WATCHDOG="${START_WATCHDOG:-1}"
INSTALL_UPDATER="${INSTALL_UPDATER:-1}"
INSTALL_DOCTOR="${INSTALL_DOCTOR:-1}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"

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
    echo "[1/12] Checking Entware packages..."
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
    echo "[2/12] Installing experimental Go resolver/generator..."
    mkdir -p "$(dirname "$GO_RESOLVER")" "$TMP_DIR"

    if [ -x "$GO_RESOLVER" ]; then
        echo "Existing binary found: $GO_RESOLVER"
        return 0
    fi

    echo "Downloading Go binary: $GO_BINARY_URL"
    if ! curl -fL -o "$GO_RESOLVER" "$GO_BINARY_URL"; then
        echo "ERROR: failed to download Go binary: $GO_BINARY_URL" >&2
        echo "Expected GitHub Release asset: xray-failover-go-linux-arm64" >&2
        echo "Release tag: $GO_EXPERIMENTAL_TAG" >&2
        exit 1
    fi

    chmod +x "$GO_RESOLVER"
}

create_xray_init() {
    echo "[9/12] Creating Xray init script..."
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

# NOTE: The legacy inline helper generation below is kept for compatibility with the original fresh installer.
# Installed systems are upgraded to the latest modular scripts by xray-go-installer-update.
create_update_command() {
    echo "[4/12] Creating vless-go-update command..."
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

create_auto_update_command() { echo "[5/12] Creating vless-go-auto-update command..."; install -m 755 scripts/vless-go-auto-update.sh "$GO_AUTO_UPDATE_CMD" 2>/dev/null || true; }
create_failover_command() { echo "[6/12] Creating vless-go-failover command..."; install -m 755 scripts/vless-go-failover.sh "$GO_FAILOVER_CMD" 2>/dev/null || true; }

install_updater() {
    echo "[7/12] Installing xray-go-installer-update command..."

    if [ "$INSTALL_UPDATER" = "0" ]; then
        echo "Updater installation skipped because INSTALL_UPDATER=0."
        return 0
    fi

    mkdir -p "$(dirname "$GO_INSTALLER_UPDATE_CMD")" "$TMP_DIR"
    TMP_UPDATER="$TMP_DIR/xray-go-installer-update.$$"
    trap 'rm -f "$TMP_UPDATER" 2>/dev/null || true' EXIT INT TERM

    if ! curl -fL -o "$TMP_UPDATER" "$GO_INSTALLER_UPDATE_URL"; then
        echo "ERROR: failed to download updater: $GO_INSTALLER_UPDATE_URL" >&2
        exit 1
    fi

    chmod +x "$TMP_UPDATER"
    mv "$TMP_UPDATER" "$GO_INSTALLER_UPDATE_CMD"
    chmod +x "$GO_INSTALLER_UPDATE_CMD"
}

install_doctor() {
    echo "[8/12] Installing vless-go-doctor command..."

    if [ "$INSTALL_DOCTOR" = "0" ]; then
        echo "Doctor installation skipped because INSTALL_DOCTOR=0."
        return 0
    fi

    mkdir -p "$(dirname "$DOCTOR_CMD")" "$TMP_DIR"
    TMP_DOCTOR="$TMP_DIR/vless-go-doctor.$$"
    trap 'rm -f "$TMP_DOCTOR" 2>/dev/null || true' EXIT INT TERM

    if ! curl -fL -o "$TMP_DOCTOR" "$DOCTOR_URL"; then
        echo "ERROR: failed to download doctor: $DOCTOR_URL" >&2
        exit 1
    fi

    chmod +x "$TMP_DOCTOR"
    mv "$TMP_DOCTOR" "$DOCTOR_CMD"
    chmod +x "$DOCTOR_CMD"
}

install_watchdog() {
    echo "[11/12] Installing watchdog daemon and recovery support..."

    if [ "$INSTALL_WATCHDOG" = "0" ]; then
        echo "Watchdog installation skipped because INSTALL_WATCHDOG=0."
        return 0
    fi

    mkdir -p "$TMP_DIR" "$XRAY_DIR"
    TMP_WATCHDOG_INSTALLER="$TMP_DIR/xray_vless_go_watchdog_install.$$"
    trap 'rm -f "$TMP_WATCHDOG_INSTALLER" 2>/dev/null || true' EXIT INT TERM

    if ! curl -fL -o "$TMP_WATCHDOG_INSTALLER" "$WATCHDOG_INSTALL_URL"; then
        echo "ERROR: failed to download watchdog installer: $WATCHDOG_INSTALL_URL" >&2
        exit 1
    fi

    chmod +x "$TMP_WATCHDOG_INSTALLER"
    WATCHDOG_BRANCH="$WATCHDOG_BRANCH" sh "$TMP_WATCHDOG_INSTALLER"

    if [ "$AUTO_RECOVER_PRIMARY" = "1" ] && [ -f "$GO_WATCHDOG_CONF" ]; then
        sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' "$GO_WATCHDOG_CONF"
    fi

    if [ "$START_WATCHDOG" = "1" ] && [ -x "$GO_WATCHDOG_INIT" ]; then
        "$GO_WATCHDOG_INIT" restart || "$GO_WATCHDOG_INIT" start || true
    else
        echo "Watchdog daemon not started. Start it with: $GO_WATCHDOG_INIT start"
    fi
}

valid_auto_lan_ip() {
    awk 'NF && ($1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print; exit }'
}

detect_lan_router_ip() {
    if [ -n "$PROXY_UPSTREAM_HOST" ]; then
        echo "$PROXY_UPSTREAM_HOST"
        return 0
    fi

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
    echo "[10/12] Configuring Proxy0..."
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
    echo "[12/12] Testing and starting Xray..."
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

    echo "[3/12] Resolving subscription and generating Xray config..."
    "$GO_RESOLVER" \
        -input "$INPUT_VALUE" \
        -output "$XRAY_CONFIG" \
        -listen "$SOCKS_LISTEN" \
        -port "$SOCKS_PORT" \
        -profile "vless-out" \
        -first

    create_update_command
    create_auto_update_command
    create_failover_command
    install_updater
    install_doctor
    create_xray_init
    configure_proxy0
    install_watchdog
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
    echo "Failover command: $GO_FAILOVER_CMD"
    echo "Installer update command: $GO_INSTALLER_UPDATE_CMD"
    echo "Doctor command: $DOCTOR_CMD"
    echo "Watchdog command: $GO_WATCHDOG_CMD"
    echo "Watchdog init: $GO_WATCHDOG_INIT"
    echo "Watchdog config: $GO_WATCHDOG_CONF"
    echo "Enable daily subscription auto-update: vless-go-auto-update enable"
    echo "Run diagnostics: vless-go-doctor"
    echo "Update installed Go edition without re-entering sources: xray-go-installer-update --first"
    echo "Switch manually: vless-go-failover switch backup --first"
    echo "Watchdog status: vless-go-watchdog status"
    echo "Override Proxy0 upstream host if needed: PROXY_UPSTREAM_HOST=192.168.1.1 sh xray_vless_failover_go.sh"
}

main "$@"
