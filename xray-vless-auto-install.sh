#!/bin/sh

set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"

echo
echo "======================================"
echo " Xray VLESS auto installer for Keenetic"
echo " curl-ready edition"
echo "======================================"
echo

read_tty() {
    prompt="$1"
    var_name="$2"

    printf "%s" "$prompt" >/dev/tty
    IFS= read -r value </dev/tty

    eval "$var_name=\$value"
}

detect_router_ip() {
    if [ -n "$ROUTER_IP" ]; then
        echo "$ROUTER_IP"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        for iface in br0 Bridge0 Home home lan0 lan br-lan; do
            ip -4 addr show dev "$iface" 2>/dev/null \
                | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
        done | awk 'NF { print; exit }'

        ip -4 addr show scope global 2>/dev/null \
            | awk '
                /inet / {
                    ip=$2
                    sub(/\/.*/, "", ip)
                    if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                        print ip
                        exit
                    }
                }
            '
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null \
            | awk '
                /inet / {
                    ip=""
                    for (i=1;i<=NF;i++) {
                        if ($i == "inet") {
                            ip=$(i+1)
                        } else if ($i ~ /^addr:/) {
                            ip=$i
                            sub(/^addr:/, "", ip)
                        }

                        if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                            print ip
                            exit
                        }
                    }
                }
            '
    fi
}

if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg not found. Entware is not available in this shell."
    exit 1
fi

ROUTER_LAN_IP="$(detect_router_ip | head -n 1)"

if [ -z "$ROUTER_LAN_IP" ]; then
    echo "Could not auto-detect router LAN IP."
    read_tty "Enter router LAN IP, for example 192.168.1.1: " ROUTER_LAN_IP
fi

if [ -z "$ROUTER_LAN_IP" ]; then
    echo "ERROR: router LAN IP is empty."
    exit 1
fi

SOCKS_HOST="$ROUTER_LAN_IP"

echo "Router LAN IP: $ROUTER_LAN_IP"
echo "Xray SOCKS5: $SOCKS_HOST:$SOCKS_PORT"
echo "Keenetic Proxy interface: $PROXY_IFACE"
echo

echo "[1/8] Updating Entware package list..."
opkg update

echo
echo "[2/8] Installing Xray and dependencies..."
opkg install ca-bundle python3 >/dev/null 2>&1 || true

if opkg install xray xray-core; then
    echo "Installed xray + xray-core."
elif opkg install xray-core; then
    echo "Installed xray-core."
else
    echo "ERROR: Could not install xray/xray-core from Entware."
    exit 1
fi

if command -v xray >/dev/null 2>&1; then
    XRAY_BIN="$(command -v xray)"
elif [ -x /opt/bin/xray ]; then
    XRAY_BIN="/opt/bin/xray"
else
    echo "ERROR: xray binary not found after installation."
    exit 1
fi

echo "Xray binary: $XRAY_BIN"

mkdir -p "$XRAY_DIR"

echo
echo "[3/8] Enter your VLESS link."
read_tty "VLESS link: " VLESS_URL

if [ -z "$VLESS_URL" ]; then
    echo "ERROR: empty VLESS link."
    exit 1
fi

export VLESS_URL XRAY_CONFIG SOCKS_HOST SOCKS_PORT

echo
echo "[4/8] Generating Xray config..."

python3 <<'PY'
import os
import json
import urllib.parse

url = os.environ["VLESS_URL"].strip()
config_path = os.environ["XRAY_CONFIG"]
socks_host = os.environ["SOCKS_HOST"]
socks_port = int(os.environ["SOCKS_PORT"])

u = urllib.parse.urlparse(url)

if u.scheme != "vless":
    raise SystemExit("ERROR: only vless:// links are supported")

uuid = urllib.parse.unquote(u.username or "")
server = u.hostname
port = u.port or 443
remark = urllib.parse.unquote(u.fragment or "vless-out")

if not uuid:
    raise SystemExit("ERROR: UUID is missing in VLESS link")

if not server:
    raise SystemExit("ERROR: server host is missing in VLESS link")

params = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))

network = params.get("type", "tcp")
security = params.get("security", "none")
encryption = params.get("encryption", "none")

user = {
    "id": uuid,
    "encryption": encryption
}

if params.get("flow"):
    user["flow"] = params["flow"]

stream = {
    "network": network,
    "security": security
}

if security == "tls":
    tls = {
        "serverName": params.get("sni", server),
        "allowInsecure": params.get("allowInsecure", "0").lower() in ("1", "true", "yes")
    }

    if params.get("alpn"):
        tls["alpn"] = params["alpn"].split(",")

    stream["tlsSettings"] = tls

elif security == "reality":
    reality = {
        "serverName": params.get("sni", server),
        "fingerprint": params.get("fp", "chrome"),
        "publicKey": params.get("pbk", ""),
        "shortId": params.get("sid", ""),
        "spiderX": urllib.parse.unquote(params.get("spx", "/"))
    }

    if not reality["publicKey"]:
        raise SystemExit("ERROR: REALITY public key pbk is missing")

    stream["realitySettings"] = reality

if network == "ws":
    stream["wsSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "headers": {}
    }

    if params.get("host"):
        stream["wsSettings"]["headers"]["Host"] = params["host"]

elif network == "grpc":
    stream["grpcSettings"] = {
        "serviceName": params.get("serviceName", ""),
        "multiMode": params.get("mode", "") == "multi"
    }

elif network == "tcp":
    header_type = params.get("headerType", "none")
    if header_type != "none":
        stream["tcpSettings"] = {
            "header": {
                "type": header_type
            }
        }

elif network == "httpupgrade":
    stream["httpupgradeSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "host": params.get("host", server)
    }

elif network == "splithttp":
    stream["splithttpSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "host": params.get("host", server)
    }

config = {
    "log": {
        "loglevel": "warning"
    },
    
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": socks_host,
            "port": socks_port,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": True
            },
            "sniffing": {
                "enabled": True,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "tag": remark,
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {
                        "address": server,
                        "port": port,
                        "users": [
                            user
                        ]
                    }
                ]
            },
            "streamSettings": stream
        },
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ]
}

os.makedirs(os.path.dirname(config_path), exist_ok=True)

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("Generated:", config_path)
print("Server:", server)
print("Port:", port)
print("Network:", network)
print("Security:", security)
print("Local SOCKS5:", f"{socks_host}:{socks_port}")
PY

echo
echo "[5/8] Creating Entware init script..."

cat > "$INIT_SCRIPT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
INIT

chmod +x "$INIT_SCRIPT"

echo
echo "[6/8] Validating Xray config..."
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"

echo
echo "[7/8] Starting Xray..."

"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
sleep 1
"$INIT_SCRIPT" start
sleep 2

if netstat -lnt 2>/dev/null | grep -q "$SOCKS_HOST:$SOCKS_PORT"; then
    echo "Xray SOCKS5 is listening on $SOCKS_HOST:$SOCKS_PORT"
elif netstat -lnt 2>/dev/null | grep -q "$SOCKS_PORT"; then
    echo "Xray SOCKS5 port $SOCKS_PORT is listening."
    echo "Check exact bind address:"
    echo "netstat -lntp | grep $SOCKS_PORT"
else
    echo "WARNING: SOCKS5 port $SOCKS_PORT was not found in netstat output."
    echo "Check manually:"
    echo "$INIT_SCRIPT status"
    echo "netstat -lntp | grep $SOCKS_PORT"
fi

echo
echo "[8/8] Creating Keenetic Proxy interface $PROXY_IFACE..."

if command -v ndmc >/dev/null 2>&1; then
    ndmc -c "interface $PROXY_IFACE" \
        && ndmc -c "interface $PROXY_IFACE proxy protocol socks5" \
        && ndmc -c "interface $PROXY_IFACE proxy socks5-udp" \
        && ndmc -c "interface $PROXY_IFACE proxy upstream $SOCKS_HOST $SOCKS_PORT" \
        && ndmc -c "interface $PROXY_IFACE description Xray" \
        && ndmc -c "interface $PROXY_IFACE up" \
        && ndmc -c "system configuration save"

    echo
    echo "Keenetic proxy interface created:"
    echo "$PROXY_IFACE -> SOCKS5 $SOCKS_HOST:$SOCKS_PORT"
else
    echo "ndmc not found."
    echo
    echo "Add manually in Keenetic web interface:"
    echo "Type: SOCKS5"
    echo "Host: $SOCKS_HOST"
    echo "Port: $SOCKS_PORT"
fi

echo
echo "======================================"
echo " DONE"
echo "======================================"
echo
echo "Router LAN IP:"
echo "$ROUTER_LAN_IP"
echo
echo "Xray config:"
echo "$XRAY_CONFIG"
echo
echo "Xray service:"
echo "$INIT_SCRIPT"
echo
echo "SOCKS5:"
echo "$SOCKS_HOST:$SOCKS_PORT"
echo
echo "Keenetic Proxy:"
echo "$PROXY_IFACE -> $SOCKS_HOST:$SOCKS_PORT"
echo
echo "Useful commands:"
echo "$INIT_SCRIPT status"
echo "$INIT_SCRIPT restart"
echo "$XRAY_BIN run -test -config $XRAY_CONFIG"
echo "netstat -lntp | grep $SOCKS_PORT"
echo "ndmc -c 'show running-config' | grep -i proxy"
echo
