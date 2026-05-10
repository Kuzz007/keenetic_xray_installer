#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
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
    echo "Usage: vless-go-update [--source URL_OR_VLESS] [--selector first|index:N] [--first] [--no-restart]"
    echo ""
    echo "Options:"
    echo "  --source VALUE      Replace saved VLESS/subscription source before updating."
    echo "  --selector VALUE    Select profile using first or index:N."
    echo "  --first             Select first profile without interactive prompt."
    echo "  --no-restart        Generate and validate config, but do not restart Xray."
    echo ""
    echo "When --selector/--first are omitted, vless-go-update reads selector from:"
    echo "  /opt/etc/xray/vless-go.<active-slot>.selector"
    echo "and falls back to first."
}

FIRST="0"
NO_RESTART="0"
NEW_SOURCE=""
SELECTOR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source)
            [ "$#" -ge 2 ] || { echo "ERROR: --source requires value" >&2; exit 1; }
            NEW_SOURCE="$2"
            shift 2
            ;;
        --selector)
            [ "$#" -ge 2 ] || { echo "ERROR: --selector requires value" >&2; exit 1; }
            SELECTOR="$2"
            shift 2
            ;;
        --first)
            FIRST="1"
            SELECTOR="first"
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

if [ -z "$SELECTOR" ]; then
    ACTIVE_SLOT="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    case "$ACTIVE_SLOT" in
        primary|backup)
            SELECTOR="$(sed -n '1p' "$XRAY_DIR/vless-go.$ACTIVE_SLOT.selector" 2>/dev/null || true)"
            ;;
    esac
fi
SELECTOR="${SELECTOR:-first}"

selector_index() {
    case "$SELECTOR" in
        index:*)
            IDX="${SELECTOR#index:}"
            case "$IDX" in
                ''|*[!0-9]*) echo "ERROR: invalid selector index: $SELECTOR" >&2; return 1 ;;
                0) echo "ERROR: selector index must be 1-based: $SELECTOR" >&2; return 1 ;;
                *) printf '%s\n' "$IDX" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

go_supports_select_index() {
    "$GO_RESOLVER" -h 2>&1 | grep -q -- '-select-index'
}

extract_vless_links_from_text() {
    sed 's/[[:space:]<>"'"'']/\n/g' | grep '^vless://' | awk '!seen[$0]++'
}

extract_link_by_index_shell() {
    SOURCE_VALUE="$1"
    IDX="$2"
    TMP_SUB="$TMP_DIR/vless-go-sub.$$.$RANDOM.txt"
    TMP_DECODED="$TMP_DIR/vless-go-sub-decoded.$$.$RANDOM.txt"

    rm -f "$TMP_SUB" "$TMP_DECODED" 2>/dev/null || true

    case "$SOURCE_VALUE" in
        vless://*)
            if [ "$IDX" = "1" ]; then
                printf '%s\n' "$SOURCE_VALUE"
                return 0
            fi
            echo "ERROR: selector $SELECTOR is out of range for single VLESS link" >&2
            return 1
            ;;
        http://*|https://*)
            curl -fsSL -o "$TMP_SUB" "$SOURCE_VALUE"
            ;;
        *)
            echo "ERROR: source must be vless:// or http(s) subscription URL" >&2
            return 1
            ;;
    esac

    LINK="$(cat "$TMP_SUB" | extract_vless_links_from_text | sed -n "${IDX}p")"
    if [ -z "$LINK" ] && command -v base64 >/dev/null 2>&1; then
        tr -d '\r\n\t ' < "$TMP_SUB" | base64 -d > "$TMP_DECODED" 2>/dev/null || true
        LINK="$(cat "$TMP_DECODED" 2>/dev/null | extract_vless_links_from_text | sed -n "${IDX}p")"
    fi

    rm -f "$TMP_SUB" "$TMP_DECODED" 2>/dev/null || true

    if [ -z "$LINK" ]; then
        echo "ERROR: failed to extract profile $IDX from subscription" >&2
        return 1
    fi

    printf '%s\n' "$LINK"
}

SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE")"
TMP_CONFIG="$TMP_DIR/config.vless-go-update.$$.$RANDOM.json"
trap 'rm -f "$TMP_CONFIG" 2>/dev/null || true; vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

case "$SELECTOR" in
    first|'')
        set -- -first
        ;;
    index:*)
        IDX="$(selector_index)"
        if go_supports_select_index; then
            set -- -select-index "$IDX"
        else
            echo "Go resolver does not support -select-index yet; using shell extraction fallback for selector $SELECTOR" >&2
            SOURCE_VALUE="$(extract_link_by_index_shell "$SOURCE_VALUE" "$IDX")"
            set -- -first
        fi
        ;;
    *)
        echo "ERROR: unsupported selector: $SELECTOR (supported: first, index:N)" >&2
        exit 1
        ;;
esac

"$GO_RESOLVER" \
    -input "$SOURCE_VALUE" \
    -output "$TMP_CONFIG" \
    -listen "$SOCKS_LISTEN" \
    -port "$SOCKS_PORT" \
    -profile "vless-out" \
    "$@"

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
    echo "Selector: $SELECTOR"
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
echo "Selector: $SELECTOR"
