#!/opt/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-latest}"
CONF="${CONF:-/opt/etc/xray/xray-go-agent.conf}"
BIN="${BIN:-/opt/bin/xray-go-agent}"
INIT="${INIT:-/opt/etc/init.d/S28xray-go-agent}"
LOG="${LOG:-/opt/var/log/xray-go-agent.log}"

ask() {
  prompt="$1"
  default="${2:-}"
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  IFS= read -r value || value=""
  if [ -z "$value" ]; then
    value="$default"
  fi
  printf '%s' "$value"
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
    *)
      echo "ERROR: unsupported router architecture: entware=$opkg_arch kernel=$kernel_arch" >&2
      echo "Supported: arm64/aarch64 and mipsel/mipselsf" >&2
      exit 1
      ;;
  esac
}

install_binary() {
  asset="$(detect_asset)"
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  mkdir -p "$(dirname "$BIN")"
  tmp="${BIN}.tmp.$$"
  echo "Downloading: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --retry-delay 3 -o "$tmp" "$url"
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
  old_server="https://control.example.com"
  old_id="home"
  old_name="Дом"
  old_interval="5"
  if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF" || true
    old_server="${SERVER_URL:-$old_server}"
    old_id="${ROUTER_ID:-$old_id}"
    old_name="${ROUTER_NAME:-$old_name}"
    old_interval="${POLL_INTERVAL:-$old_interval}"
  fi

  server_url="$(ask 'VPS control server URL, example http://1.2.3.4:18090' "$old_server")"
  router_id="$(ask 'Router ID, latin only, same as VPS config' "$old_id")"
  router_name="$(ask 'Router display name' "$old_name")"
  agent_token="$(ask 'Agent token from VPS installer' "${AGENT_TOKEN:-}")"
  poll_interval="$(ask 'Poll interval seconds' "$old_interval")"

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
