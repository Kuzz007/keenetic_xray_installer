#!/opt/bin/sh
set -eu

CONF="/opt/etc/xray/xray-go-agent.conf"
BIN="/opt/bin/xray-go-agent"
INIT="/opt/etc/init.d/S28xray-go-agent"
LOG="/opt/var/log/xray-go-agent.log"

mkdir -p /opt/etc/xray /opt/var/log

if [ ! -x "$BIN" ]; then
  echo "ERROR: $BIN not found or not executable" >&2
  echo "Install the release asset first, then rerun this installer." >&2
  exit 1
fi

if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'EOF'
SERVER_URL="https://control.example.com"
ROUTER_ID="home"
ROUTER_NAME="Дом"
AGENT_TOKEN="replace-with-long-random-token"
POLL_INTERVAL="5"
EOF
  chmod 600 "$CONF"
  echo "Created config: $CONF"
  echo "Edit SERVER_URL, ROUTER_ID, ROUTER_NAME and AGENT_TOKEN before starting."
fi

cat > "$INIT" <<'EOF'
#!/opt/bin/sh

ENABLED=yes
PROCS=xray-go-agent
ARGS="-config /opt/etc/xray/xray-go-agent.conf"
PREARGS=""
DESC="Xray Go Agent"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
chmod +x "$INIT"
touch "$LOG"

echo "Installed init service: $INIT"
echo "Config: $CONF"
echo "Commands:"
echo "  $INIT start"
echo "  $INIT stop"
echo "  $INIT restart"
echo "  $INIT status"
