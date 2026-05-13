#!/bin/sh
set -eu

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-latest}"
BIN="${BIN:-/usr/local/bin/xray-go-control-server}"
CONF="${CONF:-/etc/xray-go-control-server.conf}"
SERVICE="${SERVICE:-/etc/systemd/system/xray-go-control-server.service}"
USER_NAME="${USER_NAME:-xraygo}"
LISTEN_PORT="${LISTEN_PORT:-18090}"
LISTEN_DEFAULT="${LISTEN_DEFAULT:-}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: command not found: $1" >&2
    exit 1
  }
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

random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  elif command -v dd >/dev/null 2>&1 && [ -r /dev/urandom ]; then
    dd if=/dev/urandom bs=24 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
  else
    date +%s | sha256sum | awk '{print $1}'
  fi
}

public_ipv4() {
  ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
    ip="$(wget -qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi
  case "$ip" in
    *[!0-9.]*|""|*.*.*.*.*) ip="" ;;
  esac
  printf '%s' "$ip"
}

listen_default() {
  if [ -n "$LISTEN_DEFAULT" ]; then
    printf '%s' "$LISTEN_DEFAULT"
    return
  fi
  ip="$(public_ipv4)"
  if [ -n "$ip" ]; then
    printf '%s:%s' "$ip" "$LISTEN_PORT"
  else
    printf ':%s' "$LISTEN_PORT"
  fi
}

detect_arch_asset() {
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    x86_64|amd64) echo "xray-go-control-server-linux-amd64" ;;
    aarch64|arm64) echo "xray-go-control-server-linux-arm64" ;;
    *)
      echo "ERROR: unsupported VPS architecture: $arch" >&2
      echo "Supported: amd64, arm64" >&2
      exit 1
      ;;
  esac
}

install_binary() {
  asset="$(detect_arch_asset)"
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  echo "Downloading: $url"
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --retry-delay 3 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    echo "ERROR: curl or wget required" >&2
    exit 1
  fi
  install -m 0755 "$tmp" "$BIN"
  rm -f "$tmp"
  echo "Installed binary: $BIN"
}

build_router_list() {
  echo >&2
  echo "Router registry setup" >&2
  echo "Format stored in config: router_id:agent_token:router_name" >&2
  routers=""
  while :; do
    rid="$(ask 'Router ID, latin only, example home. Empty to finish' '')"
    [ -z "$rid" ] && break
    rname="$(ask 'Router display name' "$rid")"
    token="$(ask 'Agent token, empty to auto-generate' '')"
    [ -z "$token" ] && token="$(random_token)"
    item="${rid}:${token}:${rname}"
    if [ -z "$routers" ]; then
      routers="$item"
    else
      routers="${routers},${item}"
    fi
    echo "Added router: $rid ($rname)" >&2
    echo "Agent token for $rid: $token" >&2
    echo "Save this token for the router agent installer." >&2
    echo >&2
  done
  if [ -z "$routers" ]; then
    token="$(random_token)"
    routers="home:${token}:Дом"
    echo "No routers entered. Added default router: home:***:Дом" >&2
    echo "Agent token for home: $token" >&2
  fi
  printf '%s' "$routers"
}

write_config() {
  listen="$(ask 'Listen address / external VPS address for router agents' "$(listen_default)")"
  bot_token="$(ask 'Telegram BOT_TOKEN from BotFather' '')"
  admin_id="$(ask 'Telegram ADMIN_USER_ID' '')"
  if [ -z "$bot_token" ] || [ -z "$admin_id" ]; then
    echo "ERROR: BOT_TOKEN and ADMIN_USER_ID are required" >&2
    exit 1
  fi
  routers="$(build_router_list)"
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
LISTEN="${listen}"
BOT_TOKEN="${bot_token}"
ADMIN_USER_ID="${admin_id}"
ROUTERS="${routers}"
EOF
  install -m 0660 "$tmp" "$CONF"
  rm -f "$tmp"
  echo "Created config: $CONF"
}

install_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; skipping service install."
    echo "Run manually: $BIN -config $CONF"
    return
  fi
  if ! id "$USER_NAME" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" 2>/dev/null || \
      useradd --system --no-create-home --shell /bin/false "$USER_NAME"
  fi
  chown root:"$USER_NAME" "$CONF"
  chmod 0660 "$CONF"
  cat > "$SERVICE" <<EOF
[Unit]
Description=Xray Go Control Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -config ${CONF}
Restart=always
RestartSec=5
User=${USER_NAME}
Group=${USER_NAME}
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${CONF}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xray-go-control-server.service
  systemctl restart xray-go-control-server.service
  echo "Service installed and started: xray-go-control-server"
}

main() {
  if [ "$(id -u)" != "0" ]; then
    echo "ERROR: run as root" >&2
    exit 1
  fi
  need_cmd uname
  install_binary
  write_config
  install_service
  echo
  echo "Done. Checks:"
  echo "  systemctl status xray-go-control-server --no-pager"
  echo "  curl -fsS http://127.0.0.1:${LISTEN_PORT}/health"
  echo
  echo "Telegram commands after router agent connects:"
  echo "  /routers"
  echo "  /status_home"
  echo "  /doctor_home"
  echo "  /add_router dacha Dacha"
}

main "$@"
