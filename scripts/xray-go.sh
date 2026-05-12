#!/bin/sh
set -e

usage() {
    cat <<'USAGE'
Использование: xray-go COMMAND [ARGS...]

Единая точка входа для Full Go / Entware установки Xray на Keenetic.

Команды:
  status                 Показать статус failover и watchdog
  doctor                 Запустить vless-go-doctor
  menu                   Открыть интерактивное меню failover-go
  history [ARGS...]      Показать/управлять историей переключений
  cleanup [ARGS...]      Очистить место на /opt через vless-go-cleanup
  update [ARGS...]       Обновить Go edition через xray-go-installer-update
  update-core [ARGS...]  Обновить Xray-core через vless-go-xray-core-update
  switch primary|backup  Переключить активный профиль
  auto-update [ARGS...]  Управлять cron auto-update подписок
  logs                   Показать последние строки watchdog и switch history
  version                Показать версии Xray и Go resolver
  help                   Показать эту справку

Примеры:
  xray-go status
  xray-go doctor
  xray-go menu
  xray-go switch backup
  xray-go update
  xray-go update-core
USAGE
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
    if ! has_cmd "$1"; then
        echo "ОШИБКА: команда не найдена: $1" >&2
        return 127
    fi
}

run_status() {
    if has_cmd vless-go-failover; then
        echo "== Failover =="
        vless-go-failover status || true
        echo
    else
        echo "WARN: vless-go-failover не найден" >&2
    fi

    if has_cmd vless-go-watchdog; then
        echo "== Watchdog =="
        vless-go-watchdog status || true
    else
        echo "WARN: vless-go-watchdog не найден" >&2
    fi
}

run_logs() {
    WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
    HISTORY_LOG="/opt/var/log/vless-go-switch-history.log"

    echo "== Watchdog log =="
    if [ -s "$WATCHDOG_LOG" ]; then
        tail -n 60 "$WATCHDOG_LOG"
    else
        echo "Лог пустой или отсутствует: $WATCHDOG_LOG"
    fi

    echo
    echo "== Switch history =="
    if has_cmd vless-go-history; then
        vless-go-history tail 40 || true
    elif [ -s "$HISTORY_LOG" ]; then
        tail -n 40 "$HISTORY_LOG"
    else
        echo "История пустая или отсутствует: $HISTORY_LOG"
    fi
}

run_version() {
    echo "== Xray =="
    if has_cmd xray; then
        xray version | sed -n '1,2p'
    elif [ -x /opt/bin/xray ]; then
        /opt/bin/xray version | sed -n '1,2p'
    else
        echo "xray не найден"
    fi

    echo
    echo "== Go resolver =="
    if has_cmd xray-failover-go; then
        xray-failover-go -version 2>/dev/null || echo "xray-failover-go найден, но -version не поддерживается"
    elif [ -x /opt/bin/xray-failover-go ]; then
        /opt/bin/xray-failover-go -version 2>/dev/null || echo "xray-failover-go найден, но -version не поддерживается"
    else
        echo "xray-failover-go не найден"
    fi
}

CMD="${1:-help}"
[ "$#" -gt 0 ] && shift || true

case "$CMD" in
    status)
        run_status "$@"
        ;;
    doctor)
        require_cmd vless-go-doctor
        vless-go-doctor "$@"
        ;;
    menu)
        require_cmd failover-go
        failover-go "$@"
        ;;
    history)
        require_cmd vless-go-history
        if [ "$#" -eq 0 ]; then
            vless-go-history tail 80
        else
            vless-go-history "$@"
        fi
        ;;
    cleanup)
        require_cmd vless-go-cleanup
        vless-go-cleanup "$@"
        ;;
    update)
        require_cmd xray-go-installer-update
        if [ "$#" -eq 0 ]; then
            xray-go-installer-update --first
        else
            xray-go-installer-update "$@"
        fi
        ;;
    update-core|core-update)
        require_cmd vless-go-xray-core-update
        vless-go-xray-core-update "$@"
        ;;
    switch)
        SLOT="${1:-}"
        case "$SLOT" in
            primary|backup) shift; require_cmd vless-go-failover; vless-go-failover switch "$SLOT" "$@" ;;
            *) echo "ОШИБКА: укажи слот: primary или backup" >&2; exit 2 ;;
        esac
        ;;
    auto-update)
        require_cmd vless-go-auto-update
        vless-go-auto-update "$@"
        ;;
    logs)
        run_logs "$@"
        ;;
    version|versions)
        run_version "$@"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "ОШИБКА: неизвестная команда: $CMD" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
