#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
REF="${REF:-main}"
CONF="${CONF:-/opt/etc/xray/xray-go-agent.conf}"
BIN="${BIN:-/opt/bin/xray-go-agent-shell}"
INIT="${INIT:-/opt/etc/init.d/S28xray-go-agent-shell}"
LOG="${LOG:-/opt/var/log/xray-go-agent-shell.log}"

ARG_SERVER_URL=""
ARG_ROUTER_ID=""
ARG_ROUTER_NAME=""
ARG_AGENT_TOKEN=""
ARG_POLL_INTERVAL=""

usage() {
  cat <<EOF
Usage: xray-go-agent-shell-install [options]

Options:
  --server-url URL
  --router-id ID
  --router-name NAME
  --agent-token TOKEN
  --poll-interval SEC
  -h, --help
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-url) ARG_SERVER_URL="$2"; shift 2 ;;
      --router-id) ARG_ROUTER_ID="$2"; shift 2 ;;
      --router-name) ARG_ROUTER_NAME="$2"; shift 2 ;;
      --agent-token) ARG_AGENT_TOKEN="$2"; shift 2 ;;
      --poll-interval) ARG_POLL_INTERVAL="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then printf '%s [%s]: ' "$prompt" "$default" >&2; else printf '%s: ' "$prompt" >&2; fi
  IFS= read -r value || value=""
  [ -n "$value" ] || value="$default"
  printf '%s' "$value"
}

value_or_ask() {
  value="$1"
  prompt="$2"
  default="$3"
  if [ -n "$value" ]; then printf '%s' "$value"; else ask "$prompt" "$default"; fi
}

install_agent() {
  mkdir -p "$(dirname "$BIN")"
  url="https://raw.githubusercontent.com/${REPO}/${REF}/scripts/xray-go-agent-shell.sh"
  tmp="${BIN}.tmp.$$"
  echo "Downloading: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$BIN"
  echo "Installed shell agent: $BIN"
}

write_config() {
  mkdir -p /opt/etc/xray
  old_server="http://1.2.3.4:18090"
  old_id="home"
  old_name="Дом"
  old_token=""
  old_interval="5"
  if [ -f "$CONF" ]; then
    . "$CONF" || true
    old_server="${SERVER_URL:-$old_server}"
    old_id="${ROUTER_ID:-$old_id}"
    old_name="${ROUTER_NAME:-$old_name}"
    old_token="${AGENT_TOKEN:-$old_token}"
    old_interval="${POLL_INTERVAL:-$old_interval}"
  fi
  server_url="$(value_or_ask "$ARG_SERVER_URL" 'VPS control server URL' "$old_server")"
  router_id="$(value_or_ask "$ARG_ROUTER_ID" 'Router ID' "$old_id")"
  router_name="$(value_or_ask "$ARG_ROUTER_NAME" 'Router display name' "$old_name")"
  agent_token="$(value_or_ask "$ARG_AGENT_TOKEN" 'Agent token' "$old_token")"
  poll_interval="$(value_or_ask "$ARG_POLL_INTERVAL" 'Poll interval seconds' "$old_interval")"
  [ -n "$server_url" ] || { echo "ERROR: server URL is required" >&2; exit 1; }
  [ -n "$router_id" ] || { echo "ERROR: router ID is required" >&2; exit 1; }
  [ -n "$agent_token" ] || { echo "ERROR: agent token is required" >&2; exit 1; }
  tmp="${CONF}.tmp.$$"
  cat > "$tmp" <<EOF
SERVER_URL="${server_url}"
ROUTER_ID="${router_id}"
ROUTER_NAME="${router_name}"
AGENT_TOKEN="${agent_token}"
POLL_INTERVAL="${poll_interval}"
EOF
  chmod 600 "$tmp"
  mv "$tmp" "$CONF"
  echo "Created config: $CONF"
}

install_init() {
  mkdir -p /opt/etc/init.d /opt/var/log
  cat > "$INIT" <<EOF
#!/opt/bin/sh

ENABLED=yes
PROCS=xray-go-agent-shell
ARGS="-config $CONF"
PREARGS=""
DESC="Xray Go Shell Agent"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
  chmod +x "$INIT"
  touch "$LOG"
  echo "Installed init service: $INIT"
}

main() {
  parse_args "$@"
  /opt/etc/init.d/S28xray-go-agent stop 2>/dev/null || true
  rm -f /opt/etc/init.d/S28xray-go-agent
  rm -f /opt/bin/xray-go-agent
  install_agent
  write_config
  install_init
  "$INIT" restart || "$INIT" start || true
  echo
  echo "Done. Checks:"
  echo "  $INIT status"
  echo "  tail -n 80 $LOG"
  echo "  $BIN -config $CONF -once"
}

main "$@"
