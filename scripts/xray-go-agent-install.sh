#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-latest}"
CONF="${CONF:-/opt/etc/xray/xray-go-agent.conf}"
BIN="${BIN:-/opt/bin/xray-go-agent}"
INIT="${INIT:-/opt/etc/init.d/S28xray-go-agent}"
LOG="${LOG:-/opt/var/log/xray-go-agent.log}"

ARG_SERVER_URL=""
ARG_ROUTER_ID=""
ARG_ROUTER_NAME=""
ARG_AGENT_TOKEN=""
ARG_POLL_INTERVAL=""

usage() {
  cat <<EOF
Usage: xray-go-agent-install [options]

Options:
  --server-url URL       VPS control server URL, example http://1.2.3.4:18090
  --router-id ID         Router ID from control bot, latin only
  --router-name NAME     Router display name
  --agent-token TOKEN    Agent token from control bot
  --poll-interval SEC    Poll interval seconds, default 10
  -h, --help             Show this help

If required options are omitted, the installer asks interactively.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-url)
        [ "$#" -ge 2 ] || { echo "ERROR: --server-url requires value" >&2; exit 1; }
        ARG_SERVER_URL="$2"; shift 2 ;;
      --router-id)
        [ "$#" -ge 2 ] || { echo "ERROR: --router-id requires value" >&2; exit 1; }
        ARG_ROUTER_ID="$2"; shift 2 ;;
      --router-name)
        [ "$#" -ge 2 ] || { echo "ERROR: --router-name requires value" >&2; exit 1; }
        ARG_ROUTER_NAME="$2"; shift 2 ;;
      --agent-token)
        [ "$#" -ge 2 ] || { echo "ERROR: --agent-token requires value" >&2; exit 1; }
        ARG_AGENT_TOKEN="$2"; shift 2 ;;
      --poll-interval)
        [ "$#" -ge 2 ] || { echo "ERROR: --poll-interval requires value" >&2; exit 1; }
        ARG_POLL_INTERVAL="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        exit 1 ;;
    esac
  done
}

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r value || value=""
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf '%s' "$value"
}

value_or_ask() {
  value="$1"
  prompt="$2"
  default="$3"
  if [ -n "$value" ]; then
    printf '%s' "$value"
  else
    ask "$prompt" "$default"
  fi
}

detect_asset() {
  opkg_arch=""
  if command -v opkg >/dev/null 2>&1; then
    opkg_arch="$(opkg print-architecture 2>/dev/null | awk 'NR==1{print $2}')"
  fi
  kernel_arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$opkg_arch:$kernel_arch" in
    *aarch64*:*|*:aarch64|*:arm64) echo "xray-go-agent-linux-arm64" ;;
    *mipsel*:*|*mipsle*:*|*mipselsf*:*) echo "xray-go-agent-linux-mipsle" ;;
    *:mips|*mips*:mips) echo "xray-go-agent-linux-mips" ;;
    *)
      echo "ERROR: unsupported router architecture: entware=$opkg_arch kernel=$kernel_arch" >&2
      echo "Supported: arm64/aarch64, mipsel/mipselsf and mips" >&2
      exit 1
      ;;
  esac
}

fetch_file() {
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --retry-delay 3 -o "$out" "$url"
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
  echo "Installed binary: $BIN"
}

write_config() {
  mkdir -p /opt/etc/xray
  old_server="https://control.example.com"
  old_id="home"
  old_name="Дом"
  old_interval="10"
  old_token="${AGENT_TOKEN:-}"
  if [ -f "$CONF" ]; then
    . "$CONF" || true
    old_server="${SERVER_URL:-$old_server}"
    old_id="${ROUTER_ID:-$old_id}"
    old_name="${ROUTER_NAME:-$old_name}"
    old_token="${AGENT_TOKEN:-$old_token}"
    old_interval="${POLL_INTERVAL:-$old_interval}"
  fi

  server_url="$(value_or_ask "$ARG_SERVER_URL" 'VPS control server URL, example http://1.2.3.4:18090' "$old_server")"
  router_id="$(value_or_ask "$ARG_ROUTER_ID" 'Router ID, latin only, same as VPS config' "$old_id")"
  router_name="$(value_or_ask "$ARG_ROUTER_NAME" 'Router display name' "$old_name")"
  agent_token="$(value_or_ask "$ARG_AGENT_TOKEN" 'Agent token from VPS control bot' "$old_token")"
  poll_interval="$(value_or_ask "$ARG_POLL_INTERVAL" 'Poll interval seconds' "$old_interval")"

  if [ -z "$server_url" ] || [ -z "$router_id" ] || [ -z "$agent_token" ]; then
    echo "ERROR: SERVER_URL, ROUTER_ID and AGENT_TOKEN are required" >&2
    exit 1
  fi

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
  cat > "$INIT" <<'EOF'
#!/opt/bin/sh

ENABLED=yes
PROCS=xray-go-agent
ARGS="-config /opt/etc/xray/xray-go-agent.conf"
PREARGS=""
DESC="Xray Go Agent"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
  chmod +x "$INIT"
  touch "$LOG"
  echo "Installed init service: $INIT"
}

main() {
  parse_args "$@"
  mkdir -p /opt/etc/xray /opt/var/log
  install_binary
  write_config
  install_init
  if [ -x "$INIT" ]; then
    "$INIT" restart || "$INIT" start || true
  fi
  echo
  echo "Done. Checks:"
  echo "  $INIT status"
  echo "  tail -n 50 $LOG"
  echo "  /opt/bin/xray-go-agent -config $CONF -once"
}

main "$@"
