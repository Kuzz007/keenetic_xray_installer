#!/bin/sh
set -e

WATCHDOG_BRANCH="${WATCHDOG_BRANCH:-main}"
WATCHDOG_URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${WATCHDOG_BRANCH}/scripts/vless-go-watchdog.sh}"
WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
WATCHDOG_CONF="/opt/etc/xray/vless-go-watchdog.conf"
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

mkdir -p /opt/bin /opt/etc/init.d /opt/etc/xray /opt/var/log /opt/var/run /opt/var/spool/cron/crontabs

echo "Installing VLESS Go watchdog from: $WATCHDOG_URL"
if ! curl -fL -o "$WATCHDOG_CMD" "$WATCHDOG_URL"; then
    echo "ERROR: failed to download watchdog script." >&2
    exit 1
fi

chmod +x "$WATCHDOG_CMD"

if [ ! -f "$WATCHDOG_CONF" ]; then
    cat > "$WATCHDOG_CONF" <<CONF
# VLESS Go watchdog settings.
WATCHDOG_INTERVAL=15
FAILOVER_FAILURES_REQUIRED=2
CHECK_RETRIES=2
CHECK_RETRY_DELAY=2
CHECK_URLS="http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204"
AUTO_RECOVER_PRIMARY=0
RECOVERY_SUCCESSES_REQUIRED=2
RECOVERY_COOLDOWN_CYCLES=2
RECOVERY_TEST_PORT=18080
POST_SWITCH_DELAY=5
PROXY0_REFRESH=0
CONF
    chmod 600 "$WATCHDOG_CONF" 2>/dev/null || true
else
    grep -q '^CHECK_URLS=' "$WATCHDOG_CONF" || echo 'CHECK_URLS="http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204"' >> "$WATCHDOG_CONF"
    grep -q '^POST_SWITCH_DELAY=' "$WATCHDOG_CONF" || echo 'POST_SWITCH_DELAY=5' >> "$WATCHDOG_CONF"
    grep -q '^PROXY0_REFRESH=' "$WATCHDOG_CONF" || echo 'PROXY0_REFRESH=0' >> "$WATCHDOG_CONF"
fi

cat > "$WATCHDOG_INIT" <<INIT
#!/bin/sh

ENABLED=yes
DESC="VLESS Go Watchdog"
DAEMON="$WATCHDOG_CMD"
CONFIG="$WATCHDOG_CONF"
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

    if [ -f "\$CONFIG" ]; then
        . "\$CONFIG"
        export WATCHDOG_INTERVAL FAILOVER_FAILURES_REQUIRED CHECK_RETRIES CHECK_RETRY_DELAY CHECK_URL CHECK_URLS AUTO_RECOVER_PRIMARY RECOVERY_SUCCESSES_REQUIRED RECOVERY_COOLDOWN_CYCLES RECOVERY_TEST_PORT POST_SWITCH_DELAY PROXY0_REFRESH PROXY_IFACE
    fi

    "\$DAEMON" daemon >/dev/null 2>&1 &
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
echo "Config file: $WATCHDOG_CONF"
echo ""
echo "Commands:"
echo "  vless-go-watchdog status"
echo "  vless-go-watchdog check"
echo "  vless-go-watchdog run-backup"
echo "  vless-go-watchdog run-primary"
echo "  vless-go-watchdog probe-primary"
echo "  vless-go-watchdog daemon"
echo "  $WATCHDOG_INIT start"
echo "  $WATCHDOG_INIT stop"
echo "  $WATCHDOG_INIT status"
echo ""
echo "Default daemon behavior:"
echo "  - checks SOCKS 127.0.0.1:10808 every 15 seconds"
echo "  - requires 2 failed daemon cycles before switching primary -> backup"
echo "  - each cycle has 2 curl attempts with 2s retry delay"
echo "  - waits 5 seconds after switch before post-switch health check"
echo "  - backup -> primary recovery is disabled by default in helper installer"
echo ""
echo "Enable safe backup -> primary recovery:"
echo "  sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' $WATCHDOG_CONF"
echo "  $WATCHDOG_INIT restart"
echo ""
echo "Optional Proxy0 refresh after switch:"
echo "  sed -i 's/^PROXY0_REFRESH=.*/PROXY0_REFRESH=1/' $WATCHDOG_CONF"
echo "  $WATCHDOG_INIT restart"
