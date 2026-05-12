# Shared VLESS Go lock helper. Source this file from shell commands.

VLESS_GO_LOCK_DIR="${VLESS_GO_LOCK_DIR:-/opt/var/run/vless-go.lock}"
VLESS_GO_LOCK_WAIT="${VLESS_GO_LOCK_WAIT:-30}"
VLESS_GO_LOCK_HELD_LOCAL="0"

vless_go_lock_is_pid_alive() {
    _pid="$1"
    case "$_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$_pid" 2>/dev/null
}

vless_go_cleanup_stale_lock() {
    [ -d "$VLESS_GO_LOCK_DIR" ] || return 0

    _pid="$(cat "$VLESS_GO_LOCK_DIR/pid" 2>/dev/null || true)"
    _owner="$(cat "$VLESS_GO_LOCK_DIR/owner" 2>/dev/null || echo unknown)"
    _created_at="$(cat "$VLESS_GO_LOCK_DIR/created_at" 2>/dev/null || echo unknown)"

    if ! vless_go_lock_is_pid_alive "$_pid"; then
        echo "Removing stale VLESS Go lock: path=$VLESS_GO_LOCK_DIR owner=$_owner pid=${_pid:-missing} created_at=$_created_at" >&2
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
        vless_go_cleanup_stale_lock

        if mkdir "$VLESS_GO_LOCK_DIR" 2>/dev/null; then
            VLESS_GO_LOCK_HELD_LOCAL="1"
            printf '%s\n' "$$" > "$VLESS_GO_LOCK_DIR/pid"
            printf '%s\n' "$_owner" > "$VLESS_GO_LOCK_DIR/owner"
            printf '%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" > "$VLESS_GO_LOCK_DIR/created_at"
            export VLESS_GO_LOCK_HELD=1
            trap 'vless_go_release_lock' EXIT INT TERM
            return 0
        fi

        _now="$(date +%s)"
        _elapsed="$((_now - _start))"
        if [ "$_elapsed" -ge "$VLESS_GO_LOCK_WAIT" ]; then
            _owner_text="$(cat "$VLESS_GO_LOCK_DIR/owner" 2>/dev/null || echo unknown)"
            _pid_text="$(cat "$VLESS_GO_LOCK_DIR/pid" 2>/dev/null || echo unknown)"
            _created_text="$(cat "$VLESS_GO_LOCK_DIR/created_at" 2>/dev/null || echo unknown)"
            echo "ERROR: VLESS Go lock is busy: owner=$_owner_text pid=$_pid_text created_at=$_created_text path=$VLESS_GO_LOCK_DIR" >&2
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
