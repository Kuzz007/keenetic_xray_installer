#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
LOCK_HELPER="/opt/libexec/vless-go-lock.sh"

if [ -s "$LOCK_HELPER" ]; then
    . "$LOCK_HELPER"
else
    vless_go_acquire_lock() { return 0; }
fi

usage() {
    echo "Usage: vless-go-failover COMMAND [ARGS]"
    echo "Commands:"
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
    validate_selector "$VALUE" || { echo "ERROR: invalid selector: $VALUE (supported: first, index:N)" >&2; exit 1; }
    FILE="$(selector_file "$SLOT")" || { echo "ERROR: invalid slot: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Saved $SLOT selector: $VALUE"
}

save_source() {
    SLOT="$1"
    VALUE="$2"
    SELECTOR="${3:-first}"
    FILE="$(slot_file "$SLOT")" || { echo "ERROR: invalid slot: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Saved $SLOT source: $FILE"
    save_selector "$SLOT" "$SELECTOR"
}

parse_set_args() {
    SET_SOURCE=""
    SET_SELECTOR="first"
    [ "$#" -ge 1 ] || { echo "ERROR: source is required" >&2; exit 1; }
    SET_SOURCE="$1"
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --selector)
                [ "$#" -ge 2 ] || { echo "ERROR: --selector requires value" >&2; exit 1; }
                SET_SELECTOR="$2"
                shift 2
                ;;
            --first)
                SET_SELECTOR="first"
                shift
                ;;
            *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
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
                [ "$#" -ge 2 ] || { echo "ERROR: --selector requires value" >&2; exit 1; }
                SELECTOR="$2"
                shift 2
                ;;
            --no-restart) NO_RESTART="1"; shift ;;
            *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
}

run_update() {
    SOURCE_VALUE="$1"
    SLOT="$2"
    shift 2
    parse_update_flags "$@"

    [ -x "$GO_UPDATE_CMD" ] || { echo "ERROR: update command not found: $GO_UPDATE_CMD" >&2; exit 1; }

    if [ -z "$SELECTOR" ]; then
        case "$SLOT" in
            primary|backup) SELECTOR="$(slot_selector "$SLOT")" ;;
            *) SELECTOR="first" ;;
        esac
    fi
    validate_selector "$SELECTOR" || { echo "ERROR: invalid selector: $SELECTOR" >&2; exit 1; }

    vless_go_acquire_lock "vless-go-failover:$SLOT"
    trap 'vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$SOURCE_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
    printf '%s\n' "$SLOT" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true

    ARGS="--source $SOURCE_VALUE --selector $SELECTOR"
    [ "$NO_RESTART" = "0" ] || ARGS="$ARGS --no-restart"

    # shellcheck disable=SC2086
    VLESS_GO_LOCK_HELD=1 "$GO_UPDATE_CMD" $ARGS
    echo "Active VLESS slot: $SLOT"
    echo "Active VLESS selector: $SELECTOR"
}

status() {
    echo "Failover-lite status:"
    [ -s "$ACTIVE_STORE" ] && echo "  active: $(sed -n '1p' "$ACTIVE_STORE")" || echo "  active: unknown"
    if [ -s "$PRIMARY_STORE" ]; then
        echo "  primary: configured"
        echo "  primary selector: $(slot_selector primary)"
    else
        echo "  primary: not configured"
    fi
    if [ -s "$BACKUP_STORE" ]; then
        echo "  backup: configured"
        echo "  backup selector: $(slot_selector backup)"
    else
        echo "  backup: not configured"
    fi
    [ -s "$SOURCE_STORE" ] && echo "  current source: configured" || echo "  current source: not configured"
}

case "${1:-status}" in
    status) status ;;
    set-primary) shift; parse_set_args "$@"; save_source primary "$SET_SOURCE" "$SET_SELECTOR" ;;
    set-backup) shift; parse_set_args "$@"; save_source backup "$SET_SOURCE" "$SET_SELECTOR" ;;
    set-selector) shift; [ "$#" -ge 2 ] || { echo "ERROR: set-selector requires slot and selector" >&2; exit 1; }; save_selector "$1" "$2" ;;
    switch) shift; [ "$#" -ge 1 ] || { echo "ERROR: switch requires primary or backup" >&2; exit 1; }; SLOT="$1"; shift; SOURCE_VALUE="$(slot_source "$SLOT")" || { echo "ERROR: $SLOT source is not configured" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    update-active) shift; if [ -s "$ACTIVE_STORE" ]; then SLOT="$(sed -n '1p' "$ACTIVE_STORE")"; SOURCE_VALUE="$(slot_source "$SLOT" 2>/dev/null || true)"; else SLOT="current"; SOURCE_VALUE=""; fi; [ -n "$SOURCE_VALUE" ] || SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE" 2>/dev/null || true)"; [ -n "$SOURCE_VALUE" ] || { echo "ERROR: no active source found" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    sync-primary) [ -s "$SOURCE_STORE" ] || { echo "ERROR: current source is not configured" >&2; exit 1; }; save_source primary "$(sed -n '1p' "$SOURCE_STORE")" "first"; printf '%s\n' primary > "$ACTIVE_STORE"; chmod 600 "$ACTIVE_STORE" 2>/dev/null || true ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
