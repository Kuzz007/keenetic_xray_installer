#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-latest}"
CONF="${CONF:-/opt/etc/xray/xray-go-agent.conf}"
BIN="${BIN:-/opt/bin/xray-go-agent}"
INIT="${INIT:-/opt/etc/init.d/S28xray-go-agent}"
LOG="${LOG:-/opt/var/log/xray-go-agent.log}"
REMOVE_SHELL_AGENT="${REMOVE_SHELL_AGENT:-1}"

ARG_SERVER_URL=""
ARG_ROUTER_ID=""
ARG_ROUTER_NAME=""
ARG_AGENT_TOKEN=""
ARG_POLL_INTERVAL=""

usage() {
  cat <<EOF
Usage: xray-go-agent-unified-install [options]

Options:
  --server-url URL       VPS control server URL, example http://1.2.3.4:18090
  --router-id ID         Router ID from control bot
  --router-name NAME     Router display name
  --agent-token TOKEN    Agent token from control bot
  --poll-interval SEC    Poll interval seconds, default 10
  -h, --help             Show this help

Environment:
  REPO=$REPO
  TAG=$TAG
  REMOVE_SHELL_AGENT=$REMOVE_SHELL_AGENT      1 = remove old shell-agent service/binary
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-url) [ "$#" -ge 2 ] || { echo "ERROR: --server-url requires value" >&2; exit 1; }; ARG_SERVER_URL="$2"; shift 2 ;;
      --router-id) [ "$#" -ge 2 ] || { echo "ERROR: --router-id requires value" >&2; exit 1; }; ARG_ROUTER_ID="$2"; shift 2 ;;
      --router-name) [ "$#" -ge 2 ] || { echo "ERROR: --router-name requires value" >&2; exit 1; }; ARG_ROUTER_NAME="$2"; shift 2 ;;
      --agent-token) [ "$#" -ge 2 ] || { echo "ERROR: --agent-token requires value" >&2; exit 1; }; ARG_AGENT_TOKEN="$2"; shift 2 ;;
      --poll-interval) [ "$#" -ge 2 ] || { echo "ERROR: --poll-interval requires value" >&2; exit 1; }; ARG_POLL_INTERVAL="$2"; shift 2 ;;
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
  arch_hint="$opkg_arches $kernel_arch"
  case "$arch_hint" in
    *aarch64*|*arm64*) echo "xray-go-agent-linux-arm64" ;;
    *mipselsf*|*mipsel*|*mipsle*) echo "xray-go-agent-linux-mipsle" ;;
    *mips*) echo "xray-go-agent-linux-mips" ;;
    *)
      echo "ERROR: unsupported router architecture: entware=$opkg_arches kernel=$kernel_arch" >&2
      echo "Supported: arm64/aarch64, mipsel/mipselsf/mipsle and mips" >&2
      exit 1
      ;;
  esac
}

fetch_file() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
}

sha256_file() {
  file="$1"
  [ -s "$file" ] || { echo ""; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
  else
    echo ""
  fi
}

sha256_from_file() {
  # First whitespace-separated field of line 1: matches both `sha256sum`
  # output ("<hash>  <filename>") and a bare-hash-only file.
  awk 'NR==1{print $1; exit}' "$1" 2>/dev/null
}

install_binary() {
  asset="$(detect_asset)"
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  mkdir -p "$(dirname "$BIN")"
  tmp="${BIN}.tmp.$$"
  tmp_sha="${tmp}.sha256"
  echo "Selected unified agent asset: $asset"
  echo "Downloading: $url"
  fetch_file "$url" "$tmp"

  echo "Downloading sha256: ${url}.sha256"
  if ! fetch_file "${url}.sha256" "$tmp_sha"; then
    rm -f "$tmp" "$tmp_sha"
    echo "ERROR: failed to download sha256 checksum: ${url}.sha256" >&2
    exit 1
  fi

  actual_sha256="$(sha256_file "$tmp")"
  expected_sha256="$(sha256_from_file "$tmp_sha")"
  if [ -z "$actual_sha256" ]; then
    rm -f "$tmp" "$tmp_sha"
    echo "ERROR: cannot calculate sha256 for downloaded binary." >&2
    exit 1
  fi
  if [ -z "$expected_sha256" ]; then
    rm -f "$tmp" "$tmp_sha"
    echo "ERROR: downloaded sha256 file is empty or invalid." >&2
    exit 1
  fi
  if [ "$actual_sha256" != "$expected_sha256" ]; then
    rm -f "$tmp" "$tmp_sha"
    echo "ERROR: sha256 mismatch for downloaded binary." >&2
    echo "Expected: $expected_sha256" >&2
    echo "Actual:   $actual_sha256" >&2
    exit 1
  fi
  echo "sha256 OK: $actual_sha256"
  rm -f "$tmp_sha"

  chmod +x "$tmp"
  mv "$tmp" "$BIN"
  echo "Installed unified binary: $BIN"
}

read_old_config() {
  [ -f "$CONF" ] || return 0
  if grep -Eq '^[[:space:]]*(SERVER_URL|ROUTER_ID|ROUTER_NAME|AGENT_TOKEN|POLL_INTERVAL)=' "$CONF" 2>/dev/null; then
    . "$CONF" || true
  else
    saved="${CONF}.old.$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONF" "$saved" 2>/dev/null || true
    echo "WARN: saved previous config to $saved"
  fi
}

write_config() {
  mkdir -p /opt/etc/xray
  old_server="http://1.2.3.4:18090"
  old_id="home"
  old_name="Дом"
  old_token=""
  old_interval="10"
  SERVER_URL="" ROUTER_ID="" ROUTER_NAME="" AGENT_TOKEN="" POLL_INTERVAL=""
  read_old_config
  old_server="${SERVER_URL:-$old_server}"
  old_id="${ROUTER_ID:-$old_id}"
  old_name="${ROUTER_NAME:-$old_name}"
  old_token="${AGENT_TOKEN:-$old_token}"
  old_interval="${POLL_INTERVAL:-$old_interval}"

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
PROCS=xray-go-agent
ARGS="-config $CONF"
PREARGS=""
DESC="Xray Unified Go Agent"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
  chmod +x "$INIT"
  touch "$LOG"
  echo "Installed init service: $INIT"
}

remove_legacy_agents() {
  /opt/etc/init.d/S28xray-go-agent-shell stop 2>/dev/null || true
  /opt/etc/init.d/S28xray-go-agent stop 2>/dev/null || true
  if [ "$REMOVE_SHELL_AGENT" = "1" ]; then
    rm -f /opt/etc/init.d/S28xray-go-agent-shell /opt/bin/xray-go-agent-shell
  fi
}

main() {
  parse_args "$@"
  mkdir -p /opt/etc/xray /opt/var/log /opt/tmp
  remove_legacy_agents
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
