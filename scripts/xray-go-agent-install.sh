#!/opt/bin/sh
set -eu

# Установщик агента управления.
#
# Важно: агент НЕ ставит minimal_go/full_go и НЕ меняет профиль Xray.
# Он только подключает роутер к control-server/боту и выполняет разрешённые
# команды управления: статус, переключение слота, подписка/source, recovery,
# логи, update scripts/update agent.

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
xray-go-agent-install — установка агента управления роутером

Использование:
  xray-go-agent-install [options]

Опции:
  --server-url URL       URL control-server/VPS, пример http://1.2.3.4:18090
  --router-id ID         ID роутера из бота/control-server, латиница/цифры/_/-
  --router-name NAME     Отображаемое имя роутера
  --agent-token TOKEN    Токен агента из бота/control-server
  --poll-interval SEC    Интервал опроса сервера в секундах, по умолчанию 10
  -h, --help             Показать справку

Если обязательные опции не заданы, установщик спросит их интерактивно.

Важно:
  Этот скрипт ставит только агент управления.
  Он НЕ ставит minimal_go/full_go и НЕ меняет профиль Xray.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --server-url)
        [ "$#" -ge 2 ] || { echo "ОШИБКА: --server-url требует значение" >&2; exit 1; }
        ARG_SERVER_URL="$2"; shift 2 ;;
      --router-id)
        [ "$#" -ge 2 ] || { echo "ОШИБКА: --router-id требует значение" >&2; exit 1; }
        ARG_ROUTER_ID="$2"; shift 2 ;;
      --router-name)
        [ "$#" -ge 2 ] || { echo "ОШИБКА: --router-name требует значение" >&2; exit 1; }
        ARG_ROUTER_NAME="$2"; shift 2 ;;
      --agent-token)
        [ "$#" -ge 2 ] || { echo "ОШИБКА: --agent-token требует значение" >&2; exit 1; }
        ARG_AGENT_TOKEN="$2"; shift 2 ;;
      --poll-interval)
        [ "$#" -ge 2 ] || { echo "ОШИБКА: --poll-interval требует значение" >&2; exit 1; }
        ARG_POLL_INTERVAL="$2"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        echo "ОШИБКА: неизвестный аргумент: $1" >&2
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
      echo "ОШИБКА: неподдерживаемая архитектура роутера: entware=$opkg_arch kernel=$kernel_arch" >&2
      echo "Поддерживаются: arm64/aarch64, mipsel/mipselsf и mips" >&2
      exit 1
      ;;
  esac
}

install_binary() {
  asset="$(detect_asset)"
  url="https://github.com/${REPO}/releases/download/${TAG}/${asset}"
  mkdir -p "$(dirname "$BIN")"
  tmp="${BIN}.tmp.$$"
  echo "Скачиваю агент: $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --retry-delay 3 -o "$tmp" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$url"
  else
    echo "ОШИБКА: нужен curl или wget" >&2
    exit 1
  fi
  chmod +x "$tmp"
  mv "$tmp" "$BIN"
  echo "Агент установлен: $BIN"
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

  server_url="$(value_or_ask "$ARG_SERVER_URL" 'URL control-server/VPS, пример http://1.2.3.4:18090' "$old_server")"
  router_id="$(value_or_ask "$ARG_ROUTER_ID" 'ID роутера из бота/control-server, латиница/цифры/_/-' "$old_id")"
  router_name="$(value_or_ask "$ARG_ROUTER_NAME" 'Имя роутера в боте' "$old_name")"
  agent_token="$(value_or_ask "$ARG_AGENT_TOKEN" 'Токен агента из бота/control-server' "$old_token")"
  poll_interval="$(value_or_ask "$ARG_POLL_INTERVAL" 'Интервал опроса сервера, секунд' "$old_interval")"

  if [ -z "$server_url" ] || [ -z "$router_id" ] || [ -z "$agent_token" ]; then
    echo "ОШИБКА: SERVER_URL, ROUTER_ID и AGENT_TOKEN обязательны" >&2
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
  echo "Конфиг агента создан: $CONF"
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
  echo "Init-сервис агента установлен: $INIT"
}

main() {
  parse_args "$@"
  mkdir -p /opt/etc/xray /opt/var/log
  echo "== Установка агента управления =="
  echo "Профиль Xray не меняется. Агент только подключает роутер к боту/control-server."
  install_binary
  write_config
  install_init
  if [ -x "$INIT" ]; then
    "$INIT" restart || "$INIT" start || true
  fi
  echo
  echo "Готово. Проверки:"
  echo "  $INIT status"
  echo "  tail -n 50 $LOG"
  echo "  /opt/bin/xray-go-agent -config $CONF -once"
}

main "$@"
