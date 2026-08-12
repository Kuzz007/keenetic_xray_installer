#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
SOCKS_AUTH_CONF="$XRAY_DIR/vless-go-socks-auth.conf"
FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_RESOLVER="/opt/bin/xray-failover-go"
HISTORY_CMD="/opt/bin/vless-go-history"
CONFIG_FILE="${CONFIG_FILE:-$XRAY_DIR/vless-go-watchdog.conf}"
AWG_RUNTIME_STATE="$XRAY_DIR/awg/runtime.json"

SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URL="${CHECK_URL:-http://connectivitycheck.gstatic.com/generate_204}"
CHECK_URLS="${CHECK_URLS:-http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
CHECK_RETRIES="${CHECK_RETRIES:-2}"
CHECK_RETRY_DELAY="${CHECK_RETRY_DELAY:-2}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-15}"
FAILOVER_FAILURES_REQUIRED="${FAILOVER_FAILURES_REQUIRED:-2}"
RECOVERY_SUCCESSES_REQUIRED="${RECOVERY_SUCCESSES_REQUIRED:-2}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"
RECOVERY_TEST_PORT="${RECOVERY_TEST_PORT:-18080}"
RECOVERY_COOLDOWN_CYCLES="${RECOVERY_COOLDOWN_CYCLES:-2}"
POST_SWITCH_DELAY="${POST_SWITCH_DELAY:-5}"
PROXY0_REFRESH="${PROXY0_REFRESH:-0}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
LOG_FILE="${LOG_FILE:-/opt/var/log/vless-go-watchdog.log}"
DETAIL_LOG_FILE="${DETAIL_LOG_FILE:-/opt/var/log/vless-go-watchdog-detail.log}"
PID_FILE="${PID_FILE:-/opt/var/run/vless-go-watchdog.pid}"
MARKER="vless-go-watchdog"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
DEFAULT_SCHEDULE="*/5 * * * *"

[ -s "$CONFIG_FILE" ] && . "$CONFIG_FILE"
[ -n "${CHECK_URLS:-}" ] || CHECK_URLS="$CHECK_URL"

XRAY_SOCKS_AUTH="0"
XRAY_SOCKS_USER=""
XRAY_SOCKS_PASS=""
[ -s "$SOCKS_AUTH_CONF" ] && . "$SOCKS_AUTH_CONF" 2>/dev/null || true
case "${XRAY_SOCKS_AUTH:-0}" in 1|yes|true|on) XRAY_SOCKS_AUTH="1" ;; *) XRAY_SOCKS_AUTH="0" ;; esac
XRAY_SOCKS_USER="${XRAY_SOCKS_USER:-}"
XRAY_SOCKS_PASS="${XRAY_SOCKS_PASS:-}"

usage() {
    echo "Использование: vless-go-watchdog check | daemon | status | enable [CRON] | disable | run-primary | run-backup | probe-primary"
}

cron_running() {
    ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1
}

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

log_detail() {
    mkdir -p "$(dirname "$DETAIL_LOG_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$DETAIL_LOG_FILE"
}

history_log() {
    [ -x "$HISTORY_CMD" ] || return 0
    "$HISTORY_CMD" log "$@" >/dev/null 2>&1 || true
}

active_slot() {
    [ -s "$ACTIVE_STORE" ] && sed -n '1p' "$ACTIVE_STORE" || echo "unknown"
}

awg_owns_xray() {
    [ -s "$AWG_RUNTIME_STATE" ]
}

selector_file() {
    case "$1" in
        primary|backup) echo "$XRAY_DIR/vless-go.$1.selector" ;;
        *) return 1 ;;
    esac
}

validate_selector() {
    VALUE="$1"
    case "$VALUE" in
        first|'') return 0 ;;
        index:*)
            IDX="${VALUE#index:}"
            case "$IDX" in
                ''|*[!0-9]*|0) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

slot_selector() {
    SLOT="$1"
    FILE="$(selector_file "$SLOT")" || { echo first; return 0; }
    VALUE="$(sed -n '1p' "$FILE" 2>/dev/null || true)"
    VALUE="${VALUE:-first}"
    validate_selector "$VALUE" || VALUE="first"
    printf '%s\n' "$VALUE"
}

resolver_selector_args() {
    SELECTOR="$1"
    case "$SELECTOR" in
        first|'') printf '%s\n' "-first" ;;
        index:*)
            IDX="${SELECTOR#index:}"
            if ! "$GO_RESOLVER" -h 2>&1 | grep -q -- '-select-index'; then
                log "Recovery probe primary не может использовать selector $SELECTOR: Go resolver не поддерживает -select-index"
                return 1
            fi
            printf '%s\n' "-select-index $IDX"
            ;;
        *) printf '%s\n' "-first" ;;
    esac
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then command -v xray
    elif [ -x /opt/bin/xray ]; then echo "/opt/bin/xray"
    else echo ""
    fi
}

ensure_failover_cmd() {
    [ -x "$FAILOVER_CMD" ] || { log "ОШИБКА: команда failover не найдена: $FAILOVER_CMD"; exit 1; }
}

socks_auth_for_target() {
    [ "$XRAY_SOCKS_AUTH" = "1" ] || return 1
    [ -n "$XRAY_SOCKS_USER" ] || return 1
    [ -n "$XRAY_SOCKS_PASS" ] || return 1
    [ "$2" = "$SOCKS_PORT" ] || return 1
    return 0
}

curl_check_url() {
    TARGET_HOST="$1"
    TARGET_PORT="$2"
    URL="$3"
    TMP_OUT="/tmp/vless-go-watchdog.check.$$"
    TMP_ERR="/tmp/vless-go-watchdog.err.$$"

    set -- -fsS --socks5-hostname "$TARGET_HOST:$TARGET_PORT" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME"
    if socks_auth_for_target "$TARGET_HOST" "$TARGET_PORT"; then
        set -- "$@" --proxy-user "$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS"
    fi

    set +e
    curl "$@" "$URL" >"$TMP_OUT" 2>"$TMP_ERR"
    RC="$?"
    set -e

    if [ "$RC" -eq 0 ]; then
        rm -f "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true
        return 0
    fi

    ERR_MSG="$(tr '\n' ' ' < "$TMP_ERR" 2>/dev/null | sed 's/[[:space:]][[:space:]]*/ /g')"
    rm -f "$TMP_OUT" "$TMP_ERR" 2>/dev/null || true
    log_detail "Проверка endpoint не прошла rc=$RC url=$URL error=$ERR_MSG"
    return "$RC"
}

check_socks_target_once() {
    TARGET_HOST="$1"
    TARGET_PORT="$2"

    for URL in $CHECK_URLS; do
        if curl_check_url "$TARGET_HOST" "$TARGET_PORT" "$URL"; then
            return 0
        fi
    done

    log "Проверка связи не прошла по всем endpoint"
    return 1
}

check_socks_target() {
    TARGET_HOST="$1"
    TARGET_PORT="$2"
    ATTEMPT="1"

    while [ "$ATTEMPT" -le "$CHECK_RETRIES" ]; do
        if check_socks_target_once "$TARGET_HOST" "$TARGET_PORT"; then
            [ "$ATTEMPT" = "1" ] || log "Проверка связи OK после повтора $ATTEMPT/$CHECK_RETRIES"
            return 0
        fi

        if [ "$ATTEMPT" -lt "$CHECK_RETRIES" ]; then
            log "Попытка проверки $ATTEMPT/$CHECK_RETRIES не прошла; повтор через ${CHECK_RETRY_DELAY}s"
            sleep "$CHECK_RETRY_DELAY"
        fi
        ATTEMPT="$((ATTEMPT + 1))"
    done

    return 1
}

check_socks() {
    check_socks_target "$SOCKS_HOST" "$SOCKS_PORT"
}

refresh_proxy0_if_needed() {
    [ "$PROXY0_REFRESH" = "1" ] || return 0
    command -v ndmc >/dev/null 2>&1 || { log "Обновление Proxy0 пропущено: ndmc не найден"; return 0; }

    log "Перезапуск интерфейса $PROXY_IFACE"
    ndmc -c "interface $PROXY_IFACE down" >> "$DETAIL_LOG_FILE" 2>&1 || true
    sleep 1
    if [ -x /opt/bin/vless-go-socks-auth ]; then
        /opt/bin/vless-go-socks-auth apply-proxy0 >> "$DETAIL_LOG_FILE" 2>&1 || true
    fi
    ndmc -c "interface $PROXY_IFACE up" >> "$DETAIL_LOG_FILE" 2>&1 || true
}

switch_to() {
    SLOT="$1"
    REASON="${2:-manual}"
    if awg_owns_xray; then
        log "VLESS switch skipped: isolated AWG slot owns Xray"
        return 1
    fi
    ensure_failover_cmd
    log "Переключение на $SLOT"

    TMP_SWITCH="/tmp/vless-go-watchdog.switch.$$"
    set +e
    VLESS_GO_HISTORY_SUPPRESS=1 "$FAILOVER_CMD" switch "$SLOT" >"$TMP_SWITCH" 2>&1
    RC="$?"
    set -e

    cat "$TMP_SWITCH" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    rm -f "$TMP_SWITCH" 2>/dev/null || true

    if [ "$RC" -ne 0 ]; then
        log "ОШИБКА: переключение на $SLOT не удалось; см. detail log."
        history_log failed_switch source=watchdog reason="$REASON" to="$SLOT" rc="$RC"
        return "$RC"
    fi

    log "Переключение на $SLOT завершено"
    refresh_proxy0_if_needed
    if [ "$POST_SWITCH_DELAY" -gt 0 ] 2>/dev/null; then
        log "Ожидание ${POST_SWITCH_DELAY}s после переключения"
        sleep "$POST_SWITCH_DELAY"
    fi
    return 0
}

rollback_to_backup_after_failed_recovery() {
    [ -s "$BACKUP_STORE" ] || { log "Rollback на backup невозможен: backup не настроен"; return 1; }
    log "Rollback recovery: возвращаемся на backup после неудачного backup -> primary"
    if switch_to backup daemon_recovery_rollback && check_socks; then
        log "Rollback recovery на backup OK"
        history_log daemon_recovery_rollback from=primary to=backup result=ok
        return 0
    fi
    log "Rollback recovery на backup не прошёл health-check"
    history_log failed_recovery_rollback from=primary to=backup reason=post_rollback_health_failed
    return 1
}

probe_primary() {
    [ -s "$PRIMARY_STORE" ] || { log "Основной источник не настроен; probe primary невозможен."; return 1; }
    [ -x "$GO_RESOLVER" ] || { log "Go resolver/generator не найден: $GO_RESOLVER"; return 1; }

    XRAY_BIN="$(get_xray_bin)"
    [ -n "$XRAY_BIN" ] || { log "Xray binary не найден; probe primary невозможен."; return 1; }

    PRIMARY_VALUE="$(sed -n '1p' "$PRIMARY_STORE")"
    PRIMARY_SELECTOR="$(slot_selector primary)"
    SELECTOR_ARGS="$(resolver_selector_args "$PRIMARY_SELECTOR")" || return 1
    TMP_CONFIG="/opt/tmp/vless-go-recovery-primary.$$.json"
    TMP_RESOLVER_LOG="/tmp/vless-go-recovery-resolver.$$"
    TMP_XRAY_LOG="/tmp/vless-go-recovery-xray.$$"
    TEST_PID=""
    mkdir -p /opt/tmp /opt/var/log

    cleanup_probe() {
        if [ -n "$TEST_PID" ] && kill -0 "$TEST_PID" 2>/dev/null; then
            kill "$TEST_PID" 2>/dev/null || true
            sleep 1
            kill -9 "$TEST_PID" 2>/dev/null || true
        fi
        rm -f "$TMP_CONFIG" "$TMP_RESOLVER_LOG" "$TMP_XRAY_LOG" 2>/dev/null || true
    }

    log "Recovery probe primary использует selector: $PRIMARY_SELECTOR"
    set +e
    # Intentionally use word splitting for SELECTOR_ARGS: either '-first' or '-select-index N'.
    # shellcheck disable=SC2086
    "$GO_RESOLVER" -input "$PRIMARY_VALUE" -output "$TMP_CONFIG" \
        -listen "127.0.0.1" -port "$RECOVERY_TEST_PORT" \
        -profile "vless-recovery-test" $SELECTOR_ARGS >"$TMP_RESOLVER_LOG" 2>&1
    RC="$?"
    set -e
    cat "$TMP_RESOLVER_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    [ "$RC" -eq 0 ] || { log "Генерация config для recovery probe основного профиля не прошла; см. detail log."; cleanup_probe; return 1; }

    set +e
    "$XRAY_BIN" run -test -config "$TMP_CONFIG" >> "$DETAIL_LOG_FILE" 2>&1
    RC="$?"
    set -e
    [ "$RC" -eq 0 ] || { log "Валидация config для recovery probe основного профиля не прошла; см. detail log."; cleanup_probe; return 1; }

    "$XRAY_BIN" run -config "$TMP_CONFIG" >"$TMP_XRAY_LOG" 2>&1 &
    TEST_PID="$!"
    sleep 2

    if ! kill -0 "$TEST_PID" 2>/dev/null; then
        cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
        log "Тестовый Xray для recovery probe не запустился; см. detail log."
        cleanup_probe
        return 1
    fi

    if check_socks_target "127.0.0.1" "$RECOVERY_TEST_PORT"; then
        cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
        cleanup_probe
        return 0
    fi

    cat "$TMP_XRAY_LOG" >> "$DETAIL_LOG_FILE" 2>/dev/null || true
    cleanup_probe
    return 1
}

recover_primary_once() {
    [ "$AUTO_RECOVER_PRIMARY" = "1" ] || { log "Auto recovery primary disabled: AUTO_RECOVER_PRIMARY=$AUTO_RECOVER_PRIMARY"; return 1; }
    [ -s "$PRIMARY_STORE" ] || { log "Основной профиль не настроен; recovery primary невозможен."; return 1; }
    log "Проверка восстановления primary на временном SOCKS порту $RECOVERY_TEST_PORT"
    if ! probe_primary; then
        log "Recovery probe primary FAILED"
        return 1
    fi
    log "Recovery probe primary OK; переключение backup -> primary"
    if switch_to primary cron_recovery; then
        if check_socks; then
            log "Recovery на primary OK"
            history_log cron_recovery from=backup to=primary result=ok
            return 0
        fi
        log "Recovery на primary не прошёл health-check; выполняем rollback на backup"
        history_log failed_recovery source=cron from=backup to=primary reason=post_switch_health_failed
        rollback_to_backup_after_failed_recovery || true
        return 1
    fi
    log "Recovery switch на primary не выполнился"
    history_log failed_recovery source=cron from=backup to=primary reason=switch_failed
    [ "$(active_slot)" = "backup" ] || rollback_to_backup_after_failed_recovery || true
    return 1
}

check_and_switch() {
    if awg_owns_xray; then
        log "VLESS watchdog skipped: isolated AWG slot owns Xray"
        return 0
    fi
    SLOT="$(active_slot)"
    log "Проверка активного слота: $SLOT через SOCKS $SOCKS_HOST:$SOCKS_PORT"

    if check_socks; then
        log "Проверка связи OK на $SLOT"
        if [ "$SLOT" = "backup" ]; then
            recover_primary_once || true
        fi
        return 0
    fi

    log "Проверка связи FAILED на $SLOT"
    if [ "$SLOT" = "primary" ]; then
        [ -s "$BACKUP_STORE" ] || { log "Резервный профиль не настроен; failover невозможен."; return 1; }
        switch_to backup cron_failover
        if check_socks; then log "Проверка связи OK после переключения на backup"; history_log daemon_failover from=primary to=backup result=ok source=cron; return 0; fi
        log "Проверка связи всё ещё FAILED после переключения на backup"
        history_log failed_switch source=cron from=primary to=backup reason=post_switch_health_failed
        return 1
    fi

    if [ "$SLOT" = "backup" ]; then
        recover_primary_once || true
        if check_socks; then
            return 0
        fi
        log "Backup и primary recovery не восстановили связь"
        return 1
    fi

    log "Активный слот неизвестен; автоматическое переключение не выполняется."
    return 1
}

handle_daemon_primary() {
    DAEMON_RECOVERY_SUCCESS_COUNT="0"
    DAEMON_RECOVERY_COOLDOWN="0"

    if check_socks; then
        DAEMON_FAIL_COUNT="0"
        log "Daemon health OK на primary"
        return 0
    fi

    DAEMON_FAIL_COUNT="$((DAEMON_FAIL_COUNT + 1))"
    log "Daemon health FAIL на primary: $DAEMON_FAIL_COUNT/$FAILOVER_FAILURES_REQUIRED"

    if [ "$DAEMON_FAIL_COUNT" -ge "$FAILOVER_FAILURES_REQUIRED" ]; then
        if [ -s "$BACKUP_STORE" ]; then
            log "Достигнут порог failover; переключение primary -> backup"
            if switch_to backup daemon_failover && check_socks; then
                log "Daemon failover на backup OK"
                history_log daemon_failover from=primary to=backup result=ok failures="$FAILOVER_FAILURES_REQUIRED"
                DAEMON_RECOVERY_COOLDOWN="$RECOVERY_COOLDOWN_CYCLES"
            else
                log "Daemon failover на backup не прошёл health-check"
                history_log failed_switch source=daemon from=primary to=backup reason=post_switch_health_failed
            fi
        else
            log "Резервный профиль не настроен; failover невозможен."
            history_log failed_switch source=daemon from=primary to=backup reason=backup_not_configured
        fi
        DAEMON_FAIL_COUNT="0"
    fi
}

handle_daemon_backup() {
    if check_socks; then
        DAEMON_BACKUP_FAIL_COUNT="0"
        log "Daemon health OK на backup"
    else
        DAEMON_BACKUP_FAIL_COUNT="$((DAEMON_BACKUP_FAIL_COUNT + 1))"
        DAEMON_RECOVERY_SUCCESS_COUNT="0"
        log "Daemon health FAIL на backup: подряд ошибок $DAEMON_BACKUP_FAIL_COUNT; проверяем primary recovery"
        recover_primary_once || true
        return 0
    fi

    [ "$AUTO_RECOVER_PRIMARY" = "1" ] || return 0

    if [ "$DAEMON_RECOVERY_COOLDOWN" -gt 0 ]; then
        log "Cooldown recovery probe primary: осталось циклов $DAEMON_RECOVERY_COOLDOWN"
        DAEMON_RECOVERY_COOLDOWN="$((DAEMON_RECOVERY_COOLDOWN - 1))"
        return 0
    fi

    log "Проверка восстановления primary на временном SOCKS порту $RECOVERY_TEST_PORT"
    if probe_primary; then
        DAEMON_RECOVERY_SUCCESS_COUNT="$((DAEMON_RECOVERY_SUCCESS_COUNT + 1))"
        log "Recovery probe primary OK: $DAEMON_RECOVERY_SUCCESS_COUNT/$RECOVERY_SUCCESSES_REQUIRED"
    else
        DAEMON_RECOVERY_SUCCESS_COUNT="0"
        log "Recovery probe primary FAILED"
        return 0
    fi

    if [ "$DAEMON_RECOVERY_SUCCESS_COUNT" -ge "$RECOVERY_SUCCESSES_REQUIRED" ]; then
        log "Достигнут порог recovery; переключение backup -> primary"
        if switch_to primary daemon_recovery; then
            if check_socks; then
                log "Daemon recovery на primary OK"
                history_log daemon_recovery from=backup to=primary result=ok successes="$RECOVERY_SUCCESSES_REQUIRED"
            else
                log "Daemon recovery на primary не прошёл health-check; выполняем rollback на backup"
                history_log failed_recovery source=daemon from=backup to=primary reason=post_switch_health_failed
                rollback_to_backup_after_failed_recovery || true
            fi
        else
            log "Daemon recovery switch на primary не выполнился; проверяем необходимость rollback на backup"
            history_log failed_recovery source=daemon from=backup to=primary reason=switch_failed
            [ "$(active_slot)" = "backup" ] || rollback_to_backup_after_failed_recovery || true
        fi
        DAEMON_RECOVERY_SUCCESS_COUNT="0"
        DAEMON_RECOVERY_COOLDOWN="$RECOVERY_COOLDOWN_CYCLES"
    fi
}

run_daemon() {
    mkdir -p "$(dirname "$PID_FILE")" /opt/var/log
    echo "$$" > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; log "Daemon остановлен"; exit 0' INT TERM

    DAEMON_FAIL_COUNT="0"
    DAEMON_BACKUP_FAIL_COUNT="0"
    DAEMON_RECOVERY_SUCCESS_COUNT="0"
    DAEMON_RECOVERY_COOLDOWN="0"

    log "Daemon запущен: interval=${WATCHDOG_INTERVAL}s failover_failures_required=$FAILOVER_FAILURES_REQUIRED check_retries=$CHECK_RETRIES auto_recover_primary=$AUTO_RECOVER_PRIMARY post_switch_delay=${POST_SWITCH_DELAY}s proxy0_refresh=$PROXY0_REFRESH socks_auth=$XRAY_SOCKS_AUTH"

    while true; do
        if awg_owns_xray; then
            sleep "$WATCHDOG_INTERVAL"
            continue
        fi
        SLOT="$(active_slot)"
        case "$SLOT" in
            primary) handle_daemon_primary ;;
            backup) handle_daemon_backup ;;
            *) log "Daemon: активный слот неизвестен: $SLOT" ;;
        esac
        sleep "$WATCHDOG_INTERVAL"
    done
}

case "${1:-check}" in
    check) check_and_switch ;;
    daemon) run_daemon ;;
    status) echo "active=$(active_slot) auto_recover_primary=$AUTO_RECOVER_PRIMARY socks=${SOCKS_HOST}:${SOCKS_PORT} auth=$XRAY_SOCKS_AUTH" ;;
    enable)
        SCHEDULE="${2:-$DEFAULT_SCHEDULE}"
        mkdir -p "$(dirname "$CRON_FILE")"
        touch "$CRON_FILE"
        grep -v "$MARKER" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
        echo "$SCHEDULE $0 check # $MARKER" >> "$CRON_FILE.tmp"
        mv "$CRON_FILE.tmp" "$CRON_FILE"
        if cron_running; then log "Cron уже запущен"; else log "ВНИМАНИЕ: cron не запущен; проверьте /opt/etc/init.d/S10cron start"; fi
        log "Watchdog cron включён: $SCHEDULE"
        ;;
    disable)
        [ -f "$CRON_FILE" ] || exit 0
        grep -v "$MARKER" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
        mv "$CRON_FILE.tmp" "$CRON_FILE"
        log "Watchdog cron отключён"
        ;;
    run-primary) switch_to primary manual ;;
    run-backup) switch_to backup manual ;;
    probe-primary) probe_primary ;;
    *) usage; exit 1 ;;
esac
