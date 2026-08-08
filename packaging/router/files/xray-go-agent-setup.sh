#!/bin/sh
set -eu

CONF="${CONF:-/opt/etc/xray/xray-go-agent.conf}"
INIT="${INIT:-/opt/etc/init.d/S28xray-go-agent}"
BIN="${BIN:-/opt/bin/xray-go-agent}"
SERVER_URL=""
SERVER_FINGERPRINT=""
ROUTER_ID=""
ROUTER_NAME=""
AGENT_TOKEN=""
POLL_INTERVAL="10"
START_AGENT="1"

usage() {
    cat <<'EOF'
xray-go-agent-setup - configure the agent already included in a router bundle

Usage:
  xray-go-agent-setup --server-url URL --router-id ID --router-name NAME \
    --agent-token TOKEN [--server-fingerprint SHA256] [--poll-interval SEC]
  xray-go-agent-setup --reuse-config

Options:
  --no-start       write configuration and service without starting the agent
  --reuse-config   keep the existing agent configuration and repair its service

This helper never downloads a binary. Both FULL and MINIMAL bundles install it.
EOF
}

safe_value() {
    case "$1" in
        *'"'*|*'$'*|*'`'*|*'\'*) return 1 ;;
    esac
    cleaned="$(printf '%s' "$1" | tr -d '\r\n')"
    [ "$cleaned" = "$1" ]
}

REUSE_CONFIG="0"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --server-url) [ "$#" -ge 2 ] || { echo "ERROR: --server-url requires value" >&2; exit 2; }; SERVER_URL="$2"; shift 2 ;;
        --server-fingerprint) [ "$#" -ge 2 ] || { echo "ERROR: --server-fingerprint requires value" >&2; exit 2; }; SERVER_FINGERPRINT="$2"; shift 2 ;;
        --router-id) [ "$#" -ge 2 ] || { echo "ERROR: --router-id requires value" >&2; exit 2; }; ROUTER_ID="$2"; shift 2 ;;
        --router-name) [ "$#" -ge 2 ] || { echo "ERROR: --router-name requires value" >&2; exit 2; }; ROUTER_NAME="$2"; shift 2 ;;
        --agent-token) [ "$#" -ge 2 ] || { echo "ERROR: --agent-token requires value" >&2; exit 2; }; AGENT_TOKEN="$2"; shift 2 ;;
        --poll-interval) [ "$#" -ge 2 ] || { echo "ERROR: --poll-interval requires value" >&2; exit 2; }; POLL_INTERVAL="$2"; shift 2 ;;
        --reuse-config) REUSE_CONFIG="1"; shift ;;
        --no-start) START_AGENT="0"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ -x "$BIN" ] || { echo "ERROR: bundled agent is not installed: $BIN" >&2; exit 1; }

if [ "$REUSE_CONFIG" = "1" ]; then
    [ -s "$CONF" ] || { echo "ERROR: existing agent config not found: $CONF" >&2; exit 1; }
else
    case "$SERVER_URL" in http://*|https://*) ;; *) echo "ERROR: --server-url must use http:// or https://" >&2; exit 2 ;; esac
    [ -n "$ROUTER_ID" ] || { echo "ERROR: --router-id is required" >&2; exit 2; }
    [ -n "$ROUTER_NAME" ] || ROUTER_NAME="$ROUTER_ID"
    [ -n "$AGENT_TOKEN" ] || { echo "ERROR: --agent-token is required" >&2; exit 2; }
    case "$POLL_INTERVAL" in ''|*[!0-9]*) echo "ERROR: --poll-interval must be numeric" >&2; exit 2 ;; esac
    [ "$POLL_INTERVAL" -ge 2 ] || { echo "ERROR: --poll-interval must be at least 2 seconds" >&2; exit 2; }
    for value in "$SERVER_URL" "$SERVER_FINGERPRINT" "$ROUTER_ID" "$ROUTER_NAME" "$AGENT_TOKEN"; do
        safe_value "$value" || { echo "ERROR: agent values contain unsafe quotes, escapes or newlines" >&2; exit 2; }
    done

    mkdir -p "$(dirname "$CONF")"
    tmp="${CONF}.tmp.$$"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM
    {
        printf 'SERVER_URL="%s"\n' "$SERVER_URL"
        printf 'SERVER_FINGERPRINT="%s"\n' "$SERVER_FINGERPRINT"
        printf 'ROUTER_ID="%s"\n' "$ROUTER_ID"
        printf 'ROUTER_NAME="%s"\n' "$ROUTER_NAME"
        printf 'AGENT_TOKEN="%s"\n' "$AGENT_TOKEN"
        printf 'POLL_INTERVAL="%s"\n' "$POLL_INTERVAL"
    } >"$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CONF"
    trap - EXIT INT TERM
fi

mkdir -p "$(dirname "$INIT")" /opt/var/log
tmp="${INIT}.tmp.$$"
trap 'rm -f "$tmp" 2>/dev/null || true' EXIT INT TERM
cat >"$tmp" <<EOF
#!/opt/bin/sh

ENABLED=yes
PROCS=xray-go-agent
ARGS="-config $CONF"
PREARGS=""
DESC="Xray Unified Go Agent"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
chmod 755 "$tmp"
mv "$tmp" "$INIT"
trap - EXIT INT TERM

if [ "$START_AGENT" = "1" ]; then
    "$INIT" restart || "$INIT" start
fi

echo "Agent configured: $CONF"
echo "Agent service: $INIT"
