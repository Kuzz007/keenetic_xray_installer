#!/bin/sh

HISTORY_LOG="${HISTORY_LOG:-/opt/var/log/vless-go-switch-history.log}"
DEFAULT_LINES="${VLESS_GO_HISTORY_LINES:-80}"

usage() {
    echo "Usage: vless-go-history [show [N] | tail [N] | follow | path | log EVENT [key=value ...] | clear]"
    echo ""
    echo "Examples:"
    echo "  vless-go-history"
    echo "  vless-go-history tail 40"
    echo "  vless-go-history follow"
}

ensure_log() {
    mkdir -p "$(dirname "$HISTORY_LOG")" 2>/dev/null || true
    touch "$HISTORY_LOG" 2>/dev/null || true
    chmod 600 "$HISTORY_LOG" 2>/dev/null || true
}

sanitize_token() {
    printf '%s' "$1" | tr '\n\r\t ' '____' | sed 's/[^A-Za-z0-9_.:=,/@+-]/_/g'
}

write_event() {
    EVENT="$1"
    shift
    ensure_log
    LINE="$(date '+%Y-%m-%d %H:%M:%S') event=$(sanitize_token "$EVENT")"
    for KV in "$@"; do
        LINE="$LINE $(sanitize_token "$KV")"
    done
    printf '%s\n' "$LINE" >> "$HISTORY_LOG"
}

show_log() {
    ensure_log
    N="${1:-$DEFAULT_LINES}"
    case "$N" in ''|*[!0-9]*) N="$DEFAULT_LINES" ;; esac
    tail -n "$N" "$HISTORY_LOG" 2>/dev/null || true
}

case "${1:-show}" in
    show|tail)
        shift
        show_log "${1:-$DEFAULT_LINES}"
        ;;
    follow|-f)
        ensure_log
        tail -n "${2:-50}" -f "$HISTORY_LOG"
        ;;
    path)
        echo "$HISTORY_LOG"
        ;;
    log)
        shift
        [ "$#" -ge 1 ] || { echo "ERROR: event is required" >&2; usage >&2; exit 1; }
        EVENT="$1"
        shift
        write_event "$EVENT" "$@"
        ;;
    clear)
        ensure_log
        : > "$HISTORY_LOG"
        echo "Cleared: $HISTORY_LOG"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "ERROR: unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
