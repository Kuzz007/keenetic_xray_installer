#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
GO_WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
DOCTOR_CMD="/opt/bin/vless-go-doctor"
HISTORY_CMD="/opt/bin/vless-go-history"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
MENU_CMD="/opt/bin/failover-go"
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
PROXY_IFACE="Proxy0"
PROXY_UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
TMP_DIR="/opt/tmp"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_SELECTOR="$XRAY_DIR/vless-go.primary.selector"
BACKUP_SELECTOR="$XRAY_DIR/vless-go.backup.selector"
GO_EXPERIMENTAL_TAG="${GO_EXPERIMENTAL_TAG:-0.1.2-go-experimental}"
GO_BINARY_URL="${GO_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_EXPERIMENTAL_TAG}/xray-failover-go-linux-arm64}"
REPO_BRANCH="${REPO_BRANCH:-main}"
WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-$REPO_BRANCH}"
RAW_BASE="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}"
WATCHDOG_INSTALL_URL="${WATCHDOG_INSTALL_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/xray_vless_go_watchdog_install.sh}"
INSTALL_WATCHDOG="${INSTALL_WATCHDOG:-1}"
START_WATCHDOG="${START_WATCHDOG:-1}"
INSTALL_UPDATER="${INSTALL_UPDATER:-1}"
INSTALL_DOCTOR="${INSTALL_DOCTOR:-1}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"

read_tty() {
    prompt="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

copy_mode() {
    src="$1"
    dst="$2"
    mode="${3:-755}"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod "$mode" "$dst"
}

install_script() {
    src="$1"
    dst="$2"
    mode="${3:-755}"
    url="${RAW_BASE}/${src}"

    mkdir -p "$(dirname "$dst")" "$TMP_DIR"

    if [ -f "$src" ]; then
        copy_mode "$src" "$dst" "$mode"
        return 0
    fi

    tmp="$TMP_DIR/$(basename "$dst").$$"
    if ! curl -fL -o "$tmp" "$url"; then
        echo "ОШИБКА: не удалось установить $dst" >&2
        echo "Источник: $url" >&2
        rm -f "$tmp" 2>/dev/null || true
        exit 1
    fi
    copy_mode "$tmp" "$dst" "$mode"
    rm -f "$tmp" 2>/dev/null || true
}

ensure_cron() {
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log 2>/dev/null || true
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true

    if ! command -v crond >/dev/null 2>&1; then
        echo "Устанавливаю cron для опционального автообновления подписок..."
        opkg install cron >/dev/null 2>&1 \
            || opkg install cronie >/dev/null 2>&1 \
            || opkg install busybox-cron >/dev/null 2>&1 \
            || echo "ПРЕДУПРЕЖДЕНИЕ: cron установить не удалось. Для vless-go-auto-update enable может понадобиться ручная настройка cron."
    fi

    if command -v crond >/dev/null 2>&1 && ! ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then
        if [ -x /opt/etc/init.d/S10cron ]; then
            /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
        elif [ -x /opt/etc/init.d/S10crond ]; then
            /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
        else
            crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        fi
    fi
}

ensure_packages() {
    echo "[1/12] Проверка пакетов Entware..."
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ОШИБКА: opkg не найден. Для установки нужен Entware." >&2
        exit 1
    fi

    need_update="0"
    command -v curl >/dev/null 2>&1 || need_update="1"
    command -v crond >/dev/null 2>&1 || need_update="1"
    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        need_update="1"
    fi

    [ "$need_update" = "0" ] || opkg update

    if ! command -v curl >/dev/null 2>&1; then
        opkg install curl ca-bundle
    else
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        opkg install xray-core || opkg install xray
    fi

    ensure_cron
}

install_go_resolver() {
    echo "[2/12] Установка Go resolver/generator..."
    mkdir -p "$(dirname "$GO_RESOLVER")" "$TMP_DIR"

    if [ -x "$GO_RESOLVER" ]; then
        echo "Найден существующий бинарник: $GO_RESOLVER"
        return 0
    fi

    echo "Скачиваю Go binary: $GO_BINARY_URL"
    if ! curl -fL -o "$GO_RESOLVER" "$GO_BINARY_URL"; then
        echo "ОШИБКА: не удалось скачать Go binary: $GO_BINARY_URL" >&2
        echo "Ожидаемый GitHub Release asset: xray-failover-go-linux-arm64" >&2
        echo "Release tag: $GO_EXPERIMENTAL_TAG" >&2
        exit 1
    fi

    chmod +x "$GO_RESOLVER"
}

resolve_initial_config() {
    echo "[3/12] Разбор подписки и генерация Xray config..."
    "$GO_RESOLVER" \
        -input "$INPUT_VALUE" \
        -output "$XRAY_CONFIG" \
        -listen "$SOCKS_LISTEN" \
        -port "$SOCKS_PORT" \
        -profile "vless-out" \
        -first
}

install_helpers() {
    echo "[4/12] Установка helper-команд Go edition..."
    install_script scripts/vless-go-lock.sh "$LOCK_HELPER" 644
    install_script scripts/vless-go-update.sh "$GO_UPDATE_CMD" 755
    install_script scripts/vless-go-auto-update.sh "$GO_AUTO_UPDATE_CMD" 755
    install_script scripts/vless-go-failover.sh "$GO_FAILOVER_CMD" 755
    install_script scripts/vless-go-history.sh "$HISTORY_CMD" 755
    install_script scripts/vless-go-xray-core-update.sh "$XRAY_CORE_UPDATE_CMD" 755
    install_script scripts/failover-go.sh "$MENU_CMD" 755
}

install_updater() {
    echo "[5/12] Установка команды обновления Go edition..."
    if [ "$INSTALL_UPDATER" = "0" ]; then
        echo "Установка updater пропущена: INSTALL_UPDATER=0."
        return 0
    fi
    install_script scripts/xray-go-installer-update.sh "$GO_INSTALLER_UPDATE_CMD" 755
}

install_doctor() {
    echo "[6/12] Установка диагностики doctor..."
    if [ "$INSTALL_DOCTOR" = "0" ]; then
        echo "Установка doctor пропущена: INSTALL_DOCTOR=0."
        return 0
    fi
    install_script scripts/vless-go-doctor.sh "$DOCTOR_CMD" 755
}

create_xray_init() {
    echo "[7/12] Создание init-скрипта Xray..."
    mkdir -p "$(dirname "$INIT_SCRIPT")"
    cat > "$INIT_SCRIPT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
INIT
    chmod +x "$INIT_SCRIPT"
}

valid_auto_lan_ip() {
    awk 'NF && ($1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print; exit }'
}

detect_lan_router_ip() {
    if [ -n "$PROXY_UPSTREAM_HOST" ]; then
        echo "$PROXY_UPSTREAM_HOST"
        return 0
    fi

    {
        ndmc -c "show interface Home" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        ndmc -c "show interface Bridge0" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true
        for dev in Home home Bridge0 bridge0 br0 br-lan lan0 lan1; do
            ip -4 addr show dev "$dev" 2>/dev/null | awk '/inet / { gsub(/\/.*/, "", $2); print $2 }'
        done
        ip -4 route show scope link 2>/dev/null | awk '/ src / { for (i=1; i<=NF; i++) if ($i == "src") print $(i+1) }'
    } | valid_auto_lan_ip
}

configure_proxy0() {
    echo "[8/12] Настройка Proxy0..."
    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Настройте Proxy0 вручную на SOCKS5 $SOCKS_LISTEN:$SOCKS_PORT."
        return 0
    fi

    router_ip="$(detect_lan_router_ip | awk 'NF { print; exit }')"
    router_ip="${router_ip:-127.0.0.1}"

    ndmc -c "interface $PROXY_IFACE" || true
    ndmc -c "interface $PROXY_IFACE proxy protocol socks5" || true
    ndmc -c "interface $PROXY_IFACE proxy socks5-udp" || true
    ndmc -c "interface $PROXY_IFACE proxy upstream $router_ip $SOCKS_PORT" || true
    ndmc -c "interface $PROXY_IFACE description Xray-Go-Experimental" || true
    ndmc -c "interface $PROXY_IFACE no ip global" || true
    ndmc -c "interface $PROXY_IFACE up" || true
    ndmc -c "system configuration save" || true

    echo "$PROXY_IFACE -> SOCKS5 $router_ip:$SOCKS_PORT"
}

install_watchdog() {
    echo "[9/12] Установка watchdog и recovery support..."
    if [ "$INSTALL_WATCHDOG" = "0" ]; then
        echo "Установка watchdog пропущена: INSTALL_WATCHDOG=0."
        return 0
    fi

    mkdir -p "$TMP_DIR" "$XRAY_DIR"
    tmp_watchdog_installer="$TMP_DIR/xray_vless_go_watchdog_install.$$"
    trap 'rm -f "$tmp_watchdog_installer" 2>/dev/null || true' EXIT INT TERM

    if ! curl -fL -o "$tmp_watchdog_installer" "$WATCHDOG_INSTALL_URL"; then
        echo "ОШИБКА: не удалось скачать installer watchdog: $WATCHDOG_INSTALL_URL" >&2
        exit 1
    fi

    chmod +x "$tmp_watchdog_installer"
    WATCHDOG_BRANCH="$WATCHDOG_BRANCH" sh "$tmp_watchdog_installer"

    if [ "$AUTO_RECOVER_PRIMARY" = "1" ] && [ -f "$GO_WATCHDOG_CONF" ]; then
        sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' "$GO_WATCHDOG_CONF"
    fi
}

start_watchdog() {
    echo "[10/12] Запуск watchdog..."
    if [ "$START_WATCHDOG" = "1" ] && [ -x "$GO_WATCHDOG_INIT" ]; then
        "$GO_WATCHDOG_INIT" restart || "$GO_WATCHDOG_INIT" start || true
    else
        echo "Watchdog не запущен. Запуск вручную: $GO_WATCHDOG_INIT start"
    fi
}

start_xray() {
    echo "[11/12] Проверка и запуск Xray..."
    xray_bin="$(get_xray_bin)"
    if [ -z "$xray_bin" ]; then
        echo "ОШИБКА: бинарник xray не найден." >&2
        exit 1
    fi

    if ! "$xray_bin" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        "$xray_bin" test -config "$XRAY_CONFIG"
    fi

    "$INIT_SCRIPT" restart || "$INIT_SCRIPT" start
}

final_summary() {
    echo "[12/12] Итоговая проверка установки..."
    echo
    echo "Готово. Experimental Go edition установлена."
    echo
    echo "Основные файлы:"
    echo "  Xray config: $XRAY_CONFIG"
    echo "  Go resolver/generator: $GO_RESOLVER"
    echo "  Текущий источник: $SOURCE_STORE"
    echo "  Основной источник: $PRIMARY_STORE"
    echo "  Резервный источник: $BACKUP_STORE"
    echo "  Активный слот: $ACTIVE_STORE"
    echo "  Selector primary: $PRIMARY_SELECTOR"
    echo "  Selector backup: $BACKUP_SELECTOR"
    echo
    echo "Команды управления:"
    echo "  Меню: $MENU_CMD"
    echo "  Обновить активную подписку: $GO_UPDATE_CMD"
    echo "  Failover/switch: $GO_FAILOVER_CMD"
    echo "  Auto-update cron: $GO_AUTO_UPDATE_CMD"
    echo "  История переключений: $HISTORY_CMD"
    echo "  Диагностика: $DOCTOR_CMD"
    echo "  Обновить Go edition: $GO_INSTALLER_UPDATE_CMD"
    echo "  Обновить Xray-core: $XRAY_CORE_UPDATE_CMD"
    echo "  Watchdog: $GO_WATCHDOG_CMD"
    echo "  Watchdog init: $GO_WATCHDOG_INIT"
    echo "  Watchdog config: $GO_WATCHDOG_CONF"
    echo "  Общий lock helper: $LOCK_HELPER"
    echo
    echo "Полезные команды:"
    echo "  Открыть меню: failover-go"
    echo "  Запустить диагностику: vless-go-doctor"
    echo "  Включить ежедневное автообновление подписок: vless-go-auto-update enable"
    echo "  Обновить установленную Go edition без повторного ввода ссылок: xray-go-installer-update --first"
    echo "  Переключиться на backup: vless-go-failover switch backup"
    echo "  Статус watchdog: vless-go-watchdog status"
    echo
    echo "Если Proxy0 нужно привязать к конкретному IP роутера:"
    echo "  PROXY_UPSTREAM_HOST=192.168.1.1 sh xray_vless_failover_go.sh"
}

main() {
    echo "Experimental Xray VLESS Go installer для Keenetic"
    echo "Устанавливает Go resolver, Xray config, failover helpers, watchdog, doctor и меню управления."
    echo

    ensure_packages
    install_go_resolver

    mkdir -p "$XRAY_DIR"
    read_tty "Введите основной VLESS link или subscription URL: "
    INPUT_VALUE="$REPLY"
    if [ -z "$INPUT_VALUE" ]; then
        echo "ОШИБКА: пустое значение основного источника." >&2
        exit 1
    fi

    printf '%s\n' "$INPUT_VALUE" > "$SOURCE_STORE"
    printf '%s\n' "$INPUT_VALUE" > "$PRIMARY_STORE"
    printf '%s\n' primary > "$ACTIVE_STORE"
    printf '%s\n' first > "$PRIMARY_SELECTOR"
    chmod 600 "$SOURCE_STORE" "$PRIMARY_STORE" "$ACTIVE_STORE" "$PRIMARY_SELECTOR" 2>/dev/null || true

    read_tty "Введите резервный VLESS link или subscription URL (опционально, Enter чтобы пропустить): "
    BACKUP_VALUE="$REPLY"
    if [ -n "$BACKUP_VALUE" ]; then
        printf '%s\n' "$BACKUP_VALUE" > "$BACKUP_STORE"
        printf '%s\n' first > "$BACKUP_SELECTOR"
        chmod 600 "$BACKUP_STORE" "$BACKUP_SELECTOR" 2>/dev/null || true
        echo "Резервный источник сохранён: $BACKUP_STORE"
    else
        echo "Резервный источник пропущен. Добавить позже: vless-go-failover set-backup URL_OR_VLESS"
    fi

    resolve_initial_config
    install_helpers
    install_updater
    install_doctor
    create_xray_init
    configure_proxy0
    install_watchdog
    start_watchdog
    start_xray
    final_summary
}

main "$@"
