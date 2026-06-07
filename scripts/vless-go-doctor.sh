#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_SELECTOR="$XRAY_DIR/vless-go.primary.selector"
BACKUP_SELECTOR="$XRAY_DIR/vless-go.backup.selector"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
XRAY_BACKUP_DIR="$XRAY_DIR/backups"
MANIFEST_FILE="$XRAY_DIR/xray-go.manifest"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_DETAIL_LOG="/opt/var/log/vless-go-watchdog-detail.log"
AUTO_UPDATE_LOG="/opt/var/log/vless-go-auto-update.log"
HISTORY_LOG="/opt/var/log/vless-go-switch-history.log"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
PROXY_UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
VERBOSE="0"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose|-v) VERBOSE="1"; shift ;;
        -h|--help|help)
            echo "Использование: vless-go-doctor [--verbose]"
            echo ""
            echo "По умолчанию подробный detail log не печатается, потому что он может содержать метаданные профиля/сервера."
            echo "Используйте --verbose только для локальной отладки."
            exit 0
            ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1" >&2; echo "Использование: vless-go-doctor [--verbose]" >&2; exit 2 ;;
    esac
done

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
ok() { OK_COUNT=$((OK_COUNT + 1)); printf '[OK] %s\n' "$*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf '[WARN] %s\n' "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
read_first() { [ -s "$1" ] && sed -n '1p' "$1" || true; }

mask_source_type() {
    VALUE="$1"
    case "$VALUE" in
        vless://*) echo "vless link" ;;
        http://*|https://*) echo "subscription URL" ;;
        '') echo "пусто" ;;
        *) echo "пользовательский источник" ;;
    esac
}

check_file_present() {
    FILE="$1"
    LABEL="$2"
    if [ -s "$FILE" ]; then
        ok "$LABEL настроен ($(mask_source_type "$(read_first "$FILE")"))"
    else
        warn "$LABEL не настроен"
    fi
}

valid_selector() {
    VALUE="$1"
    case "$VALUE" in
        first) return 0 ;;
        index:[1-9]*[!0-9]*) return 1 ;;
        index:[1-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

check_selector() {
    FILE="$1"
    LABEL="$2"
    VALUE="$(read_first "$FILE")"
    if [ -z "$VALUE" ]; then
        warn "$LABEL selector отсутствует: $FILE"
        return 0
    fi
    if valid_selector "$VALUE"; then
        ok "$LABEL selector: $VALUE"
    else
        fail "$LABEL selector некорректен: $VALUE"
    fi
}

xray_bin() {
    if has_cmd xray; then command -v xray
    elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray
    elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray
    else echo ""
    fi
}

opkg_bin() {
    if has_cmd opkg; then command -v opkg
    elif [ -x /opt/bin/opkg ]; then echo /opt/bin/opkg
    else echo ""
    fi
}

detect_entware_arch() {
    OPKG_BIN="$(opkg_bin)"
    [ -n "$OPKG_BIN" ] || return 0
    "$OPKG_BIN" print-architecture 2>/dev/null | awk '
        $2 != "all" && ($3 + 0) >= max { arch = $2; max = $3 + 0 }
        END { if (arch != "") print arch }
    '
}

asset_name_for_arch() {
    ARCH="$1"
    case "$ARCH" in
        aarch64-3.10|aarch64*|arm64) echo "xray-failover-go-linux-arm64" ;;
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*|mipsel-3.4|mipsel-3.4_kn|mipselsf-k3.4|mipselsf-k3.4_kn) echo "xray-failover-go-linux-mipsle" ;;
        *) echo "" ;;
    esac
}

manifest_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

sha256_file() {
    file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    if has_cmd sha256sum; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif has_cmd openssl; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

create_xray_init() {
    [ -s "$XRAY_CONFIG" ] || return 1
    mkdir -p "$(dirname "$XRAY_INIT")"
    cat > "$XRAY_INIT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
INIT
    chmod +x "$XRAY_INIT"
    return 0
}

check_xray_init_status() {
    if [ ! -x "$XRAY_INIT" ]; then
        warn "init-скрипт Xray не найден: $XRAY_INIT; создаю"
        if create_xray_init; then ok "init-скрипт Xray создан: $XRAY_INIT"; else fail "не удалось создать init-скрипт Xray"; return 0; fi
    fi

    if "$XRAY_INIT" status >/tmp/vless-go-doctor.status.$$ 2>&1; then
        ok "статус init Xray: alive"
    else
        warn "статус init Xray не alive; пробую запустить"
        sed 's/^/  /' /tmp/vless-go-doctor.status.$$
        if "$XRAY_INIT" start >/tmp/vless-go-doctor.xray-start.$$ 2>&1 || "$XRAY_INIT" restart >/tmp/vless-go-doctor.xray-start.$$ 2>&1; then
            ok "команда запуска Xray выполнена"
            sleep 2
            if "$XRAY_INIT" status >/tmp/vless-go-doctor.status.$$ 2>&1; then ok "статус init Xray после восстановления: alive"; else warn "статус init Xray всё ещё не alive после восстановления"; sed 's/^/  /' /tmp/vless-go-doctor.status.$$; fi
        else
            warn "запуск Xray через init не удался"
            sed 's/^/  /' /tmp/vless-go-doctor.xray-start.$$
        fi
        rm -f /tmp/vless-go-doctor.xray-start.$$ 2>/dev/null || true
    fi
    rm -f /tmp/vless-go-doctor.status.$$ 2>/dev/null || true
}

valid_auto_lan_ip() {
    awk 'NF && ($1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print; exit }'
}

detect_lan_router_ip() {
    if [ -n "$PROXY_UPSTREAM_HOST" ]; then echo "$PROXY_UPSTREAM_HOST"; return 0; fi
    {
        ndmc -c "show interface Home" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        ndmc -c "show interface Bridge0" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        for dev in Home home Bridge0 bridge0 br0 br-lan lan0 lan1; do ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / { gsub(/\/.*/, "", $2); print $2 }'; done
        ip -4 route show scope link 2>/dev/null | awk '/ src / { for (i=1; i<=NF; i++) if ($i == "src") print $(i+1) }'
    } | valid_auto_lan_ip
}

proxy0_exists() { ndmc -c "show interface $PROXY_IFACE" >/tmp/vless-go-doctor.proxy0.$$ 2>&1; }
proxy0_running_config() {
    ndmc -c "show running-config" 2>/dev/null | awk -v iface="$PROXY_IFACE" '
        $1 == "interface" && $2 == iface { in_block = 1; print; next }
        in_block && $0 == "!" { print; exit }
        in_block { print }
    '
}
proxy0_has_socks5() {
    if grep -qi 'socks5' /tmp/vless-go-doctor.proxy0.$$ 2>/dev/null; then return 0; fi
    proxy0_running_config >/tmp/vless-go-doctor.proxy0-running.$$ 2>/dev/null || true
    grep -qi 'proxy protocol socks5' /tmp/vless-go-doctor.proxy0-running.$$ 2>/dev/null || return 1
    grep -qi "proxy upstream .* $SOCKS_PORT" /tmp/vless-go-doctor.proxy0-running.$$ 2>/dev/null || return 1
    return 0
}

apply_proxy0_settings() {
    router_ip="$(detect_lan_router_ip | awk 'NF { print; exit }')"
    router_ip="${router_ip:-127.0.0.1}"
    ndmc -c "interface $PROXY_IFACE" >/dev/null 2>&1 || return 1
    ndmc -c "interface $PROXY_IFACE proxy protocol socks5" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE proxy socks5-udp" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE proxy upstream $router_ip $SOCKS_PORT" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE description Xray-Go-Experimental" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE no ip global" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE up" >/dev/null 2>&1 || true
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
    echo "$PROXY_IFACE -> SOCKS5 $router_ip:$SOCKS_PORT"
    return 0
}

check_storage() {
    if df -k /opt >/tmp/vless-go-doctor.df.$$ 2>/dev/null; then
        awk 'NR==2 { total=$2; used=$3; avail=$4; pct=$5; printf "  /opt: всего=%.1f MB занято=%.1f MB свободно=%.1f MB use=%s\n", total/1024, used/1024, avail/1024, pct }' /tmp/vless-go-doctor.df.$$
        FREE_KB="$(awk 'NR==2 {print $4}' /tmp/vless-go-doctor.df.$$ 2>/dev/null)"
        if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 51200 ]; then warn "мало свободного места на /opt: меньше 50 MB"; else ok "свободного места на /opt достаточно"; fi
    else
        warn "не удалось прочитать использование диска /opt"
    fi
    rm -f /tmp/vless-go-doctor.df.$$ 2>/dev/null || true

    echo "-- топ использования /opt --"
    if du -k -d 2 /opt >/tmp/vless-go-doctor.du.$$ 2>/dev/null; then
        sort -n /tmp/vless-go-doctor.du.$$ | tail -n 12 | awk '{printf "  %.1f MB\t%s\n", $1/1024, $2}'
    elif du -k /opt >/tmp/vless-go-doctor.du.$$ 2>/dev/null; then
        sort -n /tmp/vless-go-doctor.du.$$ | tail -n 12 | awk '{printf "  %.1f MB\t%s\n", $1/1024, $2}'
    else
        echo "  недоступно"
    fi
    rm -f /tmp/vless-go-doctor.du.$$ 2>/dev/null || true

    if has_cmd vless-go-cleanup; then
        ok "cleanup helper найден: $(command -v vless-go-cleanup)"
        echo "  Предпросмотр очистки: vless-go-cleanup --dry-run"
        echo "  Запуск очистки: vless-go-cleanup"
    else
        warn "cleanup helper не найден: /opt/bin/vless-go-cleanup"
    fi
}

check_architecture() {
    OPKG_BIN="$(opkg_bin)"
    if [ -n "$OPKG_BIN" ]; then ok "opkg для определения архитектуры: $OPKG_BIN"; else fail "opkg не найден для определения архитектуры"; fi

    ENTWARE_ARCH="$(detect_entware_arch)"
    UNAME_ARCH="$(uname -m 2>/dev/null || echo unknown)"
    [ -n "$ENTWARE_ARCH" ] && ok "архитектура Entware: $ENTWARE_ARCH" || warn "архитектуру Entware не удалось определить через opkg print-architecture"
    [ -n "$UNAME_ARCH" ] && ok "архитектура ядра: $UNAME_ARCH" || warn "архитектуру ядра не удалось определить через uname -m"

    ARCH_FOR_ASSET="$ENTWARE_ARCH"
    [ -n "$ARCH_FOR_ASSET" ] || ARCH_FOR_ASSET="$UNAME_ARCH"
    EXPECTED_ASSET="$(asset_name_for_arch "$ARCH_FOR_ASSET")"
    if [ -n "$EXPECTED_ASSET" ]; then ok "ожидаемый asset Go resolver: $EXPECTED_ASSET"; else fail "неподдерживаемая архитектура для Go resolver asset: $ARCH_FOR_ASSET"; fi

    GO_BIN=""
    if has_cmd xray-failover-go; then GO_BIN="$(command -v xray-failover-go)"; elif [ -x /opt/bin/xray-failover-go ]; then GO_BIN="/opt/bin/xray-failover-go"; fi
    [ -n "$GO_BIN" ] || { fail "xray-failover-go не найден для проверки архитектуры"; return 0; }

    if has_cmd file; then
        FILE_OUT="$(file "$GO_BIN" 2>/dev/null || true)"
        [ -n "$FILE_OUT" ] && echo "  $FILE_OUT"
        if [ "$EXPECTED_ASSET" = "xray-failover-go-linux-arm64" ]; then
            if echo "$FILE_OUT" | grep -Eiq 'aarch64|ARM64|ARM aarch64'; then ok "архитектура Go resolver соответствует arm64 asset"; else warn "архитектура Go resolver может не соответствовать arm64 asset"; fi
        elif [ "$EXPECTED_ASSET" = "xray-failover-go-linux-mipsle" ]; then
            if echo "$FILE_OUT" | grep -Eiq '(LSB.*MIPS|MIPS.*(LSB|little-endian)|mipsle)'; then ok "архитектура Go resolver соответствует mipsle asset"; else warn "архитектура Go resolver может не соответствовать mipsle asset"; fi
        else
            warn "нельзя сравнить архитектуру Go resolver: ожидаемый asset неизвестен"
        fi
    else
        warn "команда file не найдена; ELF-архитектуру Go resolver проверить нельзя"
    fi
}

check_go_resolver() {
    if ! has_cmd xray-failover-go; then fail "xray-failover-go не найден"; return 0; fi
    VERSION="$(xray-failover-go -version 2>/dev/null || true)"
    if [ -n "$VERSION" ]; then ok "версия xray-failover-go: $VERSION"; else warn "xray-failover-go -version не сработал; бинарник может быть старым"; fi
    HELP="$(xray-failover-go -h 2>&1 || true)"
    for FLAG in -select-index -select-name -json -private -version; do
        if echo "$HELP" | grep -q -- "$FLAG"; then ok "xray-failover-go поддерживает $FLAG"; else fail "xray-failover-go не поддерживает $FLAG"; fi
    done
}

check_manifest() {
    if [ ! -s "$MANIFEST_FILE" ]; then
        warn "direct manifest не найден: $MANIFEST_FILE"
        return 0
    fi

    INSTALL_MODE="$(manifest_value INSTALL_MODE)"
    EDITION="$(manifest_value EDITION)"
    VERSION="$(manifest_value VERSION)"
    ARCH="$(manifest_value ARCH)"
    CHANNEL="$(manifest_value CHANNEL)"
    BINARY_PATH="$(manifest_value BINARY_PATH)"
    BINARY_SHA256="$(manifest_value BINARY_SHA256)"
    MODULES="$(manifest_value MODULES)"

    ok "manifest найден: $MANIFEST_FILE"
    [ -n "$INSTALL_MODE" ] && ok "manifest install mode: $INSTALL_MODE" || warn "manifest install mode не задан"
    [ -n "$EDITION" ] && ok "manifest edition: $EDITION" || warn "manifest edition не задан"
    [ -n "$VERSION" ] && ok "manifest version: $VERSION" || warn "manifest version не задан"
    [ -n "$ARCH" ] && ok "manifest arch: $ARCH" || warn "manifest arch не задан"
    [ -n "$CHANNEL" ] && echo "  channel: $CHANNEL"
    [ -n "$MODULES" ] && echo "  modules: $MODULES"

    if [ -n "$BINARY_PATH" ]; then
        if [ -x "$BINARY_PATH" ]; then
            ok "manifest binary executable: $BINARY_PATH"
        elif [ -e "$BINARY_PATH" ]; then
            warn "manifest binary найден, но не executable: $BINARY_PATH"
        else
            warn "manifest binary отсутствует: $BINARY_PATH"
        fi
    else
        warn "manifest binary path не задан"
    fi

    if [ -n "$BINARY_PATH" ] && [ -s "$BINARY_PATH" ]; then
        ACTUAL_SHA="$(sha256_file "$BINARY_PATH")"
        if [ -n "$ACTUAL_SHA" ] && [ -n "$BINARY_SHA256" ]; then
            if [ "$ACTUAL_SHA" = "$BINARY_SHA256" ]; then
                ok "manifest binary sha256 matches target"
            else
                fail "manifest binary sha256 mismatch"
                echo "  manifest: $BINARY_SHA256"
                echo "  actual:   $ACTUAL_SHA"
            fi
        elif [ -n "$BINARY_SHA256" ]; then
            warn "не удалось посчитать sha256 для manifest binary"
        else
            warn "manifest binary sha256 не задан"
        fi
    fi
}

check_init_status() {
    INIT="$1"
    LABEL="$2"
    if [ ! -x "$INIT" ]; then warn "$LABEL init-скрипт не найден: $INIT"; return 0; fi
    if "$INIT" status >/tmp/vless-go-doctor.status.$$ 2>&1; then ok "$LABEL init status: alive"; else warn "$LABEL init status не alive"; sed 's/^/  /' /tmp/vless-go-doctor.status.$$; fi
    rm -f /tmp/vless-go-doctor.status.$$ 2>/dev/null || true
}

check_socks_listener() {
    if has_cmd netstat && netstat -lnt 2>/dev/null | grep -E "(^|[.:])$SOCKS_PORT[[:space:]]" >/dev/null 2>&1; then ok "SOCKS listener найден на порту $SOCKS_PORT"; return 0; fi
    if has_cmd ss && ss -lnt 2>/dev/null | grep -E "(^|[.:])$SOCKS_PORT[[:space:]]" >/dev/null 2>&1; then ok "SOCKS listener найден на порту $SOCKS_PORT"; return 0; fi
    warn "SOCKS listener не найден на порту $SOCKS_PORT"
}

check_socks_health() {
    if ! has_cmd curl; then warn "curl не найден; SOCKS health-check невозможен"; return 0; fi
    if curl -fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$CHECK_URL" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then
        ok "SOCKS health-check OK через $CHECK_URL"
    else
        warn "SOCKS health-check не прошёл через $CHECK_URL"
        sed 's/^/  /' /tmp/vless-go-doctor.curl.$$
    fi
    rm -f /tmp/vless-go-doctor.curl.$$ 2>/dev/null || true
}

check_proxy0() {
    rm -f /tmp/vless-go-doctor.proxy0.$$ /tmp/vless-go-doctor.proxy0-running.$$ 2>/dev/null || true
    if ! has_cmd ndmc; then warn "ndmc не найден; проверить или создать $PROXY_IFACE нельзя"; return 0; fi
    if proxy0_exists; then
        ok "интерфейс $PROXY_IFACE существует"
        if proxy0_has_socks5; then
            ok "$PROXY_IFACE выглядит настроенным на SOCKS5"
        else
            warn "$PROXY_IFACE существует, но SOCKS5-настройки не найдены; пробую восстановить"
            if apply_proxy0_settings && proxy0_exists && proxy0_has_socks5; then ok "SOCKS5-настройки $PROXY_IFACE восстановлены"; else warn "команда восстановления $PROXY_IFACE выполнена, но SOCKS5-настройки всё ещё не видны"; fi
        fi
    else
        warn "интерфейс $PROXY_IFACE не найден; создаю"
        if apply_proxy0_settings; then
            if proxy0_exists; then ok "интерфейс $PROXY_IFACE создан"; else warn "команда создания $PROXY_IFACE выполнена, но интерфейс всё ещё не виден"; fi
        else
            fail "не удалось создать интерфейс $PROXY_IFACE"
        fi
    fi
    rm -f /tmp/vless-go-doctor.proxy0.$$ /tmp/vless-go-doctor.proxy0-running.$$ 2>/dev/null || true
}

show_watchdog_summary() {
    if has_cmd vless-go-watchdog; then vless-go-watchdog status 2>/dev/null | sed 's/^/  /'; else warn "команда vless-go-watchdog не найдена"; fi
}

show_tail_safe() {
    FILE="$1"
    LABEL="$2"
    if [ -s "$FILE" ]; then
        echo "-- $LABEL --"
        tail -n 20 "$FILE" 2>/dev/null | sed 's/^/  /'
    else
        echo "-- $LABEL: пусто или отсутствует --"
    fi
}

check_cron_auto_update() {
    if [ ! -s "$CRON_FILE" ]; then ok "cron-файл пустой или отсутствует; auto-update отключён"; return 0; fi
    LINES="$(grep 'vless-go-auto-update' "$CRON_FILE" 2>/dev/null || true)"
    if [ -z "$LINES" ]; then ok "cron-запись auto-update не установлена"; return 0; fi
    if echo "$LINES" | grep -- '--first' >/dev/null 2>&1; then warn "cron auto-update всё ещё содержит legacy --first"; echo "$LINES" | sed 's/^/  /'; return 0; fi
    if echo "$LINES" | grep '/opt/bin/vless-go-auto-update run' >/dev/null 2>&1; then ok "cron auto-update использует selector-aware runner"; echo "$LINES" | sed 's/^/  /'; else warn "cron-запись auto-update найдена, но формат runner неожиданный"; echo "$LINES" | sed 's/^/  /'; fi
}

check_backups() {
    if [ ! -d "$XRAY_BACKUP_DIR" ]; then warn "директория backup Xray отсутствует: $XRAY_BACKUP_DIR"; return 0; fi
    COUNT="$(find "$XRAY_BACKUP_DIR" -type f -name 'xray.*.bak' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${COUNT:-0}" -gt 0 ]; then ok "backup-бинарники Xray найдены: $COUNT"; find "$XRAY_BACKUP_DIR" -type f -name 'xray.*.bak' 2>/dev/null | tail -n 3 | sed 's/^/  /'; else warn "backup-бинарники Xray не найдены в $XRAY_BACKUP_DIR"; fi
}

check_history() {
    if has_cmd vless-go-history; then
        ok "vless-go-history найден: $(command -v vless-go-history)"
        if vless-go-history path >/tmp/vless-go-doctor.history-path.$$ 2>/dev/null; then PATH_VALUE="$(cat /tmp/vless-go-doctor.history-path.$$)"; ok "путь истории переключений: $PATH_VALUE"; else warn "vless-go-history path вернул ошибку"; fi
        rm -f /tmp/vless-go-doctor.history-path.$$ 2>/dev/null || true
    else
        warn "команда vless-go-history не найдена"
    fi
    if [ -s "$HISTORY_LOG" ]; then
        COUNT="$(wc -l < "$HISTORY_LOG" 2>/dev/null | tr -d ' ')"
        ok "записей истории переключений: ${COUNT:-0}"
        show_tail_safe "$HISTORY_LOG" "история переключений"
    else
        info "лог истории переключений пустой или отсутствует: $HISTORY_LOG"
    fi
}

section "Команды"
for CMD in opkg curl xray xray-failover-go vless-go-update vless-go-failover vless-go-watchdog vless-go-auto-update vless-go-xray-core-update vless-go-history vless-go-cleanup xray-go-installer-update failover-go; do
    if has_cmd "$CMD"; then ok "$CMD найден: $(command -v "$CMD")"; else fail "$CMD не найден"; fi
done

section "Накопитель"
check_storage

section "Архитектура"
check_architecture

section "Go resolver"
check_go_resolver

section "Manifest"
check_manifest

section "Зависимости updater"
for CMD in python3 unzip; do
    if has_cmd "$CMD"; then ok "$CMD найден: $(command -v "$CMD")"; else warn "$CMD не найден; vless-go-xray-core-update может установить его через opkg при необходимости"; fi
done
if has_cmd vless-go-xray-core-update; then
    if vless-go-xray-core-update --help >/tmp/vless-go-doctor.corehelp.$$ 2>&1; then ok "help Xray-core updater работает"; else warn "help Xray-core updater вернул ненулевой код"; sed 's/^/  /' /tmp/vless-go-doctor.corehelp.$$; fi
    rm -f /tmp/vless-go-doctor.corehelp.$$ 2>/dev/null || true
fi

section "Сохранённое состояние"
check_file_present "$SOURCE_STORE" "текущий источник"
check_file_present "$PRIMARY_STORE" "основной источник"
check_file_present "$BACKUP_STORE" "резервный источник"
ACTIVE="$(read_first "$ACTIVE_STORE")"
case "$ACTIVE" in
    primary|backup) ok "активный слот: $ACTIVE" ;;
    '') warn "активный слот не задан" ;;
    *) fail "активный слот некорректен: $ACTIVE" ;;
esac
check_selector "$PRIMARY_SELECTOR" "primary"
check_selector "$BACKUP_SELECTOR" "backup"
[ -s "$WATCHDOG_CONF" ] && ok "config watchdog найден: $WATCHDOG_CONF" || warn "config watchdog отсутствует: $WATCHDOG_CONF"

section "Xray"
XRAY_BIN="$(xray_bin)"
if [ -n "$XRAY_BIN" ]; then
    ok "xray binary: $XRAY_BIN"
    XRAY_VERSION="$($XRAY_BIN version 2>/dev/null | sed -n '1p')"
    [ -n "$XRAY_VERSION" ] && ok "версия Xray: $XRAY_VERSION" || warn "не удалось прочитать версию Xray"
    if [ -s "$XRAY_CONFIG" ]; then
        ok "config Xray найден: $XRAY_CONFIG"
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/tmp/vless-go-doctor.xray.$$ 2>&1; then ok "валидация config Xray OK"; else fail "валидация config Xray не прошла"; sed 's/^/  /' /tmp/vless-go-doctor.xray.$$; fi
        rm -f /tmp/vless-go-doctor.xray.$$ 2>/dev/null || true
    else
        fail "config Xray отсутствует: $XRAY_CONFIG"
    fi
else
    fail "xray binary не найден"
fi
check_backups
check_xray_init_status
check_socks_listener
check_socks_health

section "Proxy0"
check_proxy0

section "Auto-update"
if has_cmd vless-go-auto-update; then vless-go-auto-update status 2>/dev/null | sed 's/^/  /'; fi
check_cron_auto_update
[ -s "$AUTO_UPDATE_LOG" ] && show_tail_safe "$AUTO_UPDATE_LOG" "лог auto-update" || info "лог auto-update пустой или отсутствует: $AUTO_UPDATE_LOG"

section "Watchdog"
check_init_status "$WATCHDOG_INIT" "VLESS Go watchdog"
show_watchdog_summary

section "История переключений"
check_history

section "Логи"
show_tail_safe "$WATCHDOG_LOG" "основной лог watchdog"
if [ "$VERBOSE" = "1" ]; then
    echo "-- detail log watchdog --"
    echo "  ПРЕДУПРЕЖДЕНИЕ: подробный detail log может содержать метаданные профиля/сервера."
    show_tail_safe "$WATCHDOG_DETAIL_LOG" "detail log watchdog"
else
    echo "-- detail log watchdog пропущен --"
    echo "  Используйте: vless-go-doctor --verbose"
fi

section "Итог"
printf 'OK=%s WARN=%s FAIL=%s\n' "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
[ "$FAIL_COUNT" -gt 0 ] && exit 2
exit 0
