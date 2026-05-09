#!/bin/sh
set -e

WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-main}"
WATCHDOG_URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/scripts/vless-go-watchdog.sh}"
WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_PID="/opt/var/run/vless-go-watchdog.pid"

if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg not found. Entware is required." >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle
else
    opkg install ca-bundle >/dev/null 2>&1 || true
fi

mkdir -p /opt/bin /opt/etc/init.d /opt/var/log /opt/var/run /opt/var/spool/cron/crontabs

echo "Installing VLESS Go watchdog from: $WATCHDOG_URL"
if ! curl -fL -o "$WATCHDOG_CMD" "$WATCHDOG_URL"; then
    echo "ERROR: failed to download watchdog script." >&2
    exit 1
fi

chmod +x "$WATCHDOG_CMD"

cat > "$WATCHDOG_INIT" <<INIT
#!/bin/sh

ENABLED=yes
DESC="VLESS Go Watchdog"
DAEMON="$WATCHDOG_CMD"
PIDFILE="$WATCHDOG_PID"
LOGFILE="$WATCHDOG_LOG"

mkdir -p /opt/var/run /opt/var/log

is_running() {
    [ -f "\$PIDFILE" ] || return 1
    PID="\$(cat "\$PIDFILE" 2>/dev/null)"
    [ -n "\$PID" ] || return 1
    kill -0 "\$PID" 2>/dev/null
}

start() {
    printf " Starting %s... " "\$DESC"

    if is_running; then
        echo "already running."
        exit 0
    fi

    if [ ! -x "\$DAEMON" ]; then
        echo "error."
        echo "Daemon not found or not executable: \$DAEMON"
        exit 1
    fi

    "\$DAEMON" daemon >> "\$LOGFILE" 2>&1 &
    echo "\$!" > "\$PIDFILE"

    sleep 2

    if is_running; then
        echo "done."
        exit 0
    fi

    echo "error."
    tail -n 30 "\$LOGFILE" 2>/dev/null || true
    rm -f "\$PIDFILE"
    exit 1
}

stop() {
    printf " Stopping %s... " "\$DESC"

    if ! is_running; then
        echo "not running."
        rm -f "\$PIDFILE"
        exit 0
    fi

    PID="\$(cat "\$PIDFILE")"
    kill "\$PID" 2>/dev/null || true
    sleep 2

    if kill -0 "\$PID" 2>/dev/null; then
        kill -9 "\$PID" 2>/dev/null || true
    fi

    rm -f "\$PIDFILE"
    echo "done."
}

status() {
    printf " Checking %s... " "\$DESC"
    if is_running; then
        echo "alive. PID: \$(cat "\$PIDFILE")"
        exit 0
    fi
    echo "not running."
    exit 1
}

restart() {
    "\$0" stop
    sleep 1
    "\$0" start
}

case "\$1" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    *) echo "Usage: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
INIT

chmod +x "$WATCHDOG_INIT"

echo "Installed: $WATCHDOG_CMD"
echo "Installed init service: $WATCHDOG_INIT"
echo ""
echo "Commands:"
echo "  vless-go-watchdog status"
echo "  vless-go-watchdog check"
echo "  vless-go-watchdog run-backup"
echo "  vless-go-watchdog run-primary"
echo "  vless-go-watchdog daemon"
echo "  $WATCHDOG_INIT start"
echo "  $WATCHDOG_INIT stop"
echo "  $WATCHDOG_INIT status"
echo ""
echo "Default daemon behavior:"
echo "  - checks SOCKS 127.0.0.1:10808 every 15 seconds"
echo "  - requires 2 failed daemon cycles before switching primary -> backup"
echo "  - each cycle has 2 curl attempts with 2s retry delay"
echo "  - does not automatically switch from backup back to primary yet"
