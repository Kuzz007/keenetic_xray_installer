#!/bin/sh
set -e

XRAY_GO_VERSION="${XRAY_GO_VERSION:-0.1.0}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"

GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_DOCTOR_SUMMARY_CMD="/opt/bin/vless-go-doctor-summary"
GO_DOCTOR_SUMMARY_URL="${GO_DOCTOR_SUMMARY_URL:-${RAW_BASE}/scripts/vless-go-doctor-summary.sh}"
GO_PRIVACY_CHECK_CMD="/opt/bin/vless-go-privacy-check"
GO_PRIVACY_CHECK_URL="${GO_PRIVACY_CHECK_URL:-${RAW_BASE}/scripts/vless-go-privacy-check.sh}"
GO_SAFETY_CHECK_CMD="/opt/bin/xray-go-safety-check"
GO_SAFETY_CHECK_URL="${GO_SAFETY_CHECK_URL:-${RAW_BASE}/scripts/xray-go-safety-check.sh}"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_CLEANUP_CMD="/opt/bin/vless-go-cleanup"
GO_RECOVER_CMD="/opt/bin/vless-go-recover"
GO_MANIFEST_CMD="/opt/bin/xray-go-manifest"
MANIFEST_FILE="${XRAY_GO_MANIFEST:-/opt/etc/xray/xray-go.manifest}"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"
GO_INSTALLER_UPDATE_URL="${GO_INSTALLER_UPDATE_URL:-${RAW_BASE}/scripts/xray-go-installer-update.sh}"
DIRECT_FULL_UPDATE_CMD="/opt/bin/xray-go-direct-full"
DIRECT_FULL_UPDATE_URL="${DIRECT_FULL_UPDATE_URL:-${RAW_BASE}/scripts/xray-go-direct-full.sh}"
DIRECT_UNINSTALL_CMD="/opt/bin/xray-go-direct-uninstall"
DIRECT_UNINSTALL_URL="${DIRECT_UNINSTALL_URL:-${RAW_BASE}/scripts/xray-go-direct-uninstall.sh}"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
XRAY_CORE_UPDATE_URL="${XRAY_CORE_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-xray-core-update.sh}"
MENU_CMD="/opt/bin/failover-go"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"

usage() {
    cat <<EOF
xray-go - единая команда управления Keenetic Xray Go edition

Использование:
  xray-go status
  xray-go summary
  xray-go doctor [--support|--summary|--verbose|--json]
  xray-go privacy-check
  xray-go safety-check
  xray-go menu
  xray-go history [--follow]
  xray-go logs watchdog [--follow]
  xray-go logs history [--follow]
  xray-go recover [status|enable-hourly|disable-hourly|proxy0|xray|watchdog]
  xray-go manifest [summary|show|path]
  xray-go update [go|xray-core]
  xray-go update go --dry-run
  xray-go update xray-core --dry-run
  xray-go update-core [--dry-run]
  xray-go switch primary|backup
  xray-go cleanup [--dry-run]
  xray-go uninstall --dry-run
  xray-go version
  xray-go help

Summary mode:
  xray-go summary
  xray-go doctor --summary
    Компактный read-only summary без raw VLESS/subscription sources.

Privacy mode:
  xray-go privacy-check
    Read-only scanner для diagnostic/support output. Не печатает найденные значения.

Safety mode:
  xray-go safety-check
    Read-only rollback boundary check для direct-install рабочих файлов.

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
  xray-go update xray-core --dry-run
    Read-only проверка Xray-core update target без скачивания и без restart.
  xray-go update xray-core [--channel stable|latest|prerelease] [--tag vX.Y.Z] [--yes] [--no-restart]
    Обновляет только Xray-core через vless-go-xray-core-update. Direct-install layer не меняется.

Uninstall mode:
  xray-go uninstall --dry-run
    Для direct mode показывает план удаления/очистки без изменений.
    На первом этапе это только read-only planner.

Version mode:
  xray-go version
    Показывает wrapper version, direct manifest summary, Go resolver version/sha256 и helper paths.

Низкоуровневые команды остаются доступны:
  failover-go
  vless-go-doctor
  vless-go-doctor-summary
  vless-go-privacy-check
  xray-go-safety-check
  vless-go-failover
  vless-go-history
  vless-go-cleanup
  vless-go-recover
  xray-go-manifest
  vless-go-xray-core-update
  xray-go-installer-update
  xray-go-direct-full
  xray-go-direct-uninstall
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

refresh_installer_update() { fetch_script_to "$GO_INSTALLER_UPDATE_URL" "$GO_INSTALLER_UPDATE_CMD" "xray-go-installer-update" || return 0; }
refresh_direct_full_update() { fetch_script_to "$DIRECT_FULL_UPDATE_URL" "$DIRECT_FULL_UPDATE_CMD" "xray-go-direct-full" || return 0; }
refresh_direct_uninstall() { fetch_script_to "$DIRECT_UNINSTALL_URL" "$DIRECT_UNINSTALL_CMD" "xray-go-direct-uninstall" || return 0; }
refresh_doctor_summary() { fetch_script_to "$GO_DOCTOR_SUMMARY_URL" "$GO_DOCTOR_SUMMARY_CMD" "vless-go-doctor-summary" || return 0; }
refresh_privacy_check() { fetch_script_to "$GO_PRIVACY_CHECK_URL" "$GO_PRIVACY_CHECK_CMD" "vless-go-privacy-check" || return 0; }
refresh_safety_check() { fetch_script_to "$GO_SAFETY_CHECK_URL" "$GO_SAFETY_CHECK_CMD" "xray-go-safety-check" || return 0; }
refresh_xray_core_update() { fetch_script_to "$XRAY_CORE_UPDATE_URL" "$XRAY_CORE_UPDATE_CMD" "vless-go-xray-core-update" || return 0; }

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

json_escape() { sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r//g;s/\t/  /g'; }

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

summary_seen() { grep -Eq 'OK=[0-9]+[[:space:]]+WARN=[0-9]+[[:space:]]+FAIL=[0-9]+' "$1" 2>/dev/null; }

sha256_file() {
    file="$1"
    [ -s "$file" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        return 1
    fi
}

run_summary() {
    [ "$#" -eq 0 ] || { echo "Использование: xray-go summary" >&2; exit 2; }
    refresh_doctor_summary
    need_exec "$GO_DOCTOR_SUMMARY_CMD"
    "$GO_DOCTOR_SUMMARY_CMD"
}

run_privacy_check() {
    [ "$#" -eq 0 ] || { echo "Использование: xray-go privacy-check" >&2; exit 2; }
    refresh_privacy_check
    need_exec "$GO_PRIVACY_CHECK_CMD"
    "$GO_PRIVACY_CHECK_CMD"
}

run_safety_check() {
    [ "$#" -eq 0 ] || { echo "Использование: xray-go safety-check" >&2; exit 2; }
    refresh_safety_check
    need_exec "$GO_SAFETY_CHECK_CMD"
    "$GO_SAFETY_CHECK_CMD"
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
    printf '}\n'
    rm -f "$tmp" 2>/dev/null || true
    exit "$exit_code"
}

run_doctor() {
    need_exec "$GO_DOCTOR_CMD"
    case "${1:-}" in
        --json|json)
            shift || true
            [ "$#" -eq 0 ] || { echo "ОШИБКА: xray-go doctor --json не принимает дополнительные аргументы." >&2; exit 2; }
            run_doctor_json
            ;;
        --summary|summary)
            shift || true
            [ "$#" -eq 0 ] || { echo "ОШИБКА: xray-go doctor --summary не принимает дополнительные аргументы." >&2; exit 2; }
            run_summary
            ;;
        --support|support)
            shift || true
            [ "$#" -eq 0 ] || { echo "ОШИБКА: xray-go doctor --support не принимает дополнительные аргументы." >&2; exit 2; }
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
        *) echo "Использование: xray-go logs watchdog|history [--follow]" >&2; exit 2 ;;
    esac
}

run_recover() {
    need_exec "$GO_RECOVER_CMD"
    case "${1:-run}" in
        "") "$GO_RECOVER_CMD" run ;;
        status|enable-hourly|disable-hourly|proxy0|refresh-proxy0|xray|restart-xray|watchdog|restart-watchdog|run|check)
            "$GO_RECOVER_CMD" "$@"
            ;;
        *) echo "Использование: xray-go recover [status|enable-hourly|disable-hourly|proxy0|xray|watchdog]" >&2; exit 2 ;;
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
        *) echo "Использование: xray-go manifest [summary|show|path]" >&2; exit 2 ;;
    esac
}

run_version() {
    [ "$#" -eq 0 ] || { echo "Использование: xray-go version" >&2; exit 2; }

    echo "xray-go wrapper version: $XRAY_GO_VERSION"
    echo "Repository branch: $REPO_BRANCH"

    echo
    echo "== Manifest summary =="
    if [ -s "$MANIFEST_FILE" ]; then
        if [ -x "$GO_MANIFEST_CMD" ]; then
            "$GO_MANIFEST_CMD" summary || show_manifest_summary_fallback || true
        else
            show_manifest_summary_fallback || true
        fi
    else
        echo "Manifest: not found ($MANIFEST_FILE)"
    fi

    echo
    echo "== Go resolver =="
    resolver_path="$(manifest_get_value BINARY_PATH)"
    [ -n "$resolver_path" ] || resolver_path="/opt/bin/xray-failover-go"
    echo "Path: $resolver_path"
    if [ -x "$resolver_path" ]; then
        resolver_version="$($resolver_path -version 2>/dev/null || true)"
        [ -n "$resolver_version" ] || resolver_version="unknown"
        echo "Version: $resolver_version"
        resolver_sha="$(sha256_file "$resolver_path" 2>/dev/null || true)"
        manifest_sha="$(manifest_get_value BINARY_SHA256)"
        echo "Sha256: ${resolver_sha:-unknown}"
        if [ -n "$manifest_sha" ]; then
            if [ "$resolver_sha" = "$manifest_sha" ]; then
                echo "Manifest sha256 match: yes"
            else
                echo "Manifest sha256 match: no"
                echo "Manifest sha256: $manifest_sha"
            fi
        fi
    else
        echo "Status: missing or not executable"
    fi

    echo
    echo "== Helper paths =="
    for helper in \
        "$GO_FAILOVER_CMD" \
        "$GO_DOCTOR_CMD" \
        "$GO_DOCTOR_SUMMARY_CMD" \
        "$GO_PRIVACY_CHECK_CMD" \
        "$GO_SAFETY_CHECK_CMD" \
        "$GO_RECOVER_CMD" \
        "$GO_WATCHDOG_CMD" \
        "$DIRECT_FULL_UPDATE_CMD" \
        "$DIRECT_UNINSTALL_CMD" \
        "$XRAY_CORE_UPDATE_CMD"; do
        if [ -x "$helper" ]; then
            echo "[OK] $helper"
        elif [ -e "$helper" ]; then
            echo "[WARN] $helper exists but is not executable"
        else
            echo "[MISS] $helper"
        fi
    done
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo "/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

xray_config_test() {
    bin="$1"
    config="$2"
    [ -x "$bin" ] || return 1
    [ -s "$config" ] || return 1
    if "$bin" run -test -config "$config" >/dev/null 2>&1; then
        return 0
    fi
    "$bin" test -config "$config" >/dev/null 2>&1
}

run_xray_core_dry_run() {
    [ "$#" -eq 0 ] || { echo "Использование: xray-go update xray-core --dry-run" >&2; exit 2; }

    echo "== Xray-core update dry-run =="
    echo "No changes made. No downloads, no service restart, no direct-install files modified."
    echo

    xray_bin="$(get_xray_bin)"
    if [ -n "$xray_bin" ] && [ -x "$xray_bin" ]; then
        echo "[OK] Xray binary: $xray_bin"
        "$xray_bin" version 2>/dev/null | sed -n '1,2p' || true
    else
        echo "[FAIL] Xray binary not found"
    fi

    if [ -s /opt/etc/xray/config.json ]; then
        if [ -n "$xray_bin" ] && xray_config_test "$xray_bin" /opt/etc/xray/config.json; then
            echo "[OK] Xray config valid: /opt/etc/xray/config.json"
        else
            echo "[FAIL] Xray config validation failed: /opt/etc/xray/config.json"
        fi
    else
        echo "[WARN] Xray config missing: /opt/etc/xray/config.json"
    fi

    if [ -x /opt/etc/init.d/S24xray ]; then
        if /opt/etc/init.d/S24xray status >/dev/null 2>&1; then
            echo "[OK] Xray init status: alive"
        else
            echo "[WARN] Xray init status is not alive"
        fi
    else
        echo "[WARN] Xray init script missing: /opt/etc/init.d/S24xray"
    fi

    if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
        echo "[OK] Xray-core updater helper: $XRAY_CORE_UPDATE_CMD"
    elif [ -e "$XRAY_CORE_UPDATE_CMD" ]; then
        echo "[WARN] Xray-core updater helper exists but is not executable: $XRAY_CORE_UPDATE_CMD"
    else
        echo "[WARN] Xray-core updater helper missing: $XRAY_CORE_UPDATE_CMD"
    fi

    echo
    echo "Planned apply command examples:"
    echo "  xray-go update xray-core --channel latest --yes"
    echo "  xray-go update xray-core --channel prerelease --yes --no-restart"
    echo "  xray-go update xray-core --tag vX.Y.Z --yes"
    echo
    echo "Scope boundary: this target updates only Xray-core. It does not change direct-install manifest, VLESS sources, helpers, watchdog config, or recovery cron."
}

run_xray_core_update() {
    case "${1:-}" in
        --dry-run|--plan|dry-run|plan)
            shift || true
            run_xray_core_dry_run "$@"
            ;;
        *)
            refresh_xray_core_update
            need_exec "$XRAY_CORE_UPDATE_CMD"
            "$XRAY_CORE_UPDATE_CMD" "$@"
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
        refresh_doctor_summary
        refresh_privacy_check
        refresh_safety_check
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
            run_xray_core_update "$@"
            ;;
        *) echo "Использование: xray-go update [go|xray-core]" >&2; exit 2 ;;
    esac
}

run_uninstall() {
    case "${1:-}" in
        ""|--dry-run|--plan|dry-run|plan) [ "$#" -gt 0 ] && shift ;;
        *) echo "Использование: xray-go uninstall --dry-run" >&2; exit 2 ;;
    esac
    [ "$#" -eq 0 ] || { echo "Использование: xray-go uninstall --dry-run" >&2; exit 2; }

    INSTALL_MODE="$(manifest_get_value INSTALL_MODE)"
    if [ "$INSTALL_MODE" != "direct" ]; then
        echo "ОШИБКА: uninstall planner пока доступен только для INSTALL_MODE=direct." >&2
        echo "Текущий INSTALL_MODE: ${INSTALL_MODE:-unknown}" >&2
        exit 2
    fi

    refresh_direct_uninstall
    need_exec "$DIRECT_UNINSTALL_CMD"
    "$DIRECT_UNINSTALL_CMD" --dry-run
}

case "${1:-help}" in
    status)
        shift
        show_status "$@"
        ;;
    summary)
        shift
        run_summary "$@"
        ;;
    privacy-check|privacy)
        shift
        run_privacy_check "$@"
        ;;
    safety-check|safety)
        shift
        run_safety_check "$@"
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
        run_update xray-core "$@"
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
    uninstall)
        shift
        run_uninstall "$@"
        ;;
    version|--version|-V)
        shift || true
        run_version "$@"
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
