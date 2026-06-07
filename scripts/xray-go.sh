#!/bin/sh
set -e

XRAY_GO_VERSION="${XRAY_GO_VERSION:-0.1.0}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"

GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_CLEANUP_CMD="/opt/bin/vless-go-cleanup"
GO_RECOVER_CMD="/opt/bin/vless-go-recover"
GO_MANIFEST_CMD="/opt/bin/xray-go-manifest"
MANIFEST_FILE="${XRAY_GO_MANIFEST:-/opt/etc/xray/xray-go.manifest}"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
GO_INSTALLER_UPDATE_URL="${GO_INSTALLER_UPDATE_URL:-${RAW_BASE}/scripts/xray-go-installer-update.sh}"
DIRECT_FULL_UPDATE_CMD="/opt/bin/xray-go-direct-full"
DIRECT_FULL_UPDATE_URL="${DIRECT_FULL_UPDATE_URL:-${RAW_BASE}/scripts/xray-go-direct-full.sh}"
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
  xray-go manifest [summary|show|path]
  xray-go update [go|xray-core]
  xray-go update go --dry-run
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

Manifest mode:
  xray-go manifest
    Показывает безопасный summary /opt/etc/xray/xray-go.manifest.
  xray-go manifest show
    Показывает raw manifest без VLESS/subscription secrets.

Update mode:
  xray-go update go
    Если manifest INSTALL_MODE=direct — выполняет direct full update.
    Иначе использует старый opkg/IPK-compatible update path.
  xray-go update go --dry-run
    Для direct mode показывает план без изменений.

Низкоуровневые команды остаются доступны:
  failover-go
  vless-go-doctor
  vless-go-failover
  vless-go-history
  vless-go-cleanup
  vless-go-recover
  xray-go-manifest
  vless-go-xray-core-update
  xray-go-installer-update
  xray-go-direct-full
EOF
}

need_exec() {
    if [ ! -x "$1" ]; then
        echo "ОШИБКА: команда не найдена или не исполняемая: $1" >&2
        exit 127
    fi
}

fetch_script_to() {
    url="$1"
    dest="$2"
    label="$3"

    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$dest")" /opt/tmp
    tmp="${dest}.$$"
    echo "Refreshing $label..."
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$tmp" "$url" && sh -n "$tmp"; then
        chmod +x "$tmp"
        mv "$tmp" "$dest"
        chmod +x "$dest"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "WARN: failed to refresh $label from $url" >&2
    return 1
}

refresh_installer_update() {
    fetch_script_to "$GO_INSTALLER_UPDATE_URL" "$GO_INSTALLER_UPDATE_CMD" "xray-go-installer-update" || return 0
}

refresh_direct_full_update() {
    fetch_script_to "$DIRECT_FULL_UPDATE_URL" "$DIRECT_FULL_UPDATE_CMD" "xray-go-direct-full" || return 0
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

summary_seen() {
    grep -Eq 'OK=[0-9]+[[:space:]]+WARN=[0-9]+[[:space:]]+FAIL=[0-9]+' "$1" 2>/dev/null
}

run_doctor_json() {
    need_exec "$GO_DOCTOR_CMD"
    tmp="/tmp/xray-go-doctor-json.$$"
    doctor_rc="0"
    "$GO_DOCTOR_CMD" >"$tmp" 2>&1 || doctor_rc="$?"
    ok_count="$(counter_from_summary OK "$tmp")"
    warn_count="$(counter_from_summary WARN "$tmp")"
    fail_count="$(counter_from_summary FAIL "$tmp")"
    active_slot="$(active_slot_from_output "$tmp")"
    status="ok"
    exit_code="0"

    if [ "${fail_count:-0}" -gt 0 ]; then
        status="fail"
        exit_code="2"
    elif ! summary_seen "$tmp" && [ "$doctor_rc" -ne 0 ]; then
        status="fail"
        exit_code="$doctor_rc"
    elif [ "${warn_count:-0}" -gt 0 ] || [ "$doctor_rc" -ne 0 ]; then
        status="warn"
        exit_code="0"
    fi

    printf '{'
    printf '"schema":"xray-go.doctor.v1"'
    printf ',"ok":%s' "$( [ "$status" = "fail" ] && printf false || printf true )"
    printf ',"status":"%s"' "$status"
    printf ',"exit_code":%s' "$exit_code"
    printf ',"ok_count":%s' "$ok_count"
    printf ',"warn_count":%s' "$warn_count"
    printf ',"fail_count":%s' "$fail_count"
    printf ',"active_slot":"%s"' "$active_slot"
    printf ',"support_safe":true'
    printf ',"raw_output_included":false'
    printf '}
'
    rm -f "$tmp" 2>/dev/null || true
    exit "$exit_code"
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
            show_manifest_summary_safe || true
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

manifest_get_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

show_manifest_summary_fallback() {
    [ -s "$MANIFEST_FILE" ] || { echo "Manifest: not found ($MANIFEST_FILE)"; return 1; }
    echo "Manifest: $MANIFEST_FILE"
    echo "Install mode: $(manifest_get_value INSTALL_MODE)"
    echo "Edition: $(manifest_get_value EDITION)"
    echo "Version: $(manifest_get_value VERSION)"
    echo "Architecture: $(manifest_get_value ARCH)"
    echo "Channel: $(manifest_get_value CHANNEL)"
    echo "Source: $(manifest_get_value SOURCE)"
    echo "Binary: $(manifest_get_value BINARY_PATH)"
    echo "Binary sha256: $(manifest_get_value BINARY_SHA256)"
    echo "Modules: $(manifest_get_value MODULES)"
    echo "Installed at: $(manifest_get_value INSTALLED_AT)"
    echo "Last update at: $(manifest_get_value LAST_UPDATE_AT)"
}

show_manifest_summary_safe() {
    echo
    echo "== Manifest =="
    if [ -x "$GO_MANIFEST_CMD" ]; then
        "$GO_MANIFEST_CMD" summary
    else
        show_manifest_summary_fallback
    fi
}

run_manifest() {
    action="${1:-summary}"
    case "$action" in
        ""|summary|status)
            if [ -x "$GO_MANIFEST_CMD" ]; then "$GO_MANIFEST_CMD" summary; else show_manifest_summary_fallback; fi
            ;;
        show|cat)
            if [ -x "$GO_MANIFEST_CMD" ]; then "$GO_MANIFEST_CMD" show; else [ -s "$MANIFEST_FILE" ] && cat "$MANIFEST_FILE" || { echo "Manifest not found: $MANIFEST_FILE" >&2; exit 1; }; fi
            ;;
        path)
            if [ -x "$GO_MANIFEST_CMD" ]; then "$GO_MANIFEST_CMD" path; else echo "$MANIFEST_FILE"; fi
            ;;
        *)
            echo "Использование: xray-go manifest [summary|show|path]" >&2
            exit 2
            ;;
    esac
}

run_direct_go_update() {
    MODE="apply"
    case "${1:-}" in
        "") ;;
        --dry-run|--plan|dry-run|plan) MODE="dry-run"; shift ;;
        --apply|apply) MODE="apply"; shift ;;
        *) echo "Использование: xray-go update go [--dry-run]" >&2; exit 2 ;;
    esac
    [ "$#" -eq 0 ] || { echo "Использование: xray-go update go [--dry-run]" >&2; exit 2; }

    refresh_direct_full_update
    need_exec "$DIRECT_FULL_UPDATE_CMD"

    if [ "$MODE" = "dry-run" ]; then
        "$DIRECT_FULL_UPDATE_CMD" --dry-run --no-commands
    else
        echo "Direct install mode detected. Running direct full update."
        "$DIRECT_FULL_UPDATE_CMD" --apply --yes --no-commands
    fi
}

run_opkg_go_update() {
    refresh_installer_update
    need_exec "$GO_INSTALLER_UPDATE_CMD"
    "$GO_INSTALLER_UPDATE_CMD" --first
}

run_update() {
    TARGET="${1:-go}"
    case "$TARGET" in
        go|installer|edition)
            shift || true
            INSTALL_MODE="$(manifest_get_value INSTALL_MODE)"
            if [ "$INSTALL_MODE" = "direct" ]; then
                run_direct_go_update "$@"
            else
                [ "$#" -eq 0 ] || { echo "Использование: xray-go update go" >&2; exit 2; }
                run_opkg_go_update
            fi
            ;;
        xray-core|core|xray)
            shift || true
            [ "$#" -eq 0 ] || { echo "Использование: xray-go update xray-core" >&2; exit 2; }
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
    manifest)
        shift
        run_manifest "$@"
        ;;
    update)
        shift
        run_update "$@"
        ;;
    update-core)
        shift
        run_update xray-core
        ;;
    switch)
        shift
        need_exec "$GO_FAILOVER_CMD"
        "$GO_FAILOVER_CMD" switch "$@"
        ;;
    cleanup)
        shift
        need_exec "$GO_CLEANUP_CMD"
        "$GO_CLEANUP_CMD" "$@"
        ;;
    version|--version|-V)
        echo "$XRAY_GO_VERSION"
        ;;
    help|-h|--help|"")
        usage
        ;;
    *)
        echo "ОШИБКА: неизвестная команда: $1" >&2
        usage >&2
        exit 2
        ;;
esac
