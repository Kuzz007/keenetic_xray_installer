#!/bin/sh
set -e

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_UPDATE_CMD="${GO_UPDATE_CMD:-/opt/bin/vless-go-update}"
HISTORY_CMD="${HISTORY_CMD:-/opt/bin/vless-go-history}"
LOCK_HELPER="${LOCK_HELPER:-/opt/libexec/vless-go-lock.sh}"
AWG_RUNTIME_STATE="$XRAY_DIR/awg/runtime.json"
AWG_PROFILE_DIR="$XRAY_DIR/awg/profiles"
AWG_SLOT_CMD="${AWG_SLOT_CMD:-/opt/bin/keenetic-awg-slot}"

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
    echo "  set-awg primary|backup --input FILE|-"
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

type_file() {
    case "$1" in
        primary|backup) echo "$XRAY_DIR/vpn-slot.$1.type" ;;
        *) return 1 ;;
    esac
}

slot_type() {
    SLOT="$1"
    FILE="$(type_file "$SLOT")" || return 1
    VALUE="$(sed -n '1p' "$FILE" 2>/dev/null || true)"
    case "$VALUE" in
        vless|awg) printf '%s\n' "$VALUE"; return 0 ;;
    esac
    if [ -s "$(slot_file "$SLOT")" ]; then
        echo vless
        return 0
    fi
    if [ -s "$AWG_PROFILE_DIR/$SLOT.conf" ]; then
        echo awg
        return 0
    fi
    echo unknown
}

save_slot_type() {
    SLOT="$1"
    VALUE="$2"
    FILE="$(type_file "$SLOT")" || return 1
    case "$VALUE" in vless|awg) ;; *) return 1 ;; esac
    mkdir -p "$XRAY_DIR"
    TMP="$FILE.tmp.$$"
    printf '%s\n' "$VALUE" > "$TMP"
    chmod 600 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$FILE"
}

write_active_slot() {
    SLOT="$1"
    case "$SLOT" in primary|backup) ;; *) return 1 ;; esac
    mkdir -p "$XRAY_DIR"
    TMP="$ACTIVE_STORE.tmp.$$"
    printf '%s\n' "$SLOT" > "$TMP"
    chmod 600 "$TMP" 2>/dev/null || true
    mv -f "$TMP" "$ACTIVE_STORE"
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
    ACTIVE="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    if [ -s "$AWG_RUNTIME_STATE" ] && [ "$ACTIVE" = "$SLOT" ]; then
        echo "ERROR: active AWG slot $SLOT cannot be replaced; switch to the other slot first." >&2
        exit 1
    fi
    FILE="$(slot_file "$SLOT")" || { echo "ОШИБКА: некорректный слот: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Источник $SLOT сохранён: $FILE"
    save_selector "$SLOT" "$SELECTOR"
    save_slot_type "$SLOT" vless
}

set_awg_profile() {
    [ "$#" -ge 1 ] || { echo "ERROR: set-awg requires primary or backup" >&2; exit 1; }
    SLOT="$1"
    shift
    case "$SLOT" in primary|backup) ;; *) echo "ERROR: invalid AWG slot: $SLOT" >&2; exit 1 ;; esac
    INPUT="-"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --input)
                [ "$#" -ge 2 ] || { echo "ERROR: --input requires FILE or -" >&2; exit 1; }
                INPUT="$2"
                shift 2
                ;;
            *) echo "ERROR: unknown set-awg argument: $1" >&2; exit 1 ;;
        esac
    done
    [ -x "$AWG_SLOT_CMD" ] || { echo "ERROR: AWG slot manager is not installed: $AWG_SLOT_CMD" >&2; exit 1; }
    ACTIVE="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    if [ "$ACTIVE" = "$SLOT" ]; then
        echo "ERROR: configure AWG only in the inactive slot; switch to the other slot first." >&2
        exit 1
    fi
    "$AWG_SLOT_CMD" import --slot "$SLOT" --input "$INPUT"
    save_slot_type "$SLOT" awg
    echo "AWG profile staged in $SLOT; active slot ${ACTIVE:-unknown} was not changed."
}

apply_source_if_active() {
    SLOT="$1"
    SELECTOR="${2:-first}"
    ACTIVE="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    if [ "$ACTIVE" != "$SLOT" ]; then
        echo "Источник $SLOT сохранён, но не применён: активный слот ${ACTIVE:-unknown}."
        echo "Чтобы применить позже: vless-go-failover switch $SLOT"
        return 0
    fi
    SOURCE_VALUE="$(slot_source "$SLOT")" || { echo "ОШИБКА: источник $SLOT не настроен" >&2; exit 1; }
    echo "Активный слот $SLOT изменён; применяю новый источник к Xray config..."
    run_update "$SOURCE_VALUE" "$SLOT" "set-active-source" --selector "$SELECTOR"
    echo "Источник $SLOT сохранён и применён."
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
    NO_RESTART="0"
    SELECTOR=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --first) SELECTOR="first"; shift ;;
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

    if [ -s "$AWG_RUNTIME_STATE" ]; then
        echo "ERROR: isolated AWG slot owns Xray; deactivate or recover AWG before switching VLESS." >&2
        exit 1
    fi

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

    # Important safety rule:
    # Do not change active/source state before config generation and validation succeed.
    # vless-go-update writes $SOURCE_STORE only after successful resolver + xray -test.
    # ACTIVE_STORE is written below only after vless-go-update returns 0.
    mkdir -p "$XRAY_DIR"

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
        echo "ОШИБКА: переключение на $SLOT не применено; active/source state не изменён." >&2
        exit "$RC"
    fi

    printf '%s\n' "$SOURCE_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
    printf '%s\n' "$SLOT" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true

    case "$ACTION" in
        switch) history_log manual_switch from="$OLD_SLOT" to="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
        update-active) history_log update_active_config slot="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
        set-active-source) history_log set_active_source slot="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
        *) history_log "$ACTION" slot="$SLOT" selector="$SELECTOR" no_restart="$NO_RESTART" ;;
    esac

    echo "Активный VLESS слот: $SLOT"
    echo "Активный VLESS selector: $SELECTOR"
}

rollback_to_awg_slot() {
    SLOT="$1"
    [ "$(slot_type "$SLOT")" = "awg" ] || return 0
    echo "Rolling back to the previous AWG slot: $SLOT" >&2
    if "$AWG_SLOT_CMD" activate --slot "$SLOT"; then
        write_active_slot "$SLOT"
        return 0
    fi
    echo "ERROR: rollback to AWG slot $SLOT failed; run keenetic-awg-slot recover." >&2
    return 1
}

switch_to_awg() {
    SLOT="$1"
    OLD_SLOT="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    if [ -s "$AWG_RUNTIME_STATE" ]; then
        if [ "$OLD_SLOT" = "$SLOT" ]; then
            "$AWG_SLOT_CMD" status --slot "$SLOT"
            echo "AWG slot $SLOT is already active."
            return 0
        fi
        "$AWG_SLOT_CMD" deactivate
    fi

    set +e
    "$AWG_SLOT_CMD" activate --slot "$SLOT"
    RC="$?"
    set -e
    if [ "$RC" -ne 0 ]; then
        rollback_to_awg_slot "$OLD_SLOT" || true
        history_log failed_switch action=switch from="${OLD_SLOT:-unknown}" to="$SLOT" type=awg rc="$RC"
        return "$RC"
    fi
    if ! write_active_slot "$SLOT"; then
        "$AWG_SLOT_CMD" deactivate || true
        rollback_to_awg_slot "$OLD_SLOT" || true
        echo "ERROR: AWG activated but active slot state could not be committed." >&2
        return 1
    fi
    history_log manual_switch from="${OLD_SLOT:-unknown}" to="$SLOT" type=awg
    echo "Active VPN slot: $SLOT (AWG)"
}

switch_to_vless() {
    SLOT="$1"
    SOURCE_VALUE="$2"
    shift 2
    OLD_SLOT="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
    HAD_AWG=0
    if [ -s "$AWG_RUNTIME_STATE" ]; then
        HAD_AWG=1
        "$AWG_SLOT_CMD" deactivate
    fi

    set +e
    (run_update "$SOURCE_VALUE" "$SLOT" "switch" "$@")
    RC="$?"
    set -e
    if [ "$RC" -ne 0 ]; then
        if [ "$HAD_AWG" = 1 ]; then
            rollback_to_awg_slot "$OLD_SLOT" || true
        fi
        return "$RC"
    fi
}

switch_typed() {
    SLOT="$1"
    shift
    case "$SLOT" in primary|backup) ;; *) echo "ERROR: invalid VPN slot: $SLOT" >&2; exit 1 ;; esac
    TYPE="$(slot_type "$SLOT")"
    case "$TYPE" in
        awg)
            [ "$#" -eq 0 ] || { echo "ERROR: AWG switch does not accept VLESS selector flags" >&2; exit 1; }
            [ -x "$AWG_SLOT_CMD" ] || { echo "ERROR: AWG slot manager is not installed: $AWG_SLOT_CMD" >&2; exit 1; }
            [ -s "$AWG_PROFILE_DIR/$SLOT.conf" ] || { echo "ERROR: AWG profile $SLOT is not configured" >&2; exit 1; }
            switch_to_awg "$SLOT"
            ;;
        vless)
            SOURCE_VALUE="$(slot_source "$SLOT")" || { echo "ERROR: VLESS source $SLOT is not configured" >&2; exit 1; }
            switch_to_vless "$SLOT" "$SOURCE_VALUE" "$@"
            ;;
        *)
            history_log failed_switch to="$SLOT" reason=profile_not_configured
            echo "ERROR: VPN slot $SLOT is not configured" >&2
            exit 1
            ;;
    esac
}

update_active_typed() {
    if [ -s "$ACTIVE_STORE" ]; then
        SLOT="$(sed -n '1p' "$ACTIVE_STORE")"
    else
        SLOT="current"
    fi
    if [ "$SLOT" != "current" ] && [ "$(slot_type "$SLOT")" = "awg" ]; then
        echo "Active AWG slot $SLOT has no VLESS subscription to update."
        return 0
    fi
    SOURCE_VALUE=""
    if [ "$SLOT" != "current" ]; then
        SOURCE_VALUE="$(slot_source "$SLOT" 2>/dev/null || true)"
    fi
    [ -n "$SOURCE_VALUE" ] || SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE" 2>/dev/null || true)"
    [ -n "$SOURCE_VALUE" ] || { history_log failed_update reason=no_active_source; echo "ОШИБКА: активный источник не найден" >&2; exit 1; }
    run_update "$SOURCE_VALUE" "$SLOT" "update-active" "$@"
}

print_slot_status() {
    SLOT="$1"
    LABEL="$2"
    TYPE="$(slot_type "$SLOT")"
    case "$TYPE" in
        vless)
            if [ -s "$(slot_file "$SLOT")" ]; then
                echo "  $LABEL профиль: настроен (VLESS)"
                echo "  selector $LABEL профиля: $(slot_selector "$SLOT")"
            else
                echo "  $LABEL профиль: повреждён (VLESS source missing)"
            fi
            ;;
        awg)
            if [ -s "$AWG_PROFILE_DIR/$SLOT.conf" ]; then
                echo "  $LABEL профиль: настроен (AWG)"
            else
                echo "  $LABEL профиль: повреждён (AWG profile missing)"
            fi
            ;;
        *) echo "  $LABEL профиль: не настроен" ;;
    esac
}

status() {
    echo "Статус failover-lite:"
    [ -s "$ACTIVE_STORE" ] && echo "  активный слот: $(sed -n '1p' "$ACTIVE_STORE")" || echo "  активный слот: неизвестен"
    print_slot_status primary "основной"
    print_slot_status backup "резервный"
    if [ -s "$ACTIVE_STORE" ] && [ "$(slot_type "$(sed -n '1p' "$ACTIVE_STORE")")" = "awg" ]; then
        echo "  текущий транспорт: AWG"
    elif [ -s "$SOURCE_STORE" ]; then
        echo "  текущий источник: настроен (VLESS)"
    else
        echo "  текущий источник: не настроен"
    fi
}

if [ "${VLESS_GO_FAILOVER_LIB_ONLY:-0}" != 1 ]; then
case "${1:-status}" in
    status) status ;;
    set-primary) shift; parse_set_args "$@"; save_source primary "$SET_SOURCE" "$SET_SELECTOR"; apply_source_if_active primary "$SET_SELECTOR" ;;
    set-backup) shift; parse_set_args "$@"; save_source backup "$SET_SOURCE" "$SET_SELECTOR"; apply_source_if_active backup "$SET_SELECTOR" ;;
    set-awg) shift; set_awg_profile "$@" ;;
    set-selector) shift; [ "$#" -ge 2 ] || { echo "ОШИБКА: set-selector требует слот и selector" >&2; exit 1; }; save_selector "$1" "$2" ;;
    switch) shift; [ "$#" -ge 1 ] || { echo "ОШИБКА: switch требует primary или backup" >&2; exit 1; }; SLOT="$1"; shift; switch_typed "$SLOT" "$@" ;;
    update-active) shift; update_active_typed "$@" ;;
    sync-primary) [ -s "$SOURCE_STORE" ] || { echo "ОШИБКА: текущий источник не настроен" >&2; exit 1; }; save_source primary "$(sed -n '1p' "$SOURCE_STORE")" "first"; write_active_slot primary ;;
    -h|--help|help) usage ;;
    *) echo "ОШИБКА: неизвестная команда: $1" >&2; usage >&2; exit 1 ;;
esac
fi
