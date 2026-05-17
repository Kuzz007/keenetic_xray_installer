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
UPDATE_ONLY="${UPDATE_ONLY:-0}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"
ASSUME_YES="${ASSUME_YES:-0}"

usage() {
  cat <<'USAGE'
Usage: xray-go-control-server-install.sh [options]

Options:
  --update-only       Update binary/service and reuse existing config. Do not ask setup questions.
  --force-config      Recreate config interactively even when it already exists.
  --yes               Non-interactive update confirmation where possible.
  -h, --help          Show help.

Default behavior:
  - If config exists, it is reused and not rewritten.
  - If config is missing, the script asks initial setup questions.

Environment overrides:
  REPO=Kuzz007/keenetic_xray_installer
  TAG=latest
  BIN=/usr/local/bin/xray-go-control-server
  CONF=/etc/xray-go-control-server.conf
  SERVICE=/etc/systemd/system/xray-go-control-server.service
  USER_NAME=xraygo
  UPDATE_ONLY=1
  FORCE_CONFIG=1
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update-only|--repair-only|--no-config) UPDATE_ONLY="1"; shift ;;
    --force-config|--reconfigure) FORCE_CONFIG="1"; shift ;;
    -y|--yes) ASSUME_YES="1"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

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

config_value() {
  key="$1"
  [ -f "$CONF" ] || return 0
  sed -n "s/^${key}=//p" "$CONF" 2>/dev/null | sed -n '1p' | sed 's/^"//; s/"$//'
}

configured_listen() {
  value="$(config_value LISTEN)"
  [ -n "$value" ] || value="$(listen_default)"
  printf '%s' "$value"
}

health_url() {
  listen="$(configured_listen)"
  case "$listen" in
    :*) printf 'http://127.0.0.1%s/health' "$listen" ;;
    0.0.0.0:*) printf 'http://127.0.0.1:%s/health' "${listen##*:}" ;;
    \[::\]:*) printf 'http://127.0.0.1:%s/health' "${listen##*:}" ;;
    *) printf 'http://%s/health' "$listen" ;;
  esac
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
  if [ -f "$CONF" ]; then
    cp "$CONF" "${CONF}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  fi
  install -m 0660 "$tmp" "$CONF"
  rm -f "$tmp"
  echo "Created config: $CONF"
}

ensure_config() {
  if [ "$FORCE_CONFIG" = "1" ]; then
    echo "Force config mode: recreating $CONF"
    write_config
    return
  fi
  if [ -f "$CONF" ]; then
    echo "Existing config found, reusing without prompts: $CONF"
    return
  fi
  if [ "$UPDATE_ONLY" = "1" ]; then
    echo "ERROR: --update-only requested but config is missing: $CONF" >&2
    echo "Run without --update-only for initial setup." >&2
    exit 1
  fi
  write_config
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
  ensure_config
  install_service
  echo
  echo "Done. Checks:"
  echo "  systemctl status xray-go-control-server --no-pager"
  echo "  curl -fsS $(health_url)"
  echo
  if [ "$UPDATE_ONLY" = "1" ] || [ "$FORCE_CONFIG" != "1" ]; then
    echo "Config reuse: existing config was preserved unless --force-config was used."
  fi
  echo "Telegram commands after router agent connects:"
  echo "  /routers"
  echo "  /status_home"
  echo "  /doctor_home"
  echo "  /add_router dacha Dacha"
}

main "$@"
