#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
HISTORY_CMD="/opt/bin/vless-go-history"
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"

if [ -s "$LOCK_HELPER" ]; then
    . "$LOCK_HELPER"
else
    vless_go_acquire_lock() { return 0; }
fi

history_log() {
    [ "${VLESS_GO_HISTORY_SUPPRESS:-0}" = "1" ] && return 0
    [ -x "$HISTORY_CMD" ] || return 0
    "$HISTORY_CMD" log "$@" >/dev/null 2>&1 || true
}

usage() {
    echo "Использование: vless-go-failover КОМАНДА [АРГУМЕНТЫ]"
    echo "Команды:"
    echo "  status"
    echo "  set-primary SRC [--selector first|index:N]"
    echo "  set-backup SRC [--selector first|index:N]"
    echo "  set-selector primary|backup first|index:N"
    echo "  switch primary|backup [--selector first|index:N] [--first] [--no-restart]"
    echo "  update-active [--selector first|index:N] [--first] [--no-restart]"
    echo "  sync-primary"
}

slot_file() {
    case "$1" in
        primary) echo "$PRIMARY_STORE" ;;
        backup) echo "$BACKUP_STORE" ;;
        *) return 1 ;;
    esac
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

validate_source() {
    VALUE="$1"
    case "$VALUE" in
        '') echo "ОШИБКА: источник не должен быть пустым" >&2; return 1 ;;
    esac

    LINE_COUNT="$(printf '%s\n' "$VALUE" | wc -l | tr -d ' ')"
    if [ "$LINE_COUNT" != "1" ]; then
        echo "ОШИБКА: источник должен быть одной строкой" >&2
        return 1
    fi

    case "$VALUE" in
        vless://*|http://*|https://*) return 0 ;;
        *) echo "ОШИБКА: источник должен начинаться с vless://, http:// или https://" >&2; return 1 ;;
    esac
}

slot_source() {
    FILE="$(slot_file "$1")" || return 1
    [ -s "$FILE" ] || return 2
    sed -n '1p' "$FILE"
}

slot_selector() {
    SLOT="$1"
    FILE="$(selector_file "$SLOT")" || return 1
    VALUE="$(sed -n '1p' "$FILE" 2>/dev/null || true)"
    VALUE="${VALUE:-first}"
    validate_selector "$VALUE" || VALUE="first"
    printf '%s\n' "$VALUE"
}

save_selector() {
    SLOT="$1"
    VALUE="${2:-first}"
    validate_selector "$VALUE" || { echo "ОШИБКА: некорректный selector: $VALUE (поддерживается: first, index:N)" >&2; exit 1; }
    FILE="$(selector_file "$SLOT")" || { echo "ОШИБКА: некорректный слот: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Selector для $SLOT сохранён: $VALUE"
}

save_source() {
    SLOT="$1"
    VALUE="$2"
    SELECTOR="${3:-first}"
    validate_source "$VALUE" || exit 1
    FILE="$(slot_file "$SLOT")" || { echo "ОШИБКА: некорректный слот: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Источник $SLOT сохранён: $FILE"
    save_selector "$SLOT" "$SELECTOR"
}

parse_set_args() {
    SET_SOURCE=""
    SET_SELECTOR="first"
    [ "$#" -ge 1 ] || { echo "ОШИБКА: требуется источник" >&2; exit 1; }
    SET_SOURCE="$1"
    validate_source "$SET_SOURCE" || exit 1
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --selector)
                [ "$#" -ge 2 ] || { echo "ОШИБКА: --selector требует значение" >&2; exit 1; }
                SET_SELECTOR="$2"
                shift 2
                ;;
            --first)
                SET_SELECTOR="first"
                shift
                ;;
            *) echo "ОШИБКА: неизвестный аргумент: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
}

parse_update_flags() {
    FIRST="0"
    NO_RESTART="0"
    SELECTOR=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --first) FIRST="1"; SELECTOR="first"; shift ;;
            --selector)
                [ "$#" -ge 2 ] || { echo "ОШИБКА: --selector требует значение" >&2; exit 1; }
                SELECTOR="$2"
                shift 2
                ;;
            --no-restart) NO_RESTART="1"; shift ;;
            *) echo "ОШИБКА: неизвестный флаг: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
}

run_update() {
    SOURCE_VALUE="$1"
    SLOT="$2"
    ACTION="${3:-update-active}"
    shift 3
    parse_update_flags "$@"

    validate_source "$SOURCE_VALUE" || { history_log failed_update slot="$SLOT" reason=invalid_source; exit 1; }
    [ -x "$GO_UPDATE_CMD" ] || { history_log failed_update slot="$SLOT" reason=missing_update_command; echo "ОШИБКА: команда обновления не найдена: $GO_UPDATE_CMD" >&2; exit 1; }

    if [ -z "$SELECTOR" ]; then
        case "$SLOT" in
            primary|backup) SELECTOR="$(slot_selector "$SLOT")" ;;
            *) SELECTOR="first" ;;
        esac
    fi
    validate_selector "$SELECTOR" || { history_log failed_update slot="$SLOT" selector="$SELECTOR" reason=invalid_selector; echo "ОШИБКА: некорректный selector: $SELECTOR" >&2; exit 1; }

    vless_go_acquire_lock "vless-go-failover:$SLOT"
    trap 'vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

    OLD_SLOT="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || echo unknown)"

    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$SOURCE_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
    printf '%s\n' "$SLOT" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true

    set +e
    if [ "$NO_RESTART" = "1" ]; then
        VLESS_GO_LOCK_HELD=1 "$GO_UPDATE_CMD" --source "$SOURCE_VALUE" --selector "$SELECTOR" --no-restart
    else
        VLESS_GO_LOCK_HELD=1 "$GO_UPDATE_CMD" --source "$SOURCE_VALUE" --selector "$SELECTOR"
    fi
    RC="$?"
    set -e

    if [ "$RC" -ne 0 ]; then
        history_log failed_switch action="$ACTION" from="$OLD_SLOT" to="$SLOT" selector="$SELECTOR" rc="$RC"
        exit "$RC"
    fi

    case "$ACTION" in
        switch) history_log manual_switch from="$OLD_SLOT" to="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
        update-active) history_log update_active_config slot="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
        *) history_log "$ACTION" slot="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
    esac

    echo "Активный VLESS слот: $SLOT"
    echo "Активный VLESS selector: $SELECTOR"
}

status() {
    echo "Статус failover-lite:"
    [ -s "$ACTIVE_STORE" ] && echo "  активный слот: $(sed -n '1p' "$ACTIVE_STORE")" || echo "  активный слот: неизвестен"
    if [ -s "$PRIMARY_STORE" ]; then
        echo "  основной профиль: настроен"
        echo "  selector основного профиля: $(slot_selector primary)"
    else
        echo "  основной профиль: не настроен"
    fi
    if [ -s "$BACKUP_STORE" ]; then
        echo "  резервный профиль: настроен"
        echo "  selector резервного профиля: $(slot_selector backup)"
    else
        echo "  резервный профиль: не настроен"
    fi
    [ -s "$SOURCE_STORE" ] && echo "  текущий источник: настроен" || echo "  текущий источник: не настроен"
}

case "${1:-status}" in
    status) status ;;
    set-primary) shift; parse_set_args "$@"; save_source primary "$SET_SOURCE" "$SET_SELECTOR" ;;
    set-backup) shift; parse_set_args "$@"; save_source backup "$SET_SOURCE" "$SET_SELECTOR" ;;
    set-selector) shift; [ "$#" -ge 2 ] || { echo "ОШИБКА: set-selector требует слот и selector" >&2; exit 1; }; save_selector "$1" "$2" ;;
    switch) shift; [ "$#" -ge 1 ] || { echo "ОШИБКА: switch требует primary или backup" >&2; exit 1; }; SLOT="$1"; shift; SOURCE_VALUE="$(slot_source "$SLOT")" || { history_log failed_switch to="$SLOT" reason=source_not_configured; echo "ОШИБКА: источник $SLOT не настроен" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "switch" "$@" ;;
    update-active) shift; if [ -s "$ACTIVE_STORE" ]; then SLOT="$(sed -n '1p' "$ACTIVE_STORE")"; SOURCE_VALUE="$(slot_source "$SLOT" 2>/dev/null || true)"; else SLOT="current"; SOURCE_VALUE=""; fi; [ -n "$SOURCE_VALUE" ] || SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE" 2>/dev/null || true)"; [ -n "$SOURCE_VALUE" ] || { history_log failed_update reason=no_active_source; echo "ОШИБКА: активный источник не найден" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "update-active" "$@" ;;
    sync-primary) [ -s "$SOURCE_STORE" ] || { echo "ОШИБКА: текущий источник не настроен" >&2; exit 1; }; save_source primary "$(sed -n '1p' "$SOURCE_STORE")" "first"; printf '%s\n' primary > "$ACTIVE_STORE"; chmod 600 "$ACTIVE_STORE" 2>/dev/null || true ;;
    -h|--help|help) usage ;;
    *) echo "ОШИБКА: неизвестная команда: $1" >&2; usage >&2; exit 1 ;;
esac
