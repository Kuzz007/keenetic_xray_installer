# Shared VLESS Go lock helper. Source this file from shell commands.

VLESS_GO_LOCK_DIR="${VLESS_GO_LOCK_DIR:-/opt/var/run/vless-go.lock}"
VLESS_GO_LOCK_WAIT="${VLESS_GO_LOCK_WAIT:-30}"
VLESS_GO_LOCK_HELD_LOCAL="0"

vless_go_lock_is_pid_alive() {
    _pid="$1"
    [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null
}

vless_go_cleanup_stale_lock() {
    [ -d "$VLESS_GO_LOCK_DIR" ] || return 0
    _pid="$(cat "$VLESS_GO_LOCK_DIR/pid" 2>/dev/null || true)"
    if ! vless_go_lock_is_pid_alive "$_pid"; then
        echo "Removing stale VLESS Go lock: $VLESS_GO_LOCK_DIR" >&2
        rm -rf "$VLESS_GO_LOCK_DIR" 2>/dev/null || true
    fi
}

vless_go_acquire_lock() {
    _owner="${1:-vless-go}"

    if [ "${VLESS_GO_LOCK_HELD:-0}" = "1" ]; then
        return 0
    fi

    mkdir -p "$(dirname "$VLESS_GO_LOCK_DIR")" 2>/dev/null || true
    _start="$(date +%s)"

    while true; do
        if mkdir "$VLESS_GO_LOCK_DIR" 2>/dev/null; then
            VLESS_GO_LOCK_HELD_LOCAL="1"
            printf '%s\n' "$$" > "$VLESS_GO_LOCK_DIR/pid"
            printf '%s\n' "$_owner" > "$VLESS_GO_LOCK_DIR/owner"
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$VLESS_GO_LOCK_DIR/created_at"
            export VLESS_GO_LOCK_HELD=1
            trap 'vless_go_release_lock' EXIT INT TERM
            return 0
        fi

        vless_go_cleanup_stale_lock

        _now="$(date +%s)"
        _elapsed="$((_now - _start))"
        if [ "$_elapsed" -ge "$VLESS_GO_LOCK_WAIT" ]; then
            _owner_text="$(cat "$VLESS_GO_LOCK_DIR/owner" 2>/dev/null || echo unknown)"
            _pid_text="$(cat "$VLESS_GO_LOCK_DIR/pid" 2>/dev/null || echo unknown)"
            echo "ERROR: VLESS Go lock is busy: owner=$_owner_text pid=$_pid_text path=$VLESS_GO_LOCK_DIR" >&2
            return 1
        fi

        sleep 1
    done
}

vless_go_release_lock() {
    if [ "$VLESS_GO_LOCK_HELD_LOCAL" = "1" ]; then
        _pid="$(cat "$VLESS_GO_LOCK_DIR/pid" 2>/dev/null || true)"
        if [ "$_pid" = "$$" ]; then
            rm -rf "$VLESS_GO_LOCK_DIR" 2>/dev/null || true
        fi
        VLESS_GO_LOCK_HELD_LOCAL="0"
    fi
}
