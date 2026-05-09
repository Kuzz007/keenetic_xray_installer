#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
PROXY_IFACE="Proxy0"
TMP_DIR="/opt/tmp"
SOURCE_STORE="$XRAY_DIR/vless-go.source"

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

ensure_packages() {
    echo "[1/7] Checking Entware packages..."
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is required." >&2
        exit 1
    fi

    NEED_UPDATE="0"
    command -v curl >/dev/null 2>&1 || NEED_UPDATE="1"
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
}

install_go_resolver() {
    echo "[2/7] Installing experimental Go resolver/generator..."
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
    echo "[5/7] Creating Xray init script..."
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
    echo "[4/7] Creating vless-go-update command..."
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

configure_proxy0() {
    echo "[6/7] Configuring Proxy0..."
    if ! command -v ndmc >/dev/null 2>&1; then
        echo "WARNING: ndmc not found. Configure Proxy0 manually to SOCKS5 $SOCKS_LISTEN:$SOCKS_PORT."
        return 0
    fi

    ROUTER_IP="$(ip -4 addr show 2>/dev/null | awk '/inet / { gsub(/\/.*/, "", $2); if ($2 ~ /^192\.168\./ || $2 ~ /^10\./ || $2 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print $2; exit } }')"
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
    echo "[7/7] Testing and starting Xray..."
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
    read_tty "Enter VLESS link or subscription URL: "
    INPUT_VALUE="$REPLY"
    if [ -z "$INPUT_VALUE" ]; then
        echo "ERROR: empty input." >&2
        exit 1
    fi

    printf '%s\n' "$INPUT_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true

    echo "[3/7] Resolving subscription and generating Xray config..."
    "$GO_RESOLVER" \
        -input "$INPUT_VALUE" \
        -output "$XRAY_CONFIG" \
        -listen "$SOCKS_LISTEN" \
        -port "$SOCKS_PORT" \
        -profile "vless-out"

    create_update_command
    create_xray_init
    configure_proxy0
    start_xray

    echo
    echo "Done. Experimental Go edition installed."
    echo "Config: $XRAY_CONFIG"
    echo "Resolver/generator: $GO_RESOLVER"
    echo "Saved source: $SOURCE_STORE"
    echo "Update command: $GO_UPDATE_CMD"
    echo "Note: failover daemon and subscription auto-update are intentionally not included yet."
}

main "$@"
