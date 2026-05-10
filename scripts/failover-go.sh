#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
GO_RESOLVER="/opt/bin/xray-failover-go"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_HISTORY_CMD="/opt/bin/vless-go-history"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"

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

pause() { read_tty "Нажмите Enter для продолжения..."; }

require_cmd() {
    if [ ! -x "$1" ]; then
        echo "ОШИБКА: команда не найдена или не исполняемая: $1" >&2
        return 1
    fi
    return 0
}

show_header() {
    clear 2>/dev/null || true
    echo "========================================"
    echo " VLESS Go / Xray failover"
    echo "========================================"
    echo
}

active_slot() { [ -s "$ACTIVE_STORE" ] && sed -n '1p' "$ACTIVE_STORE" || echo "primary"; }
slot_configured() { case "$1" in primary) [ -s "$PRIMARY_STORE" ] ;; backup) [ -s "$BACKUP_STORE" ] ;; *) return 1 ;; esac; }
slot_file() { case "$1" in primary) echo "$PRIMARY_STORE" ;; backup) echo "$BACKUP_STORE" ;; *) return 1 ;; esac; }
slot_source() { FILE="$(slot_file "$1")" || return 1; sed -n '1p' "$FILE" 2>/dev/null || true; }
selector_file() { case "$1" in primary|backup) echo "$XRAY_DIR/vless-go.$1.selector" ;; *) return 1 ;; esac; }
read_selector() { FILE="$(selector_file "$1")" || return 1; VALUE="$(sed -n '1p' "$FILE" 2>/dev/null || true)"; echo "${VALUE:-first}"; }

slot_ru() { case "$1" in primary) echo "основной" ;; backup) echo "резервный" ;; *) echo "$1" ;; esac; }

normalize_selector() {
    VALUE="$1"
    case "$VALUE" in
        first|'') echo "first" ;;
        index:[1-9]*) echo "$VALUE" ;;
        [1-9]*) echo "index:$VALUE" ;;
        *) return 1 ;;
    esac
}

show_profile_list() {
    SOURCE_VALUE="$1"
    [ -z "$SOURCE_VALUE" ] && return 0
    if [ ! -x "$GO_RESOLVER" ]; then
        echo "Список профилей пропущен: $GO_RESOLVER не найден." >&2
        return 0
    fi
    echo >&2
    echo "Доступные профили из ссылки/подписки:" >&2
    if ! "$GO_RESOLVER" -input "$SOURCE_VALUE" -list >&2; then
        echo "ПРЕДУПРЕЖДЕНИЕ: не удалось получить список профилей. Selector можно ввести вручную." >&2
    fi
    echo >&2
}

prompt_selector() {
    SLOT="$1"
    SOURCE_VALUE="$2"
    CURRENT="$(read_selector "$SLOT" 2>/dev/null || echo first)"
    SLOT_NAME="$(slot_ru "$SLOT")"

    show_profile_list "$SOURCE_VALUE"
    echo "Текущий selector для $SLOT_NAME профиля: $CURRENT" >&2
    echo "Selector выбирает VLESS-профиль внутри подписки." >&2
    echo "Поддерживается: first, index:N или просто N. Пример: 7 = index:7." >&2
    echo "Selector по имени не используется для автообновлений, так как имена в подписках нестабильны." >&2
    echo >&2
    read_tty "Введите selector для $SLOT_NAME профиля [по умолчанию: $CURRENT]: "
    VALUE="$REPLY"
    [ -n "$VALUE" ] || VALUE="$CURRENT"
    SELECTOR="$(normalize_selector "$VALUE")" || { echo "ОШИБКА: неверный selector: $VALUE" >&2; return 1; }
    echo "$SELECTOR"
}

show_status() {
    show_header
    echo "[Статус]"
    require_cmd "$GO_FAILOVER_CMD" && "$GO_FAILOVER_CMD" status || true
    echo
    require_cmd "$GO_WATCHDOG_CMD" && "$GO_WATCHDOG_CMD" status || true
    echo
    pause
}

run_doctor() {
    show_header
    echo "[Диагностика doctor]"
    require_cmd "$GO_DOCTOR_CMD" && "$GO_DOCTOR_CMD" || true
    echo
    pause
}

switch_slot() {
    SLOT="$1"
    show_header
    echo "[Переключение на $(slot_ru "$SLOT") профиль]"
    require_cmd "$GO_FAILOVER_CMD" && "$GO_FAILOVER_CMD" switch "$SLOT"
    echo
    pause
}

replace_source() {
    SLOT="$1"
    SLOT_NAME="$(slot_ru "$SLOT")"
    show_header
    echo "[Добавить/заменить $SLOT_NAME VLESS/subscription URL]"
    echo "Текущее значение не выводится, чтобы не светить приватные данные."
    echo
    read_tty "Введите новый $SLOT_NAME VLESS link или subscription URL: "
    VALUE="$REPLY"
    [ -n "$VALUE" ] || { echo "Отменено: пустое значение."; pause; return 0; }

    SELECTOR="$(prompt_selector "$SLOT" "$VALUE")" || { pause; return 1; }
    require_cmd "$GO_FAILOVER_CMD" && "$GO_FAILOVER_CMD" "set-$SLOT" "$VALUE" --selector "$SELECTOR"

    echo
    read_tty "Переключиться на $SLOT_NAME профиль сейчас? [y/N]: "
    case "$REPLY" in y|Y|yes|YES|д|Д|да|ДА) "$GO_FAILOVER_CMD" switch "$SLOT" ;; *) echo "Сохранено. Переключиться можно позже из меню." ;; esac
    echo
    pause
}

set_slot_selector() {
    SLOT="$1"
    SLOT_NAME="$(slot_ru "$SLOT")"
    show_header
    echo "[Настроить selector для $SLOT_NAME профиля]"
    require_cmd "$GO_FAILOVER_CMD" || { pause; return 0; }
    SOURCE_VALUE="$(slot_source "$SLOT")"
    SELECTOR="$(prompt_selector "$SLOT" "$SOURCE_VALUE")" || { pause; return 1; }
    "$GO_FAILOVER_CMD" set-selector "$SLOT" "$SELECTOR"
    echo
    read_tty "Применить $SLOT_NAME профиль с этим selector сейчас? [y/N]: "
    case "$REPLY" in y|Y|yes|YES|д|Д|да|ДА) "$GO_FAILOVER_CMD" switch "$SLOT" ;; *) echo "Selector сохранён, профиль не переключался." ;; esac
    echo
    pause
}

update_all_sources() {
    show_header
    echo "[Обновить основной и резервный профили сейчас]"
    require_cmd "$GO_FAILOVER_CMD" || { pause; return 0; }
    ORIGINAL="$(active_slot)"
    echo "Текущий активный слот: $ORIGINAL"
    echo
    UPDATED="0"

    if slot_configured primary; then
        echo "Обновление/проверка основного профиля без рестарта Xray..."
        "$GO_FAILOVER_CMD" switch primary --no-restart
        UPDATED="1"
        echo
    else
        echo "Основной профиль не настроен, пропуск."
    fi

    if slot_configured backup; then
        echo "Обновление/проверка резервного профиля без рестарта Xray..."
        "$GO_FAILOVER_CMD" switch backup --no-restart
        UPDATED="1"
        echo
    else
        echo "Резервный профиль не настроен, пропуск."
    fi

    [ "$UPDATED" = "0" ] && { echo "Обновлять нечего."; pause; return 0; }

    case "$ORIGINAL" in
        primary|backup)
            echo "Возврат активного слота: $ORIGINAL"
            "$GO_FAILOVER_CMD" switch "$ORIGINAL"
            ;;
        *) echo "Неизвестный исходный слот: $ORIGINAL. Оставлен последний проверенный слот." ;;
    esac
    echo
    pause
}

configure_auto_update() {
    show_header
    echo "[Автообновление подписок по cron]"
    require_cmd "$GO_AUTO_UPDATE_CMD" || { pause; return 0; }
    "$GO_AUTO_UPDATE_CMD" status || true
    echo
    echo "1. Включить ежедневное автообновление по расписанию по умолчанию"
    echo "2. Включить с собственным cron-расписанием"
    echo "3. Отключить автообновление"
    echo "4. Запустить автообновление сейчас"
    echo "0. Назад"
    echo
    read_tty "Выберите пункт: "
    case "$REPLY" in
        1) "$GO_AUTO_UPDATE_CMD" enable ;;
        2) read_tty "Введите cron-расписание, например '17 4 * * *': "; [ -n "$REPLY" ] && "$GO_AUTO_UPDATE_CMD" enable "$REPLY" || echo "Отменено." ;;
        3) "$GO_AUTO_UPDATE_CMD" disable ;;
        4) "$GO_AUTO_UPDATE_CMD" run ;;
        0) return 0 ;;
        *) echo "Неизвестный пункт." ;;
    esac
    echo
    pause
}

toggle_recovery() {
    show_header
    echo "[Автовозврат с резервного на основной профиль]"
    [ -f "$WATCHDOG_CONF" ] || { echo "ОШИБКА: конфиг watchdog не найден: $WATCHDOG_CONF" >&2; pause; return 1; }
    CURRENT="$(grep '^AUTO_RECOVER_PRIMARY=' "$WATCHDOG_CONF" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)"
    CURRENT="${CURRENT:-0}"
    echo "Текущее значение AUTO_RECOVER_PRIMARY=$CURRENT"
    echo
    if [ "$CURRENT" = "1" ]; then
        read_tty "Отключить автовозврат backup -> primary? [y/N]: "
        case "$REPLY" in y|Y|yes|YES|д|Д|да|ДА) sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=0/' "$WATCHDOG_CONF" ;; *) echo "Без изменений."; pause; return 0 ;; esac
    else
        read_tty "Включить автовозврат backup -> primary? [y/N]: "
        case "$REPLY" in y|Y|yes|YES|д|Д|да|ДА) if grep -q '^AUTO_RECOVER_PRIMARY=' "$WATCHDOG_CONF"; then sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' "$WATCHDOG_CONF"; else echo 'AUTO_RECOVER_PRIMARY=1' >> "$WATCHDOG_CONF"; fi ;; *) echo "Без изменений."; pause; return 0 ;; esac
    fi
    [ -x "$WATCHDOG_INIT" ] && "$WATCHDOG_INIT" restart || echo "ПРЕДУПРЕЖДЕНИЕ: init watchdog не найден: $WATCHDOG_INIT" >&2
    echo
    pause
}

show_watchdog_log() { show_header; echo "[Журнал watchdog]"; [ -s "$WATCHDOG_LOG" ] && tail -n 80 "$WATCHDOG_LOG" || echo "Журнал пустой или отсутствует: $WATCHDOG_LOG"; echo; pause; }
follow_watchdog_log() { show_header; echo "[Журнал watchdog в реальном времени]"; echo "Ctrl+C остановит просмотр и вернёт в shell/menu."; echo; [ -e "$WATCHDOG_LOG" ] && tail -n 50 -f "$WATCHDOG_LOG" || { echo "Журнал отсутствует: $WATCHDOG_LOG"; pause; }; }
show_switch_history() { show_header; echo "[История переключений]"; require_cmd "$GO_HISTORY_CMD" && "$GO_HISTORY_CMD" tail 80 || true; echo; pause; }
follow_switch_history() { show_header; echo "[История переключений в реальном времени]"; echo "Ctrl+C остановит просмотр и вернёт в shell/menu."; echo; require_cmd "$GO_HISTORY_CMD" && "$GO_HISTORY_CMD" follow || pause; }

update_go_edition() {
    show_header
    echo "[Обновить Go edition]"
    require_cmd "$GO_INSTALLER_UPDATE_CMD" && "$GO_INSTALLER_UPDATE_CMD" --first
    echo
    pause
}

update_xray_core() {
    show_header
    echo "[Обновить Xray-core]"
    require_cmd "$XRAY_CORE_UPDATE_CMD" || { pause; return 0; }
    echo "Перед обновлением можно создать backup текущего бинарника Xray."
    echo "Backup нужен для автоматического rollback, если новый Xray не запустится или конфиг окажется невалидным."
    echo
    read_tty "Создать backup перед обновлением Xray-core? [Y/n]: "
    case "$REPLY" in n|N|no|NO|н|Н|нет|НЕТ) BACKUP_ARG="--no-backup"; echo "ПРЕДУПРЕЖДЕНИЕ: backup отключён, автоматический rollback бинарника будет недоступен." ;; *) BACKUP_ARG="--backup" ;; esac
    echo
    "$XRAY_CORE_UPDATE_CMD" "$BACKUP_ARG"
    echo
    pause
}

show_menu() {
    show_header
    echo "Диагностика"
    echo "  1. Статус"
    echo "  2. Диагностика doctor"
    echo
    echo "Профили и переключение"
    echo "  3. Переключить на основной профиль"
    echo "  4. Переключить на резервный профиль"
    echo "  5. Добавить/заменить основной VLESS/subscription URL"
    echo "  6. Добавить/заменить резервный VLESS/subscription URL"
    echo "  7. Настроить selector основного профиля"
    echo "  8. Настроить selector резервного профиля"
    echo "  9. Обновить основной и резервный профили сейчас"
    echo
    echo "Автоматизация"
    echo " 10. Настроить cron auto-update"
    echo " 11. Включить/выключить backup -> primary recovery"
    echo
    echo "Журналы"
    echo " 12. Показать watchdog log"
    echo " 13. Смотреть watchdog log в реальном времени"
    echo " 14. Показать историю переключений"
    echo " 15. Смотреть историю переключений в реальном времени"
    echo
    echo "Обновления"
    echo " 16. Обновить Go edition"
    echo " 17. Обновить Xray-core"
    echo
    echo "  0. Выход"
    echo
}

while true; do
    show_menu
    read_tty "Выберите пункт: "
    case "$REPLY" in
        1) show_status ;; 2) run_doctor ;; 3) switch_slot primary ;; 4) switch_slot backup ;; 5) replace_source primary ;; 6) replace_source backup ;; 7) set_slot_selector primary ;; 8) set_slot_selector backup ;; 9) update_all_sources ;; 10) configure_auto_update ;; 11) toggle_recovery ;; 12) show_watchdog_log ;; 13) follow_watchdog_log ;; 14) show_switch_history ;; 15) follow_switch_history ;; 16) update_go_edition ;; 17) update_xray_core ;; 0|q|Q|exit|quit|выход|Выход) exit 0 ;; *) echo "Неизвестный пункт."; sleep 1 ;;
    esac
done
