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
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"

if [ -s "$LOCK_HELPER" ]; then
    . "$LOCK_HELPER"
else
    vless_go_acquire_lock() { return 0; }
fi

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

vless_go_acquire_lock "vless-go-update"

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
trap 'rm -f "$TMP_CONFIG" 2>/dev/null || true; vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

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
