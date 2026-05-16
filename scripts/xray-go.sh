#!/bin/sh
set -e

XRAY_GO_VERSION="${XRAY_GO_VERSION:-0.1.0}"

GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_CLEANUP_CMD="/opt/bin/vless-go-cleanup"
GO_RECOVER_CMD="/opt/bin/vless-go-recover"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
MENU_CMD="/opt/bin/failover-go"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"

usage() {
    cat <<EOF
xray-go - единая команда управления Keenetic Xray Go edition

Использование:
  xray-go status
  xray-go doctor [--support|--verbose|--json]
  xray-go menu
  xray-go history [--follow]
  xray-go logs watchdog [--follow]
  xray-go logs history [--follow]
  xray-go recover [status|enable-hourly|disable-hourly|proxy0|xray|watchdog]
  xray-go update [go|xray-core]
  xray-go update-core
  xray-go switch primary|backup
  xray-go cleanup [--dry-run]
  xray-go version
  xray-go help

Support mode:
  xray-go doctor --support
    Безопасный diagnostic output для отправки в поддержку.
    Не включает verbose detail log, который может содержать метаданные профиля/сервера.
    Включает safe summary hourly recovery без raw VLESS/subscription sources.

Machine-readable mode:
  xray-go doctor --json
    Выполняет обычный doctor и выводит краткий JSON summary без raw diagnostic output.

Recovery mode:
  xray-go recover
    Тихая self-healing проверка: если всё OK, ничего не делает.
    При сбое: Proxy0 refresh -> Xray restart -> watchdog restart -> failover.
  xray-go recover enable-hourly
    Включить ежечасную тихую cron-проверку.

Низкоуровневые команды остаются доступны:
  failover-go
  vless-go-doctor
  vless-go-failover
  vless-go-history
  vless-go-cleanup
  vless-go-recover
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

show_recovery_summary() {
    echo
    echo "== Recovery =="
    if [ -x "$GO_RECOVER_CMD" ]; then
        "$GO_RECOVER_CMD" status || true
    else
        echo "[WARN] recovery helper не найден: $GO_RECOVER_CMD"
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
    show_recovery_summary
}

json_escape() {
    sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r//g;s/\t/  /g'
}

counter_from_summary() {
    name="$1"
    file="$2"
    value="$(sed -n 's/.*'"$name"'=\([0-9][0-9]*\).*/\1/p' "$file" 2>/dev/null | tail -n 1)"
    [ -n "$value" ] || value="0"
    printf '%s' "$value"
}

active_slot_from_output() {
    sed -n 's/.*active slot:[[:space:]]*//p; s/.*active:[[:space:]]*//p; s/.*активный слот:[[:space:]]*//p' "$1" 2>/dev/null | tail -n 1 | json_escape
}

run_doctor_json() {
    need_exec "$GO_DOCTOR_CMD"
    tmp="/tmp/xray-go-doctor-json.$$"
    rc="0"
    "$GO_DOCTOR_CMD" >"$tmp" 2>&1 || rc="$?"
    ok_count="$(counter_from_summary OK "$tmp")"
    warn_count="$(counter_from_summary WARN "$tmp")"
    fail_count="$(counter_from_summary FAIL "$tmp")"
    active_slot="$(active_slot_from_output "$tmp")"
    status="ok"
    if [ "${fail_count:-0}" -gt 0 ] || [ "$rc" -ne 0 ]; then
        status="fail"
    elif [ "${warn_count:-0}" -gt 0 ]; then
        status="warn"
    fi
    printf '{'
    printf '"schema":"xray-go.doctor.v1"'
    printf ',"ok":%s' "$( [ "$status" = "fail" ] && printf false || printf true )"
    printf ',"status":"%s"' "$status"
    printf ',"exit_code":%s' "$rc"
    printf ',"ok_count":%s' "$ok_count"
    printf ',"warn_count":%s' "$warn_count"
    printf ',"fail_count":%s' "$fail_count"
    printf ',"active_slot":"%s"' "$active_slot"
    printf ',"support_safe":true'
    printf ',"raw_output_included":false'
    printf '}\n'
    rm -f "$tmp" 2>/dev/null || true
    exit "$rc"
}

run_doctor() {
    need_exec "$GO_DOCTOR_CMD"
    case "${1:-}" in
        --json|json)
            shift || true
            if [ "$#" -gt 0 ]; then
                echo "ОШИБКА: xray-go doctor --json не принимает дополнительные аргументы." >&2
                exit 2
            fi
            run_doctor_json
            ;;
        --support|support)
            shift || true
            if [ "$#" -gt 0 ]; then
                echo "ОШИБКА: xray-go doctor --support не принимает дополнительные аргументы." >&2
                exit 2
            fi
            echo "[INFO] Support mode: detail log не выводится; raw VLESS/subscription sources не печатаются."
            DOCTOR_RC="0"
            "$GO_DOCTOR_CMD" || DOCTOR_RC="$?"
            show_recovery_summary
            exit "$DOCTOR_RC"
            ;;
        *)
            "$GO_DOCTOR_CMD" "$@"
            ;;
    esac
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

run_recover() {
    need_exec "$GO_RECOVER_CMD"
    case "${1:-run}" in
        "") "$GO_RECOVER_CMD" run ;;
        status|enable-hourly|disable-hourly|proxy0|refresh-proxy0|xray|restart-xray|watchdog|restart-watchdog|run|check)
            "$GO_RECOVER_CMD" "$@"
            ;;
        *)
            echo "Использование: xray-go recover [status|enable-hourly|disable-hourly|proxy0|xray|watchdog]" >&2
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
        run_doctor "$@"
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
    recover)
        shift
        run_recover "$@"
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
