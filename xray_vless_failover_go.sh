#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
PROXY_IFACE="Proxy0"
TMP_DIR="/opt/tmp"

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
    echo "[1/6] Checking Entware packages..."
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
    echo "[2/6] Installing experimental Go resolver/generator..."
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
    echo "[4/6] Creating Xray init script..."
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

configure_proxy0() {
    echo "[5/6] Configuring Proxy0..."
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
    echo "[6/6] Testing and starting Xray..."
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

    echo "[3/6] Resolving subscription and generating Xray config..."
    "$GO_RESOLVER" \
        -input "$INPUT_VALUE" \
        -output "$XRAY_CONFIG" \
        -listen "$SOCKS_LISTEN" \
        -port "$SOCKS_PORT" \
        -profile "vless-out"

    create_xray_init
    configure_proxy0
    start_xray

    echo
    echo "Done. Experimental Go edition installed."
    echo "Config: $XRAY_CONFIG"
    echo "Resolver/generator: $GO_RESOLVER"
    echo "Note: failover daemon and subscription auto-update are intentionally not included yet."
}

main "$@"
