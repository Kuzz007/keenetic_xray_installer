#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-web-control-experiment}"
CONF="${CONF:-/opt/etc/xray/xray-web-agent.conf}"
BIN="${BIN:-/opt/bin/xray-web-agent}"
INIT="${INIT:-/opt/etc/init.d/S29xray-web-agent}"
LOG="${LOG:-/opt/var/log/xray-web-agent.log}"

ARG_SERVER_URL=""
ARG_ROUTER_ID=""
ARG_ROUTER_NAME=""
ARG_AGENT_TOKEN=""
ARG_POLL_INTERVAL=""

usage() {
  cat <<EOF
Usage: xray-web-agent-install [options]

Options:
  --server-url URL       Web control server URL, example https://panel.example.com
  --router-id ID         Router ID
  --router-name NAME     Router display name
  --agent-token TOKEN    Agent token from web control server
  --poll-interval SEC    Poll interval seconds, default 10
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

detect_asset() {
  opkg_arches=""
  if command -v opkg >/dev/null 2>&1; then
    opkg_arches="$(opkg print-architecture 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  fi
  kernel_arch="$(uname -m 2>/dev/null || echo unknown)"
  hint="$opkg_arches $kernel_arch"
  case "$hint" in
    *aarch64*|*arm64*) echo "xray-web-agent-linux-arm64" ;;
    *mipselsf*|*mipsel*|*mipsle*) echo "xray-web-agent-linux-mipsle" ;;
    *mips*) echo "xray-web-agent-linux-mips" ;;
    *) echo "ERROR: unsupported architecture: entware=$opkg_arches kernel=$kernel_arch" >&2; exit 1 ;;
  esac
}

install_binary() {
  asset="$(detect_asset)"
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  mkdir -p "$(dirname "$BIN")" /opt/tmp
  tmp="${BIN}.tmp.$$"
  echo "Selected web agent asset: $asset"
  echo "Downloading: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 3 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$BIN"
  echo "Installed binary: $BIN"
}

write_config() {
  mkdir -p /opt/etc/xray
  old_server="https://panel.example.com"
  old_id="test-router"
  old_name="Test Router"
  old_token=""
  old_interval="10"
  if [ -f "$CONF" ]; then . "$CONF" || true; fi
  old_server="${SERVER_URL:-$old_server}"
  old_id="${ROUTER_ID:-$old_id}"
  old_name="${ROUTER_NAME:-$old_name}"
  old_token="${AGENT_TOKEN:-$old_token}"
  old_interval="${POLL_INTERVAL:-$old_interval}"

  server_url="$(value_or_ask "$ARG_SERVER_URL" 'Web control server URL' "$old_server")"
  router_id="$(value_or_ask "$ARG_ROUTER_ID" 'Router ID' "$old_id")"
  router_name="$(value_or_ask "$ARG_ROUTER_NAME" 'Router display name' "$old_name")"
  agent_token="$(value_or_ask "$ARG_AGENT_TOKEN" 'Agent token' "$old_token")"
  poll_interval="$(value_or_ask "$ARG_POLL_INTERVAL" 'Poll interval seconds' "$old_interval")"

  [ -n "$server_url" ] || { echo "ERROR: server URL required" >&2; exit 1; }
  [ -n "$router_id" ] || { echo "ERROR: router ID required" >&2; exit 1; }
  [ -n "$agent_token" ] || { echo "ERROR: agent token required" >&2; exit 1; }

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
PROCS=xray-web-agent
ARGS="-config $CONF"
PREARGS=""
DESC="Xray Web Agent Experimental"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
  chmod +x "$INIT"
  touch "$LOG"
  echo "Installed init service: $INIT"
}

main() {
  parse_args "$@"
  mkdir -p /opt/etc/xray /opt/var/log /opt/tmp
  /opt/etc/init.d/S29xray-web-agent stop 2>/dev/null || true
  install_binary
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
