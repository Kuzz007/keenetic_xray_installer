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
    echo "Commands: status | set-primary SRC | set-backup SRC | switch primary|backup [--first] [--no-restart] | update-active [--first] [--no-restart] | sync-primary"
}

slot_file() {
    case "$1" in
        primary) echo "$PRIMARY_STORE" ;;
        backup) echo "$BACKUP_STORE" ;;
        *) return 1 ;;
    esac
}

slot_source() {
    FILE="$(slot_file "$1")" || return 1
    [ -s "$FILE" ] || return 2
    sed -n '1p' "$FILE"
}

save_source() {
    SLOT="$1"
    VALUE="$2"
    FILE="$(slot_file "$SLOT")" || { echo "ERROR: invalid slot: $SLOT" >&2; exit 1; }
    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$VALUE" > "$FILE"
    chmod 600 "$FILE" 2>/dev/null || true
    echo "Saved $SLOT source: $FILE"
}

parse_update_flags() {
    FIRST="0"
    NO_RESTART="0"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --first) FIRST="1"; shift ;;
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

    vless_go_acquire_lock "vless-go-failover:$SLOT"
    trap 'vless_go_release_lock 2>/dev/null || true' EXIT INT TERM

    mkdir -p "$XRAY_DIR"
    printf '%s\n' "$SOURCE_VALUE" > "$SOURCE_STORE"
    chmod 600 "$SOURCE_STORE" 2>/dev/null || true
    printf '%s\n' "$SLOT" > "$ACTIVE_STORE"
    chmod 600 "$ACTIVE_STORE" 2>/dev/null || true

    ARGS="--source $SOURCE_VALUE"
    [ "$FIRST" = "0" ] || ARGS="$ARGS --first"
    [ "$NO_RESTART" = "0" ] || ARGS="$ARGS --no-restart"

    # shellcheck disable=SC2086
    VLESS_GO_LOCK_HELD=1 "$GO_UPDATE_CMD" $ARGS
    echo "Active VLESS slot: $SLOT"
}

status() {
    echo "Failover-lite status:"
    [ -s "$ACTIVE_STORE" ] && echo "  active: $(sed -n '1p' "$ACTIVE_STORE")" || echo "  active: unknown"
    [ -s "$PRIMARY_STORE" ] && echo "  primary: configured" || echo "  primary: not configured"
    [ -s "$BACKUP_STORE" ] && echo "  backup: configured" || echo "  backup: not configured"
    [ -s "$SOURCE_STORE" ] && echo "  current source: configured" || echo "  current source: not configured"
}

case "${1:-status}" in
    status) status ;;
    set-primary) shift; [ "$#" -ge 1 ] || { echo "ERROR: set-primary requires source" >&2; exit 1; }; save_source primary "$1" ;;
    set-backup) shift; [ "$#" -ge 1 ] || { echo "ERROR: set-backup requires source" >&2; exit 1; }; save_source backup "$1" ;;
    switch) shift; [ "$#" -ge 1 ] || { echo "ERROR: switch requires primary or backup" >&2; exit 1; }; SLOT="$1"; shift; SOURCE_VALUE="$(slot_source "$SLOT")" || { echo "ERROR: $SLOT source is not configured" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    update-active) shift; if [ -s "$ACTIVE_STORE" ]; then SLOT="$(sed -n '1p' "$ACTIVE_STORE")"; SOURCE_VALUE="$(slot_source "$SLOT" 2>/dev/null || true)"; else SLOT="current"; SOURCE_VALUE=""; fi; [ -n "$SOURCE_VALUE" ] || SOURCE_VALUE="$(sed -n '1p' "$SOURCE_STORE" 2>/dev/null || true)"; [ -n "$SOURCE_VALUE" ] || { echo "ERROR: no active source found" >&2; exit 1; }; run_update "$SOURCE_VALUE" "$SLOT" "$@" ;;
    sync-primary) [ -s "$SOURCE_STORE" ] || { echo "ERROR: current source is not configured" >&2; exit 1; }; save_source primary "$(sed -n '1p' "$SOURCE_STORE")"; printf '%s\n' primary > "$ACTIVE_STORE"; chmod 600 "$ACTIVE_STORE" 2>/dev/null || true ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
