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
SOCKS_AUTH_CONF="$XRAY_DIR/vless-go-socks-auth.conf"
MUX_STATE_CONF="$XRAY_DIR/mux-state.json"
TMP_DIR="/opt/tmp"
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"
AWG_RUNTIME_STATE="$XRAY_DIR/awg/runtime.json"

if [ -s "$LOCK_HELPER" ]; then
    . "$LOCK_HELPER"
else
    vless_go_acquire_lock() { return 0; }
    vless_go_release_lock() { return 0; }
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

xray_init_alive() {
    [ -x "$INIT_SCRIPT" ] || return 1
    "$INIT_SCRIPT" status >/dev/null 2>&1
}

socks_port_listening() {
    netstat -lnt 2>/dev/null | grep -Eq "(^|[[:space:]])(127\.0\.0\.1:|0\.0\.0\.0:|:::)${SOCKS_PORT}([[:space:]]|$)|:${SOCKS_PORT}[[:space:]]"
}

wait_for_xray_ready() {
    i=1
    while [ "$i" -le 10 ]; do
        if xray_init_alive && socks_port_listening; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

restart_xray_checked() {
    if [ ! -x "$INIT_SCRIPT" ]; then
        echo "WARNING: init script not found: $INIT_SCRIPT" >&2
        echo "Config updated, restart Xray manually." >&2
        return 0
    fi

    if ! "$INIT_SCRIPT" restart; then
        "$INIT_SCRIPT" start
    fi

    if wait_for_xray_ready; then
        return 0
    fi

    echo "WARNING: Xray did not become ready after restart; trying start once more..." >&2
    "$INIT_SCRIPT" start >/dev/null 2>&1 || "$INIT_SCRIPT" restart >/dev/null 2>&1 || true

    if wait_for_xray_ready; then
        return 0
    fi

    echo "ERROR: Xray is not ready after config update." >&2
    echo "Init status:" >&2
    "$INIT_SCRIPT" status >&2 || true
    echo "SOCKS listen check:" >&2
    netstat -lnt 2>/dev/null | grep "$SOCKS_PORT" >&2 || true
    echo "Run: xray-go doctor" >&2
    return 1
}

usage() {
    echo "Usage: vless-go-update [--source URL_OR_VLESS] [--selector first|index:N] [--first] [--no-restart] [--verbose]"
    echo ""
    echo "Options:"
    echo "  --source VALUE      Replace saved VLESS/subscription source before updating."
    echo "  --selector VALUE    Select profile using first or index:N."
    echo "  --first             Select first profile without interactive prompt."
    echo "  --no-restart        Generate and validate config, but do not restart Xray."
    echo "  --verbose           Show resolver profile/server metadata while generating config."
    echo ""
    echo "SOCKS auth:"
    echo "  Managed by /opt/bin/vless-go-socks-auth and $SOCKS_AUTH_CONF."
    echo ""
    echo "Default output avoids printing profile/server metadata. Use --verbose only for local debugging."
    echo ""
    echo "When --selector/--first are omitted, vless-go-update reads selector from:"
    echo "  /opt/etc/xray/vless-go.<active-slot>.selector"
    echo "and falls back to first."
}

validate_source_value() {
    value="$1"
    case "$value" in
        vless://*|http://*|https://*) return 0 ;;
        *)
            echo "ERROR: source must start with vless://, http://, or https://" >&2
            echo "Saved source was not changed." >&2
            return 1
            ;;
    esac
}

valid_socks_credential() {
    value="$1"
    case "$value" in
        ''|*[!A-Za-z0-9._@:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

load_socks_auth() {
    XRAY_SOCKS_AUTH="0"
    XRAY_SOCKS_USER=""
    XRAY_SOCKS_PASS=""
    if [ -s "$SOCKS_AUTH_CONF" ]; then
        # shellcheck disable=SC1090
        . "$SOCKS_AUTH_CONF"
    fi
    XRAY_SOCKS_AUTH="${XRAY_SOCKS_AUTH:-0}"
    XRAY_SOCKS_USER="${XRAY_SOCKS_USER:-}"
    XRAY_SOCKS_PASS="${XRAY_SOCKS_PASS:-}"

    case "$XRAY_SOCKS_AUTH" in 1|yes|true|on) XRAY_SOCKS_AUTH="1" ;; *) XRAY_SOCKS_AUTH="0" ;; esac
    if [ "$XRAY_SOCKS_AUTH" = "1" ]; then
        valid_socks_credential "$XRAY_SOCKS_USER" || { echo "ERROR: invalid SOCKS auth username in $SOCKS_AUTH_CONF" >&2; exit 1; }
        valid_socks_credential "$XRAY_SOCKS_PASS" || { echo "ERROR: invalid SOCKS auth password in $SOCKS_AUTH_CONF" >&2; exit 1; }
    fi
}

apply_socks_auth_to_config() {
    config_file="$1"
    [ "$XRAY_SOCKS_AUTH" = "1" ] || return 0
    tmp_file="$config_file.auth.$$"

    awk -v user="$XRAY_SOCKS_USER" -v pass="$XRAY_SOCKS_PASS" '
        BEGIN { socks = 0; settings = 0; patched = 0 }
        /"protocol"[[:space:]]*:[[:space:]]*"socks"/ { socks = 1 }
        socks && !patched && /"settings"[[:space:]]*:[[:space:]]*\{/ {
            print
            print "      \"accounts\": ["
            print "        {"
            print "          \"pass\": \"" pass "\","
            print "          \"user\": \"" user "\""
            print "        }"
            print "      ],"
            print "      \"auth\": \"password\","
            print "      \"udp\": true"
            settings = 1
            next
        }
        settings {
            if ($0 ~ /^[[:space:]]*\},?[[:space:]]*$/) {
                print
                settings = 0
                patched = 1
                socks = 0
            }
            next
        }
        { print }
        END { if (!patched) exit 7 }
    ' "$config_file" > "$tmp_file" || {
        rm -f "$tmp_file" 2>/dev/null || true
        echo "ERROR: failed to apply SOCKS auth to generated Xray config" >&2
        return 1
    }

    mv "$tmp_file" "$config_file"
    chmod 600 "$config_file" 2>/dev/null || true
}

apply_persistent_mux_state_to_config() {
    config_file="$1"
    [ -s "$config_file" ] || return 0
    [ -s "$MUX_STATE_CONF" ] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        echo "WARNING: python3 not found; skip persistent Mux merge for generated config" >&2
        return 0
    fi

    python3 - "$config_file" "$MUX_STATE_CONF" <<'PY'
import json
import os
import sys

cfg_path, state_path = sys.argv[1], sys.argv[2]
with open(cfg_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)
with open(state_path, 'r', encoding='utf-8') as f:
    st = json.load(f)

outbounds = cfg.get('outbounds') or []
target = None
requested_tag = (st.get('outbound_tag') or '').strip()

if requested_tag:
    for outbound in outbounds:
        if isinstance(outbound, dict) and outbound.get('tag') == requested_tag:
            target = outbound
            break

if target is None:
    for outbound in outbounds:
        if isinstance(outbound, dict) and str(outbound.get('protocol', '')).lower() == 'vless':
            target = outbound
            break

if target is None:
    for outbound in outbounds:
        if isinstance(outbound, dict) and str(outbound.get('protocol', '')).lower() not in ('freedom', 'blackhole'):
            target = outbound
            break

if target is None:
    sys.exit(0)

concurrency = int(st.get('concurrency') or 8)
xudp_raw = st.get('xudpConcurrency')
xudp = int(xudp_raw if xudp_raw is not None else -1)
proxy443 = st.get('xudpProxyUDP443') or 'skip'

target['mux'] = {
    'enabled': True,
    'concurrency': concurrency,
    'xudpConcurrency': xudp,
    'xudpProxyUDP443': proxy443,
}

tmp = cfg_path + '.mux-state.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write('\n')
os.replace(tmp, cfg_path)
PY
    chmod 600 "$config_file" 2>/dev/null || true
}

NO_RESTART="0"
VERBOSE="0"
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
            SELECTOR="first"
            shift
            ;;
        --no-restart)
            NO_RESTART="1"
            shift
            ;;
        --verbose|-v)
            VERBOSE="1"
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

if [ -s "$AWG_RUNTIME_STATE" ]; then
    echo "ERROR: isolated AWG slot owns Xray; deactivate or recover AWG before updating VLESS." >&2
    exit 1
fi

mkdir -p "$XRAY_DIR" "$TMP_DIR"
load_socks_auth

if [ -n "$NEW_SOURCE" ]; then
    validate_source_value "$NEW_SOURCE"
    SOURCE_VALUE="$NEW_SOURCE"
else
    if [ ! -s "$SOURCE_STORE" ]; then
        echo "ERROR: source is not saved. Re-run xray_vless_failover_go.sh or use: vless-go-update --source URL_OR_VLESS" >&2
        exit 1
    fi
    SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE")"
    validate_source_value "$SOURCE_VALUE"
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

require_select_index_support() {
    if ! "$GO_RESOLVER" -h 2>&1 | grep -q -- '-select-index'; then
        echo "ERROR: installed Go resolver does not support -select-index." >&2
        echo "Update /opt/bin/xray-failover-go through xray-go-installer-update or install release 0.1.1-go-experimental+." >&2
        return 1
    fi
}

TMP_CONFIG="$TMP_DIR/config.vless-go-update.$$.json"
RESOLVER_LOG="$TMP_DIR/vless-go-update.resolver.$$.log"
trap 'rm -f "$TMP_CONFIG" "$RESOLVER_LOG" 2>/dev/null || true; vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

case "$SELECTOR" in
    first|'')
        set -- -first
        ;;
    index:*)
        IDX="$(selector_index)"
        require_select_index_support
        set -- -select-index "$IDX"
        ;;
    *)
        echo "ERROR: unsupported selector: $SELECTOR (supported: first, index:N)" >&2
        exit 1
        ;;
esac

set +e
"$GO_RESOLVER" \
    -input "$SOURCE_VALUE" \
    -output "$TMP_CONFIG" \
    -listen "$SOCKS_LISTEN" \
    -port "$SOCKS_PORT" \
    -profile "vless-out" \
    "$@" >"$RESOLVER_LOG" 2>&1
RESOLVER_RC="$?"
set -e

if [ "$RESOLVER_RC" -ne 0 ]; then
    echo "ERROR: Go resolver failed while generating config." >&2
    [ -s "$RESOLVER_LOG" ] && sed 's/^/  /' "$RESOLVER_LOG" >&2
    exit "$RESOLVER_RC"
fi

apply_socks_auth_to_config "$TMP_CONFIG"
apply_persistent_mux_state_to_config "$TMP_CONFIG"

if [ "$VERBOSE" = "1" ] && [ -s "$RESOLVER_LOG" ]; then
    cat "$RESOLVER_LOG"
fi

XRAY_BIN="$(get_xray_bin)"
if [ -z "$XRAY_BIN" ]; then
    echo "ERROR: xray binary not found." >&2
    exit 1
fi

if ! "$XRAY_BIN" run -test -config "$TMP_CONFIG" >/dev/null 2>&1; then
    "$XRAY_BIN" test -config "$TMP_CONFIG"
fi

if [ -n "$NEW_SOURCE" ]; then
    printf '%s\n' "$NEW_SOURCE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
fi

cp "$TMP_CONFIG" "$XRAY_CONFIG"
chmod 600 "$XRAY_CONFIG" 2>/dev/null || true

if [ "$NO_RESTART" = "1" ]; then
    echo "Updated and validated config: $XRAY_CONFIG"
    echo "Selector: $SELECTOR"
    if [ "$XRAY_SOCKS_AUTH" = "1" ]; then echo "SOCKS auth: enabled"; else echo "SOCKS auth: disabled"; fi
    [ -s "$MUX_STATE_CONF" ] && echo "Persistent Mux: merged from $MUX_STATE_CONF" || echo "Persistent Mux: not configured"
    echo "Xray restart skipped."
    exit 0
fi

restart_xray_checked

echo "Updated VLESS config from saved source."
echo "Selector: $SELECTOR"
if [ "$XRAY_SOCKS_AUTH" = "1" ]; then echo "SOCKS auth: enabled"; else echo "SOCKS auth: disabled"; fi
[ -s "$MUX_STATE_CONF" ] && echo "Persistent Mux: merged from $MUX_STATE_CONF" || echo "Persistent Mux: not configured"
