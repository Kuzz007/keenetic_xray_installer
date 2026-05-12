#!/bin/sh
set -e

XRAY_GO_VERSION="${XRAY_GO_VERSION:-0.1.0}"

GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_CLEANUP_CMD="/opt/bin/vless-go-cleanup"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
MENU_CMD="/opt/bin/failover-go"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"

usage() {
    cat <<EOF
xray-go - единая команда управления Keenetic Xray Go edition

Использование:
  xray-go status
  xray-go doctor [--verbose]
  xray-go menu
  xray-go history [--follow]
  xray-go logs watchdog [--follow]
  xray-go logs history [--follow]
  xray-go update [go|xray-core]
  xray-go update-core
  xray-go switch primary|backup
  xray-go cleanup [--dry-run]
  xray-go version
  xray-go help

Низкоуровневые команды остаются доступны:
  failover-go
  vless-go-doctor
  vless-go-failover
  vless-go-history
  vless-go-cleanup
  vless-go-xray-core-update
  xray-go-installer-update
EOF
}

need_exec() {
    if [ ! -x "$1" ]; then
        echo "ОШИБКА: команда не найдена или не исполняемая: $1" >&2
        exit 127
    fi
}

show_status() {
    need_exec "$GO_FAILOVER_CMD"
    "$GO_FAILOVER_CMD" status || true
    echo
    if [ -x "$GO_WATCHDOG_CMD" ]; then
        "$GO_WATCHDOG_CMD" status || true
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: команда watchdog не найдена: $GO_WATCHDOG_CMD" >&2
    fi
}

show_history() {
    need_exec "$GO_HISTORY_CMD"
    case "${1:-}" in
        --follow|-f|follow) "$GO_HISTORY_CMD" follow ;;
        ""|tail) "$GO_HISTORY_CMD" tail 80 ;;
        *) echo "ОШИБКА: неизвестный аргумент history: $1" >&2; exit 2 ;;
    esac
}

show_logs() {
    KIND="${1:-}"
    FOLLOW="${2:-}"

    case "$KIND" in
        watchdog)
            if [ "$FOLLOW" = "--follow" ] || [ "$FOLLOW" = "-f" ] || [ "$FOLLOW" = "follow" ]; then
                [ -e "$WATCHDOG_LOG" ] || { echo "Журнал watchdog не найден: $WATCHDOG_LOG" >&2; exit 1; }
                tail -n 50 -f "$WATCHDOG_LOG"
            else
                [ -s "$WATCHDOG_LOG" ] && tail -n 80 "$WATCHDOG_LOG" || echo "Журнал watchdog пустой или отсутствует: $WATCHDOG_LOG"
            fi
            ;;
        history)
            if [ "$FOLLOW" = "--follow" ] || [ "$FOLLOW" = "-f" ] || [ "$FOLLOW" = "follow" ]; then
                show_history --follow
            else
                show_history
            fi
            ;;
        *)
            echo "Использование: xray-go logs watchdog|history [--follow]" >&2
            exit 2
            ;;
    esac
}

run_update() {
    TARGET="${1:-go}"
    case "$TARGET" in
        go|installer|edition)
            need_exec "$GO_INSTALLER_UPDATE_CMD"
            "$GO_INSTALLER_UPDATE_CMD" --first
            ;;
        xray-core|core|xray)
            need_exec "$XRAY_CORE_UPDATE_CMD"
            "$XRAY_CORE_UPDATE_CMD"
            ;;
        *)
            echo "Использование: xray-go update [go|xray-core]" >&2
            exit 2
            ;;
    esac
}

case "${1:-help}" in
    status)
        shift
        show_status "$@"
        ;;
    doctor)
        shift
        need_exec "$GO_DOCTOR_CMD"
        "$GO_DOCTOR_CMD" "$@"
        ;;
    menu)
        shift
        need_exec "$MENU_CMD"
        exec "$MENU_CMD" "$@"
        ;;
    history)
        shift
        show_history "$@"
        ;;
    logs|log)
        shift
        show_logs "$@"
        ;;
    update)
        shift
        run_update "$@"
        ;;
    update-core|update-xray-core)
        shift
        run_update xray-core "$@"
        ;;
    switch)
        shift
        SLOT="${1:-}"
        case "$SLOT" in
            primary|backup)
                need_exec "$GO_FAILOVER_CMD"
                "$GO_FAILOVER_CMD" switch "$SLOT"
                ;;
            *)
                echo "Использование: xray-go switch primary|backup" >&2
                exit 2
                ;;
        esac
        ;;
    cleanup)
        shift
        need_exec "$GO_CLEANUP_CMD"
        "$GO_CLEANUP_CMD" "$@"
        ;;
    version|--version|-v)
        echo "xray-go $XRAY_GO_VERSION"
        ;;
    help|--help|-h|"")
        usage
        ;;
    *)
        echo "ОШИБКА: неизвестная команда: $1" >&2
        echo >&2
        usage >&2
        exit 2
        ;;
esac
