#!/bin/sh

set -e

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

APP_NAME="Xray VLESS Failover for Keenetic"
VERSION="2026-05-07-final"

XRAY_DIR="/opt/etc/xray"
XRAY_MAIN_DIR="/opt/etc/xray-main"
TMP_DIR="/opt/tmp"
LOG_DIR="/opt/var/log"
RUN_DIR="/opt/var/run"

XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"

XRAY_MAIN_CONFIG="$XRAY_MAIN_DIR/config.json"
XRAY_MAIN_URL_STORE="$XRAY_MAIN_DIR/vless-main.url"
XRAY_MAIN_ROUTER_IP_STORE="$XRAY_MAIN_DIR/router-lan-ip"

GENERATOR="/opt/bin/xray-vless-generate-config"
FAILOVER_DAEMON="/opt/bin/xray-vless-failover-daemon"

INIT_XRAY="/opt/etc/init.d/S24xray"
INIT_FAILOVER="/opt/etc/init.d/S25xray-failover"
INIT_XRAY_MAIN="/opt/etc/init.d/S23xray-main"
INIT_XRAY_WATCHDOG="/opt/etc/init.d/S27xray-watchdog"
INIT_PROXY0_WATCHDOG="/opt/etc/init.d/S28xray-proxy0-watchdog"

SOCKS_PORT="10808"
MAIN_PORT="10809"
PROXY0_IFACE="Proxy0"
PROXY1_IFACE="Proxy1"
PROXY0_DESC="Xray-Failover"
PROXY1_DESC="Xray_main"
PROXY0_PRIORITY="16375"
PROXY1_PRIORITY="16374"

CHECK_URL="https://www.gstatic.com/generate_204"
CHECK_INTERVAL="10"

REUSE="0"
INSTALL_XRAY_MAIN="ask"
INSTALL_WEBUI="ask"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reuse|--reuse-failover)
            REUSE="1"
            ;;
        --no-xray-main)
            INSTALL_XRAY_MAIN="no"
            ;;
        --with-xray-main)
            INSTALL_XRAY_MAIN="yes"
            ;;
        --with-webui)
            INSTALL_WEBUI="yes"
            ;;
        --no-webui)
            INSTALL_WEBUI="no"
            ;;
        --help|-h)
            echo "Usage: $0 [--reuse|--reuse-failover] [--with-xray-main|--no-xray-main] [--with-webui|--no-webui]"
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1"
            echo "Usage: $0 [--reuse|--reuse-failover] [--with-xray-main|--no-xray-main] [--with-webui|--no-webui]"
            exit 1
            ;;
    esac
    shift
done

mkdir -p "$XRAY_DIR" "$XRAY_MAIN_DIR" "$TMP_DIR" "$LOG_DIR" "$RUN_DIR" /opt/bin /opt/etc/init.d /opt/backup/xray-core /opt/backup/xray-failover

say() { echo "$*"; }

read_tty() {
    prompt="$1"
    var_name="$2"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r value </dev/tty
    else
        printf "%s" "$prompt"
        IFS= read -r value
    fi
    eval "$var_name=\$value"
}

backup_file() {
    f="$1"
    if [ -f "$f" ]; then
        cp "$f" "$f.bak.$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo backup)" 2>/dev/null || true
    fi
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo "/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

detect_router_ip() {
    if [ -s "$ROUTER_IP_STORE" ]; then
        cat "$ROUTER_IP_STORE"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        for iface in br0 Bridge0 Home home lan0 lan br-lan GigabitEthernet0/Vlan1; do
            ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
        done | awk 'NF { print; exit }'

        ip -4 addr show scope global 2>/dev/null | awk '
            /inet / {
                ip=$2
                sub(/\/.*/, "", ip)
                if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                    print ip
                    exit
                }
            }'
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '
            /inet / {
                ip=""
                for (i=1;i<=NF;i++) {
                    if ($i == "inet") ip=$(i+1)
                    else if ($i ~ /^addr:/) { ip=$i; sub(/^addr:/, "", ip) }
                    if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                        print ip
                        exit
                    }
                }
            }'
    fi
}

stop_old_services() {
    "$INIT_PROXY0_WATCHDOG" stop >/dev/null 2>&1 || true
    "$INIT_XRAY_WATCHDOG" stop >/dev/null 2>&1 || true
    "$INIT_FAILOVER" stop >/dev/null 2>&1 || true
    "$INIT_XRAY_MAIN" stop >/dev/null 2>&1 || true
    "$INIT_XRAY" stop >/dev/null 2>&1 || true
    /opt/etc/init.d/S26xray-link-monitor stop >/dev/null 2>&1 || true

    old_pids="$(ps | grep '/opt/etc/xray-keenetic' | grep -v grep | awk '{print $1}')"
    for p in $old_pids; do kill "$p" 2>/dev/null || true; done

    check_pids="$(ps | grep 'xray-check-' | grep -v grep | awk '{print $1}')"
    for p in $check_pids; do kill "$p" 2>/dev/null || true; done
}

ensure_packages() {
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is not available."
        exit 1
    fi

    need_update="0"
    command -v curl >/dev/null 2>&1 || need_update="1"
    command -v python3 >/dev/null 2>&1 || need_update="1"
    command -v unzip >/dev/null 2>&1 || need_update="1"
    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
        need_update="1"
    fi

    [ "$need_update" = "1" ] && opkg update

    command -v curl >/dev/null 2>&1 || opkg install curl ca-bundle ca-certificates
    command -v python3 >/dev/null 2>&1 || opkg install python3
    command -v unzip >/dev/null 2>&1 || opkg install unzip
    opkg install ca-bundle ca-certificates >/dev/null 2>&1 || true

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/sbin/xray ] && [ ! -x /opt/bin/xray ]; then
        opkg install xray xray-core || opkg install xray-core || opkg install xray_nohf || opkg install xray-core_nohf
    fi

    XRAY_BIN="$(get_xray_bin)"
    if [ -z "$XRAY_BIN" ]; then
        echo "ERROR: xray binary not found after install."
        exit 1
    fi
}

prepare_links() {
    ROUTER_LAN_IP="$(detect_router_ip | head -n 1)"
    [ -z "$ROUTER_LAN_IP" ] && read_tty "Введите LAN-IP роутера, например 192.168.1.1: " ROUTER_LAN_IP
    [ -z "$ROUTER_LAN_IP" ] && { echo "ERROR: router LAN IP is empty."; exit 1; }

    printf "%s\n" "$ROUTER_LAN_IP" > "$ROUTER_IP_STORE"
    printf "%s\n" "$ROUTER_LAN_IP" > "$XRAY_MAIN_ROUTER_IP_STORE"

    if [ "$REUSE" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
        PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"
    elif [ -s "$PRIMARY_STORE" ]; then
        PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"
    elif [ -s /opt/etc/xray-keenetic/main.url ]; then
        PRIMARY_VLESS="$(cat /opt/etc/xray-keenetic/main.url)"
    else
        read_tty "Primary VLESS link: " PRIMARY_VLESS
    fi

    [ -z "$PRIMARY_VLESS" ] && { echo "ERROR: Primary VLESS is empty."; exit 1; }
    printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
    chmod 600 "$PRIMARY_STORE"

    if [ "$REUSE" = "1" ] && [ -s "$BACKUP_STORE" ]; then
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"
    elif [ -s "$BACKUP_STORE" ]; then
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"
    elif [ -s /opt/etc/xray-keenetic/reserve.url ]; then
        BACKUP_VLESS="$(cat /opt/etc/xray-keenetic/reserve.url)"
    else
        echo
        echo "Backup VLESS link опциональна. Для пропуска нажмите Enter."
        read_tty "Backup VLESS link: " BACKUP_VLESS
    fi

    if [ -n "$BACKUP_VLESS" ]; then
        printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
        chmod 600 "$BACKUP_STORE"
    else
        rm -f "$BACKUP_STORE"
    fi

    [ -s "$ACTIVE_STORE" ] || echo "primary" > "$ACTIVE_STORE"

    if [ "$INSTALL_XRAY_MAIN" = "ask" ]; then
        if [ -s "$XRAY_MAIN_URL_STORE" ]; then
            INSTALL_XRAY_MAIN="yes"
        else
            echo
            echo "Установить отдельный Xray_main / Proxy1?"
            echo "1) Да"
            echo "2) Нет"
            read_tty "Выберите: " ans
            [ "$ans" = "1" ] && INSTALL_XRAY_MAIN="yes" || INSTALL_XRAY_MAIN="no"
        fi
    fi

    if [ "$INSTALL_XRAY_MAIN" = "yes" ]; then
        if [ -s "$XRAY_MAIN_URL_STORE" ]; then
            MAIN_VLESS="$(cat "$XRAY_MAIN_URL_STORE")"
        else
            read_tty "VLESS link для Xray_main / Proxy1: " MAIN_VLESS
        fi

        if [ -n "$MAIN_VLESS" ]; then
            printf "%s\n" "$MAIN_VLESS" > "$XRAY_MAIN_URL_STORE"
            chmod 600 "$XRAY_MAIN_URL_STORE"
        else
            INSTALL_XRAY_MAIN="no"
        fi
    fi

    if [ "$INSTALL_WEBUI" = "ask" ]; then
        echo
        echo "Установить опциональный WebUI в стиле KeeneticOS на порт 8090?"
        echo "Введите 1 для установки или нажмите Enter чтобы пропустить."
        read_tty "WebUI [1/Enter]: " WEBUI_ANSWER
        if [ "$WEBUI_ANSWER" = "1" ]; then
            INSTALL_WEBUI="yes"
        else
            INSTALL_WEBUI="no"
        fi
    fi
}

create_generator() {
    backup_file "$GENERATOR"
    cat > "$GENERATOR" <<'GEN'
#!/bin/sh
set -e
python3 <<'PY'
import os
import json
import urllib.parse

profile_name = os.environ.get("PROFILE_NAME", "vless-out")
url = os.environ["VLESS_URL"].strip()
listen_host = os.environ["LISTEN_HOST"]
listen_port = int(os.environ["LISTEN_PORT"])
output_config = os.environ["OUTPUT_CONFIG"]

u = urllib.parse.urlparse(url)
if u.scheme != "vless":
    raise SystemExit("ERROR: only vless:// links are supported")

uuid = urllib.parse.unquote(u.username or "")
server = u.hostname
port = u.port or 443

if not uuid:
    raise SystemExit("ERROR: UUID is missing in VLESS link")
if not server:
    raise SystemExit("ERROR: server host is missing in VLESS link")

params = dict(urllib.parse.parse_qsl(u.query, keep_blank_values=True))
network = params.get("type", "tcp")
security = params.get("security", "none")
encryption = params.get("encryption", "none")

user = {"id": uuid, "encryption": encryption}
if params.get("flow"):
    user["flow"] = params["flow"]

stream = {"network": network, "security": security}

if security == "tls":
    tls = {
        "serverName": params.get("sni", server),
        "allowInsecure": params.get("allowInsecure", "0").lower() in ("1", "true", "yes"),
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
        "spiderX": urllib.parse.unquote(params.get("spx", "/")),
    }
    if not reality["publicKey"]:
        raise SystemExit("ERROR: REALITY public key pbk is missing")
    stream["realitySettings"] = reality

if network == "ws":
    stream["wsSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "headers": {},
    }
    if params.get("host"):
        stream["wsSettings"]["headers"]["Host"] = params["host"]

elif network == "grpc":
    stream["grpcSettings"] = {
        "serviceName": params.get("serviceName", ""),
        "multiMode": params.get("mode", "") == "multi",
    }

elif network == "tcp":
    header_type = params.get("headerType", "none")
    if header_type != "none":
        stream["tcpSettings"] = {"header": {"type": header_type}}

elif network == "httpupgrade":
    stream["httpupgradeSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "host": params.get("host", server),
    }

elif network == "splithttp":
    stream["splithttpSettings"] = {
        "path": urllib.parse.unquote(params.get("path", "/")),
        "host": params.get("host", server),
    }

config = {
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": listen_host,
            "port": listen_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]},
        }
    ],
    "outbounds": [
        {
            "tag": profile_name,
            "protocol": "vless",
            "settings": {
                "vnext": [
                    {"address": server, "port": port, "users": [user]}
                ]
            },
            "streamSettings": stream,
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"},
    ],
}

with open(output_config, "w") as f:
    json.dump(config, f, indent=2)

print("Generated:", output_config)
print("Profile:", profile_name)
print("Server:", server)
print("Port:", port)
print("Network:", network)
print("Security:", security)
print("SOCKS5:", f"{listen_host}:{listen_port}")
PY
GEN
    chmod +x "$GENERATOR"
}

generate_config() {
    profile="$1"
    url="$2"
    host="$3"
    port="$4"
    out="$5"
    PROFILE_NAME="$profile" VLESS_URL="$url" LISTEN_HOST="$host" LISTEN_PORT="$port" OUTPUT_CONFIG="$out" "$GENERATOR"
}

create_init_scripts() {
    cat > "$INIT_XRAY" <<'EOF'
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

DESC="Xray Failover Core"
XRAY_CONFIG="/opt/etc/xray/config.json"
PIDFILE="/opt/var/run/xray-failover-core.pid"
LOGFILE="/opt/var/log/xray-failover-core.log"

mkdir -p /opt/var/run /opt/var/log

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo "/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

is_running() {
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi

    ps | grep '[x]ray run -config /opt/etc/xray/config.json' >/dev/null 2>&1
}

start() {
    printf " Starting %s... " "$DESC"

    if is_running; then
        echo "already running."
        exit 0
    fi

    XRAY_BIN="$(get_xray_bin)"

    if [ -z "$XRAY_BIN" ]; then
        echo "error."
        echo "xray binary not found"
        exit 1
    fi

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "error."
        echo "$XRAY_CONFIG not found"
        exit 1
    fi

    "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"

    sleep 3

    if is_running; then
        echo "done. PID: $(cat "$PIDFILE")"
        exit 0
    fi

    echo "error."
    echo "Last log:"
    tail -n 80 "$LOGFILE" 2>/dev/null || true
    rm -f "$PIDFILE"
    exit 1
}

stop() {
    printf " Stopping %s... " "$DESC"

    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null || true
            sleep 1
            kill -9 "$PID" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi

    PIDS="$(ps | grep '[x]ray run -config /opt/etc/xray/config.json' | awk '{print $1}')"
    for PID in $PIDS; do
        kill "$PID" 2>/dev/null || true
        sleep 1
        kill -9 "$PID" 2>/dev/null || true
    done

    echo "done."
}

status() {
    printf " Checking %s... " "$DESC"

    if is_running; then
        echo "alive."
        ps | grep '[x]ray run -config /opt/etc/xray/config.json' | grep -v grep || true
        exit 0
    fi

    echo "dead."
    exit 1
}

restart() {
    stop
    sleep 2
    start
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    chmod +x "$INIT_XRAY"

    cat > "$INIT_XRAY_MAIN" <<'EOF'
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

DESC="Xray_main"
XRAY_CONFIG="/opt/etc/xray-main/config.json"
PIDFILE="/opt/var/run/xray-main.pid"
LOGFILE="/opt/var/log/xray-main.log"

mkdir -p /opt/var/run /opt/var/log

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo "/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

is_running() {
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            return 0
        fi
    fi

    ps | grep '[x]ray run -config /opt/etc/xray-main/config.json' >/dev/null 2>&1
}

start() {
    printf " Starting %s... " "$DESC"

    if is_running; then
        echo "already running."
        exit 0
    fi

    XRAY_BIN="$(get_xray_bin)"

    if [ -z "$XRAY_BIN" ]; then
        echo "error."
        echo "xray binary not found"
        exit 1
    fi

    if [ ! -f "$XRAY_CONFIG" ]; then
        echo "error."
        echo "$XRAY_CONFIG not found"
        exit 1
    fi

    "$XRAY_BIN" run -config "$XRAY_CONFIG" >> "$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"

    sleep 3

    if is_running; then
        echo "done. PID: $(cat "$PIDFILE")"
        exit 0
    fi

    echo "error."
    echo "Last log:"
    tail -n 80 "$LOGFILE" 2>/dev/null || true
    rm -f "$PIDFILE"
    exit 1
}

stop() {
    printf " Stopping %s... " "$DESC"

    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ]; then
            kill "$PID" 2>/dev/null || true
            sleep 1
            kill -9 "$PID" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi

    PIDS="$(ps | grep '[x]ray run -config /opt/etc/xray-main/config.json' | awk '{print $1}')"
    for PID in $PIDS; do
        kill "$PID" 2>/dev/null || true
        sleep 1
        kill -9 "$PID" 2>/dev/null || true
    done

    echo "done."
}

status() {
    printf " Checking %s... " "$DESC"

    if is_running; then
        echo "alive."
        ps | grep '[x]ray run -config /opt/etc/xray-main/config.json' | grep -v grep || true
        exit 0
    fi

    echo "dead."
    exit 1
}

restart() {
    stop
    sleep 2
    start
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) restart ;;
    status) status ;;
    *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
EOF
    chmod +x "$INIT_XRAY_MAIN"

    cat > "$INIT_FAILOVER" <<'EOF'
#!/bin/sh
DESC="Xray VLESS Failover"
DAEMON="/opt/bin/xray-vless-failover-daemon"
PIDFILE="/opt/var/run/xray-vless-failover.pid"
LOGFILE="/opt/var/log/xray-vless-failover.log"
mkdir -p /opt/var/run /opt/var/log
is_running() { [ -f "$PIDFILE" ] || return 1; PID="$(cat "$PIDFILE" 2>/dev/null)"; [ -n "$PID" ] || return 1; kill -0 "$PID" 2>/dev/null; }
start() { printf " Запускаем %s... " "$DESC"; if is_running; then echo "уже запущен."; exit 0; fi; "$DAEMON" >> "$LOGFILE" 2>&1 & echo "$!" > "$PIDFILE"; sleep 2; if is_running; then echo "готово."; else echo "ошибка."; tail -n 30 "$LOGFILE" 2>/dev/null || true; rm -f "$PIDFILE"; exit 1; fi; }
stop() { printf " Останавливаем %s... " "$DESC"; if ! is_running; then echo "не запущен."; rm -f "$PIDFILE"; exit 0; fi; PID="$(cat "$PIDFILE")"; kill "$PID" 2>/dev/null || true; sleep 2; kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true; rm -f "$PIDFILE"; echo "готово."; }
status() { printf " Проверяем %s... " "$DESC"; if is_running; then echo "работает. PID: $(cat "$PIDFILE")"; else echo "не запущен."; exit 1; fi; }
restart() { "$0" stop; sleep 1; "$0" start; }
case "${1:-}" in start) start ;; stop) stop ;; restart) restart ;; status) status ;; *) echo "Использование: $0 {start|stop|restart|status}"; exit 1 ;; esac
EOF
    chmod +x "$INIT_FAILOVER"

    create_simple_daemon_init "$INIT_XRAY_WATCHDOG" "Xray Watchdog" "/opt/bin/xray-watchdog" "/opt/var/run/xray-watchdog.pid" "/opt/var/log/xray-watchdog.log"
    create_simple_daemon_init "$INIT_PROXY0_WATCHDOG" "Xray Proxy0 Watchdog" "/opt/bin/xray-proxy0-watchdog" "/opt/var/run/xray-proxy0-watchdog.pid" "/opt/var/log/xray-proxy0-watchdog.log"
}

create_simple_daemon_init() {
    init_file="$1"
    desc="$2"
    daemon="$3"
    pidfile="$4"
    logfile="$5"

    cat > "$init_file" <<EOF
#!/bin/sh
DESC="$desc"
DAEMON="$daemon"
PIDFILE="$pidfile"
LOGFILE="$logfile"
mkdir -p /opt/var/run /opt/var/log
is_running() { [ -f "\$PIDFILE" ] || return 1; PID="\$(cat "\$PIDFILE" 2>/dev/null)"; [ -n "\$PID" ] || return 1; kill -0 "\$PID" 2>/dev/null; }
start() { printf " Запускаем %s... " "\$DESC"; if is_running; then echo "уже запущен."; exit 0; fi; if [ ! -x "\$DAEMON" ]; then echo "ошибка."; echo "Daemon не найден: \$DAEMON"; exit 1; fi; "\$DAEMON" >> "\$LOGFILE" 2>&1 & echo "\$!" > "\$PIDFILE"; sleep 2; if is_running; then echo "готово."; else echo "ошибка."; tail -n 30 "\$LOGFILE" 2>/dev/null || true; rm -f "\$PIDFILE"; exit 1; fi; }
stop() { printf " Останавливаем %s... " "\$DESC"; if ! is_running; then echo "не запущен."; rm -f "\$PIDFILE"; exit 0; fi; PID="\$(cat "\$PIDFILE")"; kill "\$PID" 2>/dev/null || true; sleep 2; kill -0 "\$PID" 2>/dev/null && kill -9 "\$PID" 2>/dev/null || true; rm -f "\$PIDFILE"; echo "готово."; }
status() { printf " Проверяем %s... " "\$DESC"; if is_running; then echo "работает. PID: \$(cat "\$PIDFILE")"; else echo "не запущен."; exit 1; fi; }
restart() { "\$0" stop; sleep 1; "\$0" start; }
case "\${1:-}" in start) start ;; stop) stop ;; restart) restart ;; status) status ;; *) echo "Использование: \$0 {start|stop|restart|status}"; exit 1 ;; esac
EOF
    chmod +x "$init_file"
}

create_proxy_repair_commands() {
    cat > /opt/bin/xray_proxy0_repair <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
ROUTER_LAN_IP="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 192.168.1.1)"
PROXY_IFACE="Proxy0"; SOCKS_PORT="10808"; GLOBAL_PRIORITY="16375"; PROXY_DESC="Xray-Failover"
echo "Repair $PROXY_IFACE: $ROUTER_LAN_IP:$SOCKS_PORT"
if ! command -v ndmc >/dev/null 2>&1; then
    echo "ndmc not found. Configure manually: interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT"
    exit 0
fi
ndmc -c "interface $PROXY_IFACE down" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE" || true
ndmc -c "interface $PROXY_IFACE description $PROXY_DESC" || true
ndmc -c "interface $PROXY_IFACE proxy protocol socks5" || true
ndmc -c "interface $PROXY_IFACE proxy socks5-udp" || true
ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" || true
ndmc -c "interface $PROXY_IFACE ip global $GLOBAL_PRIORITY" || true
ndmc -c "interface $PROXY_IFACE no ipv6 address auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 address" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 prefix auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 prefix" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 name-servers auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 name-servers" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 force-default" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6cp" >/dev/null 2>&1 || true
sleep 5
ndmc -c "interface $PROXY_IFACE up" || true
ndmc -c "system configuration save" || true
echo "$PROXY_IFACE repaired."
EOF
    chmod +x /opt/bin/xray_proxy0_repair

    cat > /opt/bin/xray_main_proxy1_repair <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
ROUTER_LAN_IP="$(cat /opt/etc/xray-main/router-lan-ip 2>/dev/null || cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 192.168.1.1)"
PROXY_IFACE="Proxy1"; SOCKS_PORT="10809"; GLOBAL_PRIORITY="16374"; PROXY_DESC="Xray_main"
echo "Repair $PROXY_IFACE: $ROUTER_LAN_IP:$SOCKS_PORT"
if ! command -v ndmc >/dev/null 2>&1; then
    echo "ndmc not found. Configure manually: interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT"
    exit 0
fi
ndmc -c "interface $PROXY_IFACE down" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE" || true
ndmc -c "interface $PROXY_IFACE description $PROXY_DESC" || true
ndmc -c "interface $PROXY_IFACE proxy protocol socks5" || true
ndmc -c "interface $PROXY_IFACE proxy socks5-udp" || true
ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" || true
ndmc -c "interface $PROXY_IFACE ip global $GLOBAL_PRIORITY" || true
ndmc -c "interface $PROXY_IFACE no ipv6 address auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 address" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 prefix auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 prefix" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 name-servers auto" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 name-servers" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6 force-default" >/dev/null 2>&1 || true
ndmc -c "interface $PROXY_IFACE no ipv6cp" >/dev/null 2>&1 || true
sleep 5
ndmc -c "interface $PROXY_IFACE up" || true
ndmc -c "system configuration save" || true
echo "$PROXY_IFACE repaired."
EOF
    chmod +x /opt/bin/xray_main_proxy1_repair
}

create_failover_daemon() {
    cat > "$FAILOVER_DAEMON" <<'DAEMON'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GENERATOR="/opt/bin/xray-vless-generate-config"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
SOCKS_PORT="10808"
CHECK_INTERVAL="10"
CHECK_URL="https://www.gstatic.com/generate_204"
TMP_DIR="/opt/tmp"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"
FAILS_TO_BACKUP="2"
OK_TO_RETURN="2"
LOG_MAX_KB="512"
FAILOVER_LOG="/opt/var/log/xray-vless-failover.log"
EVENT_LOG="/opt/var/log/xray-vless-events.log"
mkdir -p "$TMP_DIR" /opt/var/log
get_xray_bin() { if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; fi; }
XRAY_BIN="$(get_xray_bin)"
ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
event() { echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) $*" >> "$EVENT_LOG"; }
rotate_log() { FILE="$1"; [ -f "$FILE" ] || return 0; SIZE_KB="$(du -k "$FILE" 2>/dev/null | awk '{print $1}')"; [ -n "$SIZE_KB" ] || return 0; if [ "$SIZE_KB" -gt "$LOG_MAX_KB" ]; then mv "$FILE" "$FILE.1" 2>/dev/null || true; : > "$FILE"; event "log rotated: $FILE"; fi; }
test_socks_endpoint() { HOST="$1"; PORT="$2"; RESULT="$(curl -k -sS --socks5-hostname "$HOST:$PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}' "$CHECK_URL" 2>&1)" && STATUS=0 || STATUS="$?"; echo "$RESULT"; [ "$STATUS" = "0" ]; }
wait_for_socks_port() { i=1; while [ "$i" -le 10 ]; do netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT" && return 0; sleep 1; i=$((i+1)); done; return 1; }
generate_profile_config() { PROFILE_NAME="$1" VLESS_URL="$2" LISTEN_HOST="$3" LISTEN_PORT="$4" OUTPUT_CONFIG="$5" "$GENERATOR"; }
test_vless_temp() {
    PROFILE="$1"; URL="$2"; PORT="$3"
    TMP_CONFIG="$TMP_DIR/xray-failover-test-$PROFILE.json"; TMP_LOG="$TMP_DIR/xray-failover-test-$PROFILE.log"
    echo "Проверяем неактивный профиль через временный SOCKS5: $PROFILE"
    generate_profile_config "$PROFILE" "$URL" "$TEMP_HOST" "$PORT" "$TMP_CONFIG" >/dev/null
    "$XRAY_BIN" run -test -config "$TMP_CONFIG" >/dev/null
    "$XRAY_BIN" run -config "$TMP_CONFIG" > "$TMP_LOG" 2>&1 &
    TMP_PID="$!"
    sleep 3
    if ! kill -0 "$TMP_PID" 2>/dev/null; then echo "Временный Xray не запустился."; cat "$TMP_LOG"; return 1; fi
    if test_socks_endpoint "$TEMP_HOST" "$PORT"; then kill "$TMP_PID" 2>/dev/null || true; wait "$TMP_PID" 2>/dev/null || true; return 0; fi
    kill "$TMP_PID" 2>/dev/null || true; wait "$TMP_PID" 2>/dev/null || true; return 1
}
switch_to_profile() {
    TARGET="$1"
    if [ "$TARGET" = primary ]; then URL="$(cat "$PRIMARY_STORE")"; else URL="$(cat "$BACKUP_STORE")"; fi
    echo; echo "======================================"; echo " ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET"; echo "======================================"
    event "switch requested -> $TARGET"
    generate_profile_config "$TARGET" "$URL" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$XRAY_CONFIG"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true; sleep 2; "$INIT_SCRIPT" start
    wait_for_socks_port || { event "switch failed -> $TARGET: socks port not up"; return 1; }
    sleep 5
    test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT" || { event "switch failed -> $TARGET: endpoint check failed"; return 1; }
    [ -x /opt/bin/xray_proxy0_repair ] && /opt/bin/xray_proxy0_repair || true
    echo "$TARGET" > "$ACTIVE_STORE"; sleep 5; event "switched -> $TARGET"; echo "Активный профиль теперь: $TARGET"
}
PRIMARY_FAIL_COUNT=0; PRIMARY_OK_COUNT=0
event "failover daemon started: interval=${CHECK_INTERVAL}s debounce fail=${FAILS_TO_BACKUP} ok=${OK_TO_RETURN}"
while true; do
    rotate_log "$FAILOVER_LOG"; rotate_log "$EVENT_LOG"
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    echo; echo "[$NOW] Активный профиль: $ACTIVE"
    if [ "$ACTIVE" = primary ]; then
        PRIMARY_OK_COUNT=0
        echo "Проверяем active primary через $ROUTER_LAN_IP:$SOCKS_PORT..."
        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then echo "Primary OK."; PRIMARY_FAIL_COUNT=0
        else
            PRIMARY_FAIL_COUNT=$((PRIMARY_FAIL_COUNT+1)); echo "Primary НЕ ДОСТУПЕН. Fail count: $PRIMARY_FAIL_COUNT/$FAILS_TO_BACKUP"; event "primary check failed count=$PRIMARY_FAIL_COUNT/$FAILS_TO_BACKUP"
            if [ "$PRIMARY_FAIL_COUNT" -ge "$FAILS_TO_BACKUP" ]; then
                if [ -s "$BACKUP_STORE" ]; then
                    echo "Проверяем backup перед переключением..."
                    if test_vless_temp backup "$(cat "$BACKUP_STORE")" "$TEMP_BACKUP_PORT"; then event "primary down, backup ok"; switch_to_profile backup || echo "Переключение на backup не удалось."; PRIMARY_FAIL_COUNT=0
                    else echo "Backup тоже недоступен."; event "primary down, backup also down"; fi
                else echo "Backup-ссылка не настроена."; event "primary down, backup not configured"; fi
            fi
        fi
    elif [ "$ACTIVE" = backup ]; then
        PRIMARY_FAIL_COUNT=0
        echo "Проверяем active backup через $ROUTER_LAN_IP:$SOCKS_PORT..."
        test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT" && echo "Backup OK." || { echo "Backup НЕ ДОСТУПЕН."; event "backup active endpoint failed"; }
        echo "Проверяем, вернулся ли primary..."
        if test_vless_temp primary "$(cat "$PRIMARY_STORE")" "$TEMP_PRIMARY_PORT"; then
            PRIMARY_OK_COUNT=$((PRIMARY_OK_COUNT+1)); echo "Primary доступен. OK count: $PRIMARY_OK_COUNT/$OK_TO_RETURN"; event "primary restored count=$PRIMARY_OK_COUNT/$OK_TO_RETURN"
            if [ "$PRIMARY_OK_COUNT" -ge "$OK_TO_RETURN" ]; then switch_to_profile primary || echo "Переключение на primary не удалось."; PRIMARY_OK_COUNT=0; fi
        else PRIMARY_OK_COUNT=0; echo "Primary всё ещё недоступен. Остаёмся на backup."; fi
    else
        echo "Неизвестный active-profile. Пробуем вернуться на primary."; event "unknown active profile: $ACTIVE"; switch_to_profile primary || true
    fi
    sleep "$CHECK_INTERVAL"
done
DAEMON
    chmod +x "$FAILOVER_DAEMON"
}

create_watchdogs() {
    cat > /opt/bin/xray-watchdog <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
ROUTER_IP_STORE="/opt/etc/xray/router-lan-ip"; ACTIVE_STORE="/opt/etc/xray/active-profile"
XRAY_INIT="/opt/etc/init.d/S24xray"; FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
SOCKS_PORT=10808; CHECK_INTERVAL=30; LOG_FILE="/opt/var/log/xray-watchdog.log"
mkdir -p /opt/var/log
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) $*" >> "$LOG_FILE"; }
router_ip(){ cat "$ROUTER_IP_STORE" 2>/dev/null || echo 127.0.0.1; }
endpoint_ok(){ for u in https://www.gstatic.com/generate_204 https://cp.cloudflare.com/generate_204 https://www.google.com/generate_204 https://api.ipify.org; do curl -k -sS --socks5-hostname "$(router_ip):$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null "$u" >/dev/null 2>&1 && return 0; done; return 1; }
log "xray-watchdog started, interval=${CHECK_INTERVAL}s"; FAIL_COUNT=0
while true; do
    if ! "$XRAY_INIT" status >/dev/null 2>&1; then FAIL_COUNT=$((FAIL_COUNT+1)); log "xray process check failed count=$FAIL_COUNT"
    elif ! netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT"; then FAIL_COUNT=$((FAIL_COUNT+1)); log "socks port $SOCKS_PORT check failed count=$FAIL_COUNT"
    elif ! endpoint_ok; then FAIL_COUNT=$((FAIL_COUNT+1)); log "socks endpoint check failed count=$FAIL_COUNT"
    else [ "$FAIL_COUNT" -gt 0 ] && log "xray stack recovered, fail_count reset"; FAIL_COUNT=0; fi
    if [ "$FAIL_COUNT" -ge 2 ]; then log "failure threshold reached, restarting xray stack"; "$XRAY_INIT" restart >> "$LOG_FILE" 2>&1 || true; sleep 5; [ -x /opt/bin/xray_proxy0_repair ] && /opt/bin/xray_proxy0_repair >> "$LOG_FILE" 2>&1 || true; "$FAILOVER_INIT" status >/dev/null 2>&1 || "$FAILOVER_INIT" start >> "$LOG_FILE" 2>&1 || true; FAIL_COUNT=0; fi
    sleep "$CHECK_INTERVAL"
done
EOF
    chmod +x /opt/bin/xray-watchdog

    cat > /opt/bin/xray-proxy0-watchdog <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
ROUTER_IP_STORE="/opt/etc/xray/router-lan-ip"; PROXY_IFACE=Proxy0; SOCKS_PORT=10808; GLOBAL_PRIORITY=16375; CHECK_INTERVAL=60; LOG_FILE="/opt/var/log/xray-proxy0-watchdog.log"
mkdir -p /opt/var/log
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) $*" >> "$LOG_FILE"; }
router_ip(){ cat "$ROUTER_IP_STORE" 2>/dev/null || echo 192.168.1.1; }
cfg(){ ndmc -c "show running-config" 2>/dev/null | grep -A20 -i "interface $PROXY_IFACE" || true; }
ok(){ C="$(cfg)"; IP="$(router_ip)"; echo "$C"|grep -qi "interface $PROXY_IFACE" || return 1; echo "$C"|grep -qi "proxy protocol socks5" || return 1; echo "$C"|grep -qi "proxy upstream $IP $SOCKS_PORT" || return 1; echo "$C"|grep -qi "ip global $GLOBAL_PRIORITY" || return 1; echo "$C"|grep -qi "description Xray-Failover" || return 1; }
command -v ndmc >/dev/null 2>&1 || { log "ndmc not found, proxy0 watchdog disabled"; exit 0; }
log "xray-proxy0-watchdog started, interval=${CHECK_INTERVAL}s"; FAIL_COUNT=0
while true; do
    if ok; then [ "$FAIL_COUNT" -gt 0 ] && log "Proxy0 config OK, fail_count reset"; FAIL_COUNT=0
    else FAIL_COUNT=$((FAIL_COUNT+1)); log "Proxy0 config mismatch count=$FAIL_COUNT"; if [ "$FAIL_COUNT" -ge 2 ]; then log "repair requested"; [ -x /opt/bin/xray_proxy0_repair ] && /opt/bin/xray_proxy0_repair >> "$LOG_FILE" 2>&1 || true; FAIL_COUNT=0; fi; fi
    sleep "$CHECK_INTERVAL"
done
EOF
    chmod +x /opt/bin/xray-proxy0-watchdog
}

create_xray_main_commands() {
    cat > /opt/bin/xray_main_generate <<'EOF'
#!/bin/sh
set -e
ROUTER_LAN_IP="$(cat /opt/etc/xray-main/router-lan-ip 2>/dev/null || cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 192.168.1.1)"
PROFILE_NAME="Xray_main" VLESS_URL="$(cat /opt/etc/xray-main/vless-main.url)" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="10809" OUTPUT_CONFIG="/opt/etc/xray-main/config.json" /opt/bin/xray-vless-generate-config
EOF
    chmod +x /opt/bin/xray_main_generate

    cat > /opt/bin/xray_main_update <<'EOF'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
mkdir -p /opt/etc/xray-main
printf "Введите новую VLESS-ссылку для Xray_main: "
read MAIN_VLESS
[ -z "$MAIN_VLESS" ] && { echo "ERROR: empty VLESS"; exit 1; }
printf "%s\n" "$MAIN_VLESS" > /opt/etc/xray-main/vless-main.url
chmod 600 /opt/etc/xray-main/vless-main.url
/opt/bin/xray_main_generate
XRAY_BIN="$(command -v xray || echo /opt/sbin/xray)"
"$XRAY_BIN" run -test -config /opt/etc/xray-main/config.json
/opt/etc/init.d/S23xray-main restart
sleep 5
/opt/bin/xray_main_proxy1_repair || true
echo "Готово."
EOF
    chmod +x /opt/bin/xray_main_update
}

create_update_switch_status_commands() {
    cat > /opt/bin/vless-failover-update <<'EOF'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
XRAY_DIR="/opt/etc/xray"; XRAY_CONFIG="$XRAY_DIR/config.json"; PRIMARY_STORE="$XRAY_DIR/vless-primary.url"; BACKUP_STORE="$XRAY_DIR/vless-backup.url"; ACTIVE_STORE="$XRAY_DIR/active-profile"; ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"; SOCKS_PORT=10808
printf "New Primary VLESS link: "; read P; [ -z "$P" ] && { echo "ERROR: Primary empty"; exit 1; }
echo; printf "New Backup VLESS link, optional. Press Enter to skip: "; read B
printf "%s\n" "$P" > "$PRIMARY_STORE"; chmod 600 "$PRIMARY_STORE"
if [ -n "$B" ]; then printf "%s\n" "$B" > "$BACKUP_STORE"; chmod 600 "$BACKUP_STORE"; else rm -f "$BACKUP_STORE"; fi
ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
PROFILE_NAME=primary VLESS_URL="$P" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="$SOCKS_PORT" OUTPUT_CONFIG="$XRAY_CONFIG" /opt/bin/xray-vless-generate-config
XRAY_BIN="$(command -v xray || echo /opt/sbin/xray)"
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"
echo primary > "$ACTIVE_STORE"
/opt/etc/init.d/S24xray restart
sleep 5
/opt/bin/xray_proxy0_repair || true
/opt/etc/init.d/S25xray-failover restart
/opt/etc/init.d/S27xray-watchdog restart >/dev/null 2>&1 || true
/opt/etc/init.d/S28xray-proxy0-watchdog restart >/dev/null 2>&1 || true
echo "Готово. Активный профиль: primary"
EOF
    chmod +x /opt/bin/vless-failover-update
    ln -sf /opt/bin/vless-failover-update /opt/bin/xray_vless_update
    ln -sf /opt/bin/vless-failover-update /opt/bin/xray-failover-update

    cat > /opt/bin/xray_switch <<'EOF'
#!/bin/sh
set -e
TARGET="${1:-}"
[ "$TARGET" = primary ] || [ "$TARGET" = backup ] || { echo "Usage: xray_switch primary|backup"; exit 1; }
XRAY_DIR="/opt/etc/xray"; XRAY_CONFIG="$XRAY_DIR/config.json"; PRIMARY_STORE="$XRAY_DIR/vless-primary.url"; BACKUP_STORE="$XRAY_DIR/vless-backup.url"; ACTIVE_STORE="$XRAY_DIR/active-profile"; ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"; SOCKS_PORT=10808; CHECK_URL="https://www.gstatic.com/generate_204"
[ "$TARGET" = primary ] && URL_FILE="$PRIMARY_STORE" || URL_FILE="$BACKUP_STORE"
[ -s "$URL_FILE" ] || { echo "ERROR: $TARGET link not configured"; exit 1; }
ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"; URL="$(cat "$URL_FILE")"; XRAY_BIN="$(command -v xray || echo /opt/sbin/xray)"
PROFILE_NAME="$TARGET" VLESS_URL="$URL" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="$SOCKS_PORT" OUTPUT_CONFIG="$XRAY_CONFIG" /opt/bin/xray-vless-generate-config
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"
/opt/etc/init.d/S24xray restart
sleep 5
curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null "$CHECK_URL"
echo "$TARGET" > "$ACTIVE_STORE"
/opt/bin/xray_proxy0_repair >/dev/null 2>&1 || true
echo "$(date '+%Y-%m-%d %H:%M:%S') manual switch -> $TARGET" >> /opt/var/log/xray-vless-events.log
echo "Active profile: $TARGET"
EOF
    chmod +x /opt/bin/xray_switch
}

create_core_update_commands() {
    cat > /opt/bin/xray_core_version <<'EOF'
#!/bin/sh
if command -v xray >/dev/null 2>&1; then command -v xray; xray version; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; /opt/sbin/xray version; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; /opt/bin/xray version; else echo "xray not found"; exit 1; fi
EOF
    chmod +x /opt/bin/xray_core_version

    cat > /opt/bin/xray_core_update_github <<'EOF'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
MODE="${1:-latest}"; DO_BACKUP="${XRAY_CORE_BACKUP:-yes}"
LOG="/opt/var/log/xray-core-update.log"; TMP_DIR="/opt/tmp/xray-core-update"; BACKUP_DIR="/opt/backup/xray-core"; mkdir -p "$TMP_DIR" "$BACKUP_DIR" /opt/var/log
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) $*" | tee -a "$LOG" >&2; }
get_xray_bin(){ if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; fi; }
asset(){ case "$(uname -m)" in aarch64|arm64) echo Xray-linux-arm64-v8a.zip;; armv7l|armv7*) echo Xray-linux-arm32-v7a.zip;; armv6l|armv6*) echo Xray-linux-arm32-v6.zip;; x86_64|amd64) echo Xray-linux-64.zip;; i386|i686) echo Xray-linux-32.zip;; mipsel|mipsle) echo Xray-linux-mips32le.zip;; mips) echo Xray-linux-mips32.zip;; *) echo "";; esac; }
ensure(){ command -v curl >/dev/null 2>&1 || { opkg update; opkg install curl ca-bundle ca-certificates; }; command -v python3 >/dev/null 2>&1 || { opkg update; opkg install python3; }; command -v unzip >/dev/null 2>&1 || { opkg update; opkg install unzip; }; }
get_url(){ MODE="$1"; ASSET="$2"; if [ "$MODE" = latest ]; then API=https://api.github.com/repos/XTLS/Xray-core/releases/latest; JSON="$TMP_DIR/latest.json"; log "Fetching GitHub latest release..."; curl -fsSL "$API" -o "$JSON"; python3 - "$ASSET" "$JSON" <<'PY'
import sys,json
asset,path=sys.argv[1],sys.argv[2]
r=json.load(open(path))
for a in r.get("assets",[]):
    if a.get("name")==asset:
        print(r.get("tag_name","")); print(a.get("browser_download_url","")); raise SystemExit
raise SystemExit("asset not found")
PY
else API=https://api.github.com/repos/XTLS/Xray-core/releases; JSON="$TMP_DIR/releases.json"; log "Fetching GitHub pre-release list..."; curl -fsSL "$API" -o "$JSON"; python3 - "$ASSET" "$JSON" <<'PY'
import sys,json
asset,path=sys.argv[1],sys.argv[2]
for r in json.load(open(path)):
    if not r.get("prerelease"):
        continue
    for a in r.get("assets",[]):
        if a.get("name")==asset:
            print(r.get("tag_name","")); print(a.get("browser_download_url","")); raise SystemExit
raise SystemExit("pre-release asset not found")
PY
fi; }
install_zip(){ ZIP="$1"; rm -rf "$TMP_DIR/unpack"; mkdir -p "$TMP_DIR/unpack"; unzip -o "$ZIP" -d "$TMP_DIR/unpack" >/dev/null; [ -f "$TMP_DIR/unpack/xray" ] || { log "ERROR: xray binary not found in archive"; exit 1; }; chmod +x "$TMP_DIR/unpack/xray"; TARGET="$(get_xray_bin)"; [ -z "$TARGET" ] && TARGET=/opt/sbin/xray; case "$TARGET" in /opt/sbin/xray|/opt/bin/xray) ;; *) TARGET=/opt/sbin/xray;; esac; TS="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo backup)"; if [ -x "$TARGET" ]; then if [ "$DO_BACKUP" = yes ]; then cp "$TARGET" "$BACKUP_DIR/xray.$TS.bak"; log "Backup saved: $BACKUP_DIR/xray.$TS.bak"; else log "Backup skipped by user"; fi; fi; cp "$TMP_DIR/unpack/xray" "$TARGET"; chmod +x "$TARGET"; log "Installed Xray binary to $TARGET"; }
[ "$MODE" = latest ] || [ "$MODE" = test ] || { echo "Usage: xray_core_update_github latest|test"; exit 1; }
log "=== GitHub Xray update started: mode=$MODE backup=$DO_BACKUP ==="; ensure; ASSET="$(asset)"; [ -z "$ASSET" ] && { log "ERROR: unsupported arch: $(uname -m)"; exit 1; }
OLD="$(get_xray_bin)"; [ -n "$OLD" ] && { log "Current version:"; "$OLD" version 2>&1 | tee -a "$LOG"; }
INFO="$(get_url "$MODE" "$ASSET")"; TAG="$(echo "$INFO"|sed -n '1p')"; URL="$(echo "$INFO"|sed -n '2p')"; case "$URL" in http://*|https://*) ;; *) log "ERROR: invalid URL: $URL"; echo "$INFO" | tee -a "$LOG" >&2; exit 1;; esac
log "Selected tag: $TAG"; log "Downloading: $URL"; ZIP="$TMP_DIR/$ASSET"; curl -fL "$URL" -o "$ZIP"
/opt/etc/init.d/S27xray-watchdog stop >/dev/null 2>&1 || true; /opt/etc/init.d/S28xray-proxy0-watchdog stop >/dev/null 2>&1 || true; /opt/etc/init.d/S25xray-failover stop >/dev/null 2>&1 || true; /opt/etc/init.d/S24xray stop >/dev/null 2>&1 || true
install_zip "$ZIP"; NEW="$(get_xray_bin)"; log "New version:"; "$NEW" version 2>&1 | tee -a "$LOG"; [ -f /opt/etc/xray/config.json ] && "$NEW" run -test -config /opt/etc/xray/config.json 2>&1 | tee -a "$LOG"
/opt/etc/init.d/S24xray restart 2>&1 | tee -a "$LOG" || true; sleep 5; [ -x /opt/bin/xray_proxy0_repair ] && /opt/bin/xray_proxy0_repair 2>&1 | tee -a "$LOG" || true; /opt/etc/init.d/S25xray-failover restart 2>&1 | tee -a "$LOG" || true; /opt/etc/init.d/S27xray-watchdog restart 2>&1 | tee -a "$LOG" || true; /opt/etc/init.d/S28xray-proxy0-watchdog restart 2>&1 | tee -a "$LOG" || true
log "=== GitHub Xray update completed: mode=$MODE tag=$TAG ==="
EOF
    chmod +x /opt/bin/xray_core_update_github

    cat > /opt/bin/xray_core_update_latest <<'EOF'
#!/bin/sh
echo "Сделать backup текущего Xray перед обновлением latest?"
echo "1) Да"; echo "2) Нет"; printf "Выберите: "; read c
[ "$c" = "2" ] && XRAY_CORE_BACKUP=no exec /opt/bin/xray_core_update_github latest
XRAY_CORE_BACKUP=yes exec /opt/bin/xray_core_update_github latest
EOF
    chmod +x /opt/bin/xray_core_update_latest

    cat > /opt/bin/xray_core_update_test <<'EOF'
#!/bin/sh
echo "Сделать backup текущего Xray перед обновлением test/pre-release?"
echo "1) Да"; echo "2) Нет"; printf "Выберите: "; read c
[ "$c" = "2" ] && XRAY_CORE_BACKUP=no exec /opt/bin/xray_core_update_github test
XRAY_CORE_BACKUP=yes exec /opt/bin/xray_core_update_github test
EOF
    chmod +x /opt/bin/xray_core_update_test

    cat > /opt/bin/xray_core_update_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-core-update.log; tail -f /opt/var/log/xray-core-update.log
EOF
    chmod +x /opt/bin/xray_core_update_log
}

create_status_log_maintenance_commands() {
    cat > /opt/bin/xray_failover_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-vless-failover.log; tail -f /opt/var/log/xray-vless-failover.log
EOF
    chmod +x /opt/bin/xray_failover_log

    cat > /opt/bin/xray_failover_events <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-vless-events.log
[ "${1:-}" = "-f" ] && tail -f /opt/var/log/xray-vless-events.log || tail -n 80 /opt/var/log/xray-vless-events.log
EOF
    chmod +x /opt/bin/xray_failover_events

    cat > /opt/bin/xray_watchdog_status <<'EOF'
#!/bin/sh
echo "Xray watchdog:"; /opt/etc/init.d/S27xray-watchdog status 2>&1 || true
echo; echo "Xray service:"; /opt/etc/init.d/S24xray status 2>&1 || true
echo; echo "SOCKS port:"; netstat -lntp 2>/dev/null | grep 10808 || true
echo; echo "Recent watchdog log:"; tail -n 40 /opt/var/log/xray-watchdog.log 2>/dev/null || true
EOF
    chmod +x /opt/bin/xray_watchdog_status

    cat > /opt/bin/xray_watchdog_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-watchdog.log; tail -f /opt/var/log/xray-watchdog.log
EOF
    chmod +x /opt/bin/xray_watchdog_log

    cat > /opt/bin/xray_proxy0_watchdog_status <<'EOF'
#!/bin/sh
echo "Proxy0 watchdog:"; /opt/etc/init.d/S28xray-proxy0-watchdog status 2>&1 || true
echo; echo "Proxy0 running-config:"; ndmc -c "show running-config" 2>/dev/null | grep -A20 -i "interface Proxy0" || true
echo; echo "Recent Proxy0 watchdog log:"; tail -n 40 /opt/var/log/xray-proxy0-watchdog.log 2>/dev/null || true
EOF
    chmod +x /opt/bin/xray_proxy0_watchdog_status

    cat > /opt/bin/xray_proxy0_watchdog_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-proxy0-watchdog.log; tail -f /opt/var/log/xray-proxy0-watchdog.log
EOF
    chmod +x /opt/bin/xray_proxy0_watchdog_log

    cat > /opt/bin/xray_main_status <<'EOF'
#!/bin/sh
echo "======================================"; echo " Xray_main / Proxy1 status"; echo "======================================"
echo; echo "VLESS:"; [ -s /opt/etc/xray-main/vless-main.url ] && echo "configured" || echo "not configured"
echo; echo "Xray_main service:"; /opt/etc/init.d/S23xray-main status 2>&1 || true
echo; echo "SOCKS5 port:"; netstat -lntp 2>/dev/null | grep 10809 || true
echo; echo "SOCKS5 check:"; IP="$(cat /opt/etc/xray-main/router-lan-ip 2>/dev/null || echo 127.0.0.1)"; curl -k -sS --socks5-hostname "$IP:10809" --connect-timeout 5 --max-time 10 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n' https://www.gstatic.com/generate_204 2>&1 || true
echo; echo "Proxy1 running-config:"; ndmc -c "show running-config" 2>/dev/null | grep -A15 -i "interface Proxy1" || true
EOF
    chmod +x /opt/bin/xray_main_status

    cat > /opt/bin/xray_main_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log; touch /opt/var/log/xray-main.log; tail -f /opt/var/log/xray-main.log
EOF
    chmod +x /opt/bin/xray_main_log

    cat > /opt/bin/vless-failover-status <<'EOF'
#!/bin/sh
echo "Активный профиль:"; cat /opt/etc/xray/active-profile 2>/dev/null || echo unknown
echo; echo "Статус Xray:"; /opt/etc/init.d/S24xray status 2>&1 || true
echo; echo "Статус failover:"; /opt/etc/init.d/S25xray-failover status 2>&1 || true
echo; echo "Статус Xray Watchdog:"; /opt/etc/init.d/S27xray-watchdog status 2>&1 || true
echo; echo "Статус Proxy0 Watchdog:"; /opt/etc/init.d/S28xray-proxy0-watchdog status 2>&1 || true
echo; echo "SOCKS5 port:"; netstat -lntp 2>/dev/null | grep 10808 || true
echo; echo "Проверка SOCKS5:"; IP="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 127.0.0.1)"; curl -k -sS --socks5-hostname "$IP:10808" --connect-timeout 5 --max-time 10 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n' https://www.gstatic.com/generate_204 2>&1 || true
echo; echo "Proxy0:"; ndmc -c "show running-config" 2>/dev/null | grep -A15 -i "interface Proxy0" || true
echo; echo "Последние события:"; tail -n 20 /opt/var/log/xray-vless-events.log 2>/dev/null || true
EOF
    chmod +x /opt/bin/vless-failover-status
}

create_maintenance_tools() {
    cat > /opt/bin/xray_failover_backup <<'EOF'
#!/bin/sh
set -e
BACKUP_DIR="/opt/backup/xray-failover"; TS="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo backup)"; OUT="$BACKUP_DIR/xray-failover-backup-$TS.tar.gz"; mkdir -p "$BACKUP_DIR" /opt/tmp
tar -czf "$OUT" /opt/etc/xray /opt/etc/xray-main /opt/etc/init.d/S23xray-main /opt/etc/init.d/S24xray /opt/etc/init.d/S25xray-failover /opt/etc/init.d/S27xray-watchdog /opt/etc/init.d/S28xray-proxy0-watchdog /opt/bin/failover /opt/bin/xray* /opt/bin/vless* 2>/dev/null || true
chmod 600 "$OUT"; echo "Backup created: $OUT"; ls -lh "$OUT"
EOF
    chmod +x /opt/bin/xray_failover_backup

    cat > /opt/bin/xray_logs <<'EOF'
#!/bin/sh
ALL="/opt/var/log/xray-vless-failover.log /opt/var/log/xray-vless-events.log /opt/var/log/xray-watchdog.log /opt/var/log/xray-proxy0-watchdog.log /opt/var/log/xray-core-update.log /opt/var/log/xray-main.log"
if [ "${1:-}" = grep ]; then shift; grep -i "$*" $ALL 2>/dev/null || true; exit 0; fi
echo "Usage: xray_logs grep pattern"; echo "Logs:"; ls -lh $ALL 2>/dev/null || true
EOF
    chmod +x /opt/bin/xray_logs

    cat > /opt/bin/xray_all_status <<'EOF'
#!/bin/sh
vless-failover-status
echo; echo "Xray_main:"; xray_main_status 2>/dev/null || true
EOF
    chmod +x /opt/bin/xray_all_status

    cat > /opt/bin/xray_post_update_test <<'EOF'
#!/bin/sh
set +e
FAILS=0
ok(){ echo "OK    $*"; }; fail(){ echo "FAIL  $*"; FAILS=$((FAILS+1)); }; warn(){ echo "WARN  $*"; }
XRAY_BIN="$(command -v xray || echo /opt/sbin/xray)"
[ -x "$XRAY_BIN" ] && ok "xray: $XRAY_BIN" || fail "xray missing"
[ -f /opt/etc/xray/config.json ] && "$XRAY_BIN" run -test -config /opt/etc/xray/config.json >/dev/null 2>&1 && ok "failover config" || fail "failover config"
/opt/etc/init.d/S24xray status >/dev/null 2>&1 && ok "S24xray" || fail "S24xray"
/opt/etc/init.d/S25xray-failover status >/dev/null 2>&1 && ok "S25failover" || fail "S25failover"
netstat -lnt 2>/dev/null | grep -q ":10808" && ok "port 10808" || fail "port 10808"
IP="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 127.0.0.1)"
curl -k -sS --socks5-hostname "$IP:10808" --connect-timeout 5 --max-time 10 -o /dev/null https://www.gstatic.com/generate_204 >/dev/null 2>&1 && ok "SOCKS 10808" || fail "SOCKS 10808"
if [ -f /opt/etc/xray-main/config.json ]; then
    "$XRAY_BIN" run -test -config /opt/etc/xray-main/config.json >/dev/null 2>&1 && ok "Xray_main config" || fail "Xray_main config"
    netstat -lnt 2>/dev/null | grep -q ":10809" && ok "port 10809" || fail "port 10809"
fi
[ "$FAILS" -eq 0 ] && { echo "RESULT: OK"; exit 0; } || { echo "RESULT: FAILS=$FAILS"; exit 1; }
EOF
    chmod +x /opt/bin/xray_post_update_test

    cat > /opt/bin/xray_failover_doctor <<'EOF'
#!/bin/sh
xray_all_status
EOF
    chmod +x /opt/bin/xray_failover_doctor

    cat > /opt/bin/xray_core_rollback <<'EOF'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
BACKUP_DIR="/opt/backup/xray-core"; LIST="/opt/tmp/xray-core-rollback-list.txt"; : > "$LIST"; i=1
get_xray_bin(){ if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; else echo /opt/sbin/xray; fi; }
TARGET="$(get_xray_bin)"
case "$TARGET" in /opt/sbin/xray|/opt/bin/xray) ;; *) TARGET=/opt/sbin/xray;; esac
for f in $(ls -1t "$BACKUP_DIR"/xray.*.bak 2>/dev/null); do echo "$i) $f"; echo "$f" >> "$LIST"; i=$((i+1)); done
[ -s "$LIST" ] || { echo "No backups."; exit 1; }
printf "Введите номер: "; read n; SELECTED="$(sed -n "${n}p" "$LIST")"; [ -f "$SELECTED" ] || { echo "Invalid selection"; exit 1; }
printf "Restore $SELECTED to $TARGET ? 1=yes: "; read c; [ "$c" = 1 ] || exit 0
/opt/etc/init.d/S27xray-watchdog stop >/dev/null 2>&1 || true; /opt/etc/init.d/S28xray-proxy0-watchdog stop >/dev/null 2>&1 || true; /opt/etc/init.d/S25xray-failover stop >/dev/null 2>&1 || true; /opt/etc/init.d/S23xray-main stop >/dev/null 2>&1 || true; /opt/etc/init.d/S24xray stop >/dev/null 2>&1 || true
cp "$SELECTED" "$TARGET"; chmod +x "$TARGET"; "$TARGET" version
/opt/etc/init.d/S24xray restart || true; /opt/etc/init.d/S23xray-main restart || true; /opt/etc/init.d/S25xray-failover restart || true; /opt/etc/init.d/S27xray-watchdog restart || true; /opt/etc/init.d/S28xray-proxy0-watchdog restart || true
EOF
    chmod +x /opt/bin/xray_core_rollback

    cat > /opt/bin/xray_failover_restore <<'EOF'
#!/bin/sh
BACKUP_DIR="/opt/backup/xray-failover"; LIST="/opt/tmp/xray-restore-list.txt"; : > "$LIST"; i=1
for f in $(ls -1t "$BACKUP_DIR"/xray-failover-backup-*.tar.gz 2>/dev/null); do echo "$i) $f"; echo "$f" >> "$LIST"; i=$((i+1)); done
[ -s "$LIST" ] || { echo "No backups."; exit 1; }
printf "Введите номер backup: "; read n; F="$(sed -n "${n}p" "$LIST")"; [ -f "$F" ] || { echo "Invalid selection"; exit 1; }
printf "Restore $F ? 1=yes: "; read c; [ "$c" = 1 ] || exit 0
tar -xzf "$F" -C /
chmod +x /opt/bin/xray* /opt/bin/vless* /opt/bin/failover /opt/etc/init.d/S2* 2>/dev/null || true
/opt/etc/init.d/S24xray restart || true; /opt/etc/init.d/S23xray-main restart || true; /opt/etc/init.d/S25xray-failover restart || true; /opt/etc/init.d/S27xray-watchdog restart || true; /opt/etc/init.d/S28xray-proxy0-watchdog restart || true
echo "Restore completed."
EOF
    chmod +x /opt/bin/xray_failover_restore
}


create_webui() {
    [ "$INSTALL_WEBUI" = "yes" ] || return 0

    WEBUI_DIR="/opt/etc/xray-webui"
    WEBUI_APP="/opt/libexec/xray-webui.py"
    WEBUI_INIT="/opt/etc/init.d/S29xray-webui"
    WEBUI_AUTH="$WEBUI_DIR/auth.env"
    WEBUI_PORT="8090"

    mkdir -p "$WEBUI_DIR" /opt/libexec /opt/etc/init.d /opt/var/log /opt/var/run

    if ! command -v python3 >/dev/null 2>&1; then
        opkg update
        opkg install python3
    fi

    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 192.168.1.1)"

    if [ ! -f "$WEBUI_AUTH" ]; then
        PASS="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)"
        [ -z "$PASS" ] && PASS="admin$(date +%s)"
        cat > "$WEBUI_AUTH" <<EOF
WEBUI_HOST="$ROUTER_LAN_IP"
WEBUI_PORT="$WEBUI_PORT"
WEBUI_USER="admin"
WEBUI_PASS="$PASS"
EOF
        chmod 600 "$WEBUI_AUTH"
    fi

    cat > "$WEBUI_APP" <<'PY'
#!/opt/bin/python3
import base64, html, os, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AUTH="/opt/etc/xray-webui/auth.env"
LOG="/opt/var/log/xray-webui.log"

def env():
    d={}
    try:
        for line in open(AUTH, encoding="utf-8"):
            line=line.strip()
            if line and not line.startswith("#") and "=" in line:
                k,v=line.split("=",1)
                d[k]=v.strip().strip('"').strip("'")
    except Exception:
        pass
    return d

E=env()
HOST=E.get("WEBUI_HOST","192.168.1.1")
PORT=int(E.get("WEBUI_PORT","8090"))
USER=E.get("WEBUI_USER","admin")
PASS=E.get("WEBUI_PASS","admin")

def run(cmd,timeout=180,extra=None):
    e=os.environ.copy()
    e["PATH"]="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin"
    if extra: e.update(extra)
    try:
        p=subprocess.run(cmd,shell=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,env=e)
        return p.returncode,p.stdout
    except subprocess.TimeoutExpired as x:
        return 124,(x.stdout or "")+"\\nTIMEOUT\\n"
    except Exception as x:
        return 1,str(x)

def rf(path):
    try: return open(path,encoding="utf-8").read().strip()
    except Exception: return ""

def wf(path,data,mode=0o600):
    os.makedirs(os.path.dirname(path),exist_ok=True)
    open(path,"w",encoding="utf-8").write(data.strip()+"\\n")
    os.chmod(path,mode)

def esc(x): return html.escape(str(x))
def rip(): return rf("/opt/etc/xray/router-lan-ip") or "192.168.1.1"
def mip(): return rf("/opt/etc/xray-main/router-lan-ip") or rip()
def active(): return rf("/opt/etc/xray/active-profile") or "unknown"
def alive(init): return run(init+" status >/dev/null 2>&1",20)[0]==0
def port(p): return run("netstat -lnt 2>/dev/null | grep -q ':%s'"%p,20)[0]==0
def xbin():
    for p in ["/opt/sbin/xray","/opt/bin/xray"]:
        if os.path.exists(p) and os.access(p,os.X_OK): return p
    return "xray"

def version():
    rc,out=run(xbin()+" version | head -n 1",20)
    return out.strip() if rc==0 else "unknown"

def gen(profile,url,host,port,out):
    return run("/opt/bin/xray-vless-generate-config",extra={"PROFILE_NAME":profile,"VLESS_URL":url,"LISTEN_HOST":host,"LISTEN_PORT":str(port),"OUTPUT_CONFIG":out})

def update_failover(primary,backup):
    primary=primary.strip(); backup=backup.strip()
    if not primary.startswith("vless://"): return 1,"Основная ссылка должна начинаться с vless://"
    wf("/opt/etc/xray/vless-primary.url",primary)
    if backup:
        if not backup.startswith("vless://"): return 1,"Резервная ссылка должна начинаться с vless://"
        wf("/opt/etc/xray/vless-backup.url",backup)
    else:
        try: os.remove("/opt/etc/xray/vless-backup.url")
        except FileNotFoundError: pass
    rc,out=gen("primary",primary,rip(),10808,"/opt/etc/xray/config.json")
    if rc: return rc,out
    rc2,out2=run(xbin()+" run -test -config /opt/etc/xray/config.json",60)
    if rc2: return rc2,out+"\\n"+out2
    wf("/opt/etc/xray/active-profile","primary",0o644)
    rc3,out3=run("/opt/etc/init.d/S24xray restart; sleep 5; /opt/bin/xray_proxy0_repair || true; /opt/etc/init.d/S25xray-failover restart; /opt/etc/init.d/S27xray-watchdog restart >/dev/null 2>&1 || true; /opt/etc/init.d/S28xray-proxy0-watchdog restart >/dev/null 2>&1 || true",240)
    return rc3,out+"\\n"+out2+"\\n"+out3

def update_main(link):
    link=link.strip()
    if not link.startswith("vless://"): return 1,"Ссылка Xray_main должна начинаться с vless://"
    wf("/opt/etc/xray-main/vless-main.url",link)
    rc,out=run("/opt/bin/xray_main_generate",60)
    if rc: return rc,out
    rc2,out2=run(xbin()+" run -test -config /opt/etc/xray-main/config.json",60)
    if rc2: return rc2,out+"\\n"+out2
    rc3,out3=run("/opt/etc/init.d/S23xray-main restart; sleep 5; /opt/bin/xray_main_proxy1_repair || true",240)
    return rc3,out+"\\n"+out2+"\\n"+out3

A={
"status":("Краткий статус","vless-failover-status",180),
"all_status":("Общий статус","xray_all_status",180),
"post_test":("Проверка после обновления","xray_post_update_test",180),
"events":("События переключения","xray_failover_events",180),
"xray_version":("Версия Xray core","xray_core_version",180),
"switch_primary":("Переключение на Primary","xray_switch primary",240),
"switch_backup":("Переключение на Backup","xray_switch backup",240),
"restart_failover":("Перезапуск failover","/opt/etc/init.d/S25xray-failover restart && /opt/etc/init.d/S25xray-failover status",180),
"restart_xray":("Перезапуск Xray","/opt/etc/init.d/S24xray restart && /opt/etc/init.d/S24xray status",180),
"repair_proxy0":("Восстановление Proxy0","xray_proxy0_repair",180),
"xray_main_status":("Статус Xray_main / Proxy1","xray_main_status",180),
"restart_xray_main":("Перезапуск Xray_main","/opt/etc/init.d/S23xray-main restart; sleep 5; xray_main_proxy1_repair; /opt/etc/init.d/S23xray-main status",240),
"repair_proxy1":("Восстановление Proxy1","xray_main_proxy1_repair",180),
"watchdog_status":("Статус watchdog","xray_watchdog_status && echo && xray_proxy0_watchdog_status",180),
"restart_watchdogs":("Перезапуск watchdog-ов","/opt/etc/init.d/S27xray-watchdog restart; /opt/etc/init.d/S28xray-proxy0-watchdog restart; /opt/etc/init.d/S27xray-watchdog status; /opt/etc/init.d/S28xray-proxy0-watchdog status",180),
"backup":("Backup конфигурации","xray_failover_backup",240),
"logs_failover":("Лог failover","tail -n 180 /opt/var/log/xray-vless-failover.log 2>/dev/null || true",180),
"logs_events":("События переключения","tail -n 180 /opt/var/log/xray-vless-events.log 2>/dev/null || true",180),
"logs_watchdog":("Лог Xray Watchdog","tail -n 180 /opt/var/log/xray-watchdog.log 2>/dev/null || true",180),
"logs_proxy0_watchdog":("Лог Proxy0 Watchdog","tail -n 180 /opt/var/log/xray-proxy0-watchdog.log 2>/dev/null || true",180),
"logs_core_update":("Лог обновления Xray core","tail -n 180 /opt/var/log/xray-core-update.log 2>/dev/null || true",180),
"logs_xray_main":("Лог Xray_main","tail -n 180 /opt/var/log/xray-main.log 2>/dev/null || true",180),
"update_core_latest_backup":("Обновление Xray latest с backup","XRAY_CORE_BACKUP=yes /opt/bin/xray_core_update_github latest",600),
"update_core_latest_nobackup":("Обновление Xray latest без backup","XRAY_CORE_BACKUP=no /opt/bin/xray_core_update_github latest",600),
"update_core_test_backup":("Обновление Xray test с backup","XRAY_CORE_BACKUP=yes /opt/bin/xray_core_update_github test",600),
"update_core_test_nobackup":("Обновление Xray test без backup","XRAY_CORE_BACKUP=no /opt/bin/xray_core_update_github test",600),
}

CSS="""
:root{--bg:#0d1624;--top:#111b2a;--rail:#0b1421;--a:#102a42;--card:#172436;--line:#2d3f55;--text:#e5edf7;--muted:#8ea1b7;--blue:#10a7ef;--green:#28c36a;--red:#ff615a;--yellow:#f0c64b}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 40% -10%,rgba(34,145,221,.14),transparent 42%),linear-gradient(180deg,#0d1624,#101a29);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;font-size:14px}.top{height:62px;background:#111b2a;display:flex;align-items:center;padding:0 26px;gap:24px;border-bottom:1px solid #0a101a;position:sticky;top:0;z-index:2}.logo{font-size:24px;font-weight:800;color:var(--blue)}.logo span{color:#e4edf7;font-weight:500}.sub{color:var(--muted);text-transform:uppercase;letter-spacing:.7px;border-left:1px solid #2c4057;padding-left:18px}.sp{flex:1}.ok{display:flex;gap:8px;align-items:center}.dot{width:9px;height:9px;border-radius:50%;background:var(--green);box-shadow:0 0 10px rgba(40,195,106,.85);display:inline-block}.dot.red{background:var(--red)}.dot.blue{background:var(--blue)}.shell{display:grid;grid-template-columns:176px 1fr;min-height:calc(100vh - 62px)}.side{background:linear-gradient(180deg,#0b1421,#0e1928);border-right:1px solid #142033;padding:12px 0}.side a{height:48px;display:grid;grid-template-columns:48px 1fr;align-items:center;color:#c9d7e7;text-decoration:none;border-left:3px solid transparent}.side a:hover,.side a.on{background:var(--a);border-left-color:var(--blue)}.ico{text-align:center;color:var(--blue);font-size:20px}.content{padding:18px}.head h1{margin:0 0 4px;font-size:26px}.head p{margin:0 0 16px;color:var(--muted)}.dash{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(420px,.9fr);gap:16px}.stack{display:grid;gap:16px;align-content:start}.card{background:linear-gradient(180deg,rgba(28,43,64,.96),rgba(23,36,54,.96));border:1px solid var(--line);border-radius:12px;overflow:hidden;box-shadow:0 14px 34px rgba(0,0,0,.16)}.ch{height:54px;display:flex;align-items:center;padding:0 20px;border-bottom:1px solid rgba(59,82,108,.55);font-size:18px;font-weight:700}.ch .ci{color:var(--blue);margin-right:10px}.ch .dots{margin-left:auto;color:#657993}.cb{padding:18px 20px 20px}.chips{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-bottom:18px}.chip{min-height:52px;border:1px solid #334960;background:rgba(19,31,48,.62);border-radius:8px;padding:12px;display:flex;gap:10px;align-items:center}.chip b{color:var(--green)}.metrics{border-top:1px solid rgba(59,82,108,.42);padding-top:16px;display:grid;grid-template-columns:repeat(5,1fr);gap:12px}.label{color:var(--muted);font-size:13px;margin-bottom:6px}.value{font-size:19px;color:#f3f8ff}.proxy{border-top:1px solid rgba(59,82,108,.46);padding:18px 0;display:grid;grid-template-columns:1fr 330px;gap:18px;align-items:center}.proxy:first-child{border-top:0;padding-top:2px}.pt{display:flex;gap:10px;align-items:center;font-size:18px;margin-bottom:14px}.pill{padding:4px 9px;border-radius:6px;background:rgba(40,195,106,.14);color:var(--green);font-size:12px;font-weight:700;margin-left:auto}.pill.red{background:rgba(255,97,90,.14);color:#ff958f}.details{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.actions,.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:10px}button,.btn{border:1px solid #286f9d;background:#173b57;color:#dff6ff;border-radius:7px;padding:10px;min-height:38px;cursor:pointer;font-weight:700;text-decoration:none;text-align:center}button:hover,.btn:hover{background:#19517a;border-color:var(--blue)}.green{background:#174b38;border-color:#2d9b67}.red{background:#512b32;border-color:#a54850}.yellow{background:#51451c;border-color:#9e8120}.ghost{background:rgba(29,45,66,.55);border-color:#3b536d}.primary{background:linear-gradient(180deg,#21a9f0,#1479ba);border-color:#2db8ff}.flow{display:grid;grid-template-columns:1fr 70px 1fr;align-items:center;gap:16px;padding:10px 4px 18px}.node{min-height:92px;border:1px solid #40566f;background:rgba(16,27,43,.55);border-radius:10px;padding:18px;text-align:center}.nt{font-size:16px;margin-bottom:6px}.ns{color:var(--muted);font-size:13px}.arr{color:var(--muted);font-size:34px;text-align:center}.watch{display:grid;grid-template-columns:1fr 110px 160px;gap:12px;padding:14px 0;border-top:1px solid rgba(59,82,108,.42)}.watch:first-child{border-top:0}.core{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;align-items:end}.cv{font-size:20px;color:var(--blue)}.log{display:grid;grid-template-columns:76px 86px 1fr 120px;gap:12px;padding:8px 0;border-bottom:1px solid rgba(59,82,108,.26)}.rt{text-align:right;color:var(--muted)}.backup{display:grid;grid-template-columns:1fr 1fr;gap:12px}.bi{border:1px solid #334960;background:rgba(19,31,48,.5);border-radius:8px;padding:16px}textarea{width:100%;min-height:96px;background:#0f1a29;border:1px solid #334960;color:#e5edf7;border-radius:8px;padding:10px;font-family:monospace}pre{margin:0;background:#0a111c;border:1px solid #30445b;color:#dcefff;border-radius:10px;padding:14px;overflow:auto;max-height:70vh}.notice{border:1px solid #6b4d2d;background:#3b2d2d;color:#ffd9c2;border-radius:8px;padding:12px}.muted{color:var(--muted)}@media(max-width:1100px){.dash{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)}.proxy{grid-template-columns:1fr}.shell{grid-template-columns:1fr}.side{display:none}}
"""

def nav(active):
    items=[("/","▦","Панель"),("/failover","◎","Failover"),("/main","◇","Proxy1"),("/watchdogs","⬡","Watchdog"),("/core","⬢","Ядро Xray"),("/logs","☷","Логи"),("/settings","⚙","Настройки")]
    return '<nav class="side">'+''.join(f'<a class="{"on" if active==h else ""}" href="{h}"><span class="ico">{esc(i)}</span><span>{esc(t)}</span></a>' for h,i,t in items)+'</nav>'

def card(title,body,icon=""):
    return f'<section class="card"><div class="ch"><span class="ci">{esc(icon)}</span>{esc(title)}<span class="dots">•••</span></div><div class="cb">{body}</div></section>'

def page(title,active,body,out=""):
    out_html=card("Вывод команды",f"<pre>{esc(out)}</pre>","☷") if out else ""
    return f'<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title><style>{CSS}</style></head><body><div class="top"><div class="logo">KEENETIC <span>XRAY</span></div><div class="sub">Мониторинг и управление прокси</div><div class="sp"></div><div class="ok"><span class="dot"></span> Система работает</div><div class="avatar">A</div></div><div class="shell">{nav(active)}<main class="content">{body}{out_html}</main></div></body></html>'

def action(a,t,cls=""):
    return f'<form method="post" action="/action" style="display:inline"><input type="hidden" name="action" value="{esc(a)}"><button class="{esc(cls)}" type="submit">{esc(t)}</button></form>'

class H(BaseHTTPRequestHandler):
    def auth_ok(self):
        h=self.headers.get("Authorization","")
        if not h.startswith("Basic "): return False
        try:
            raw=base64.b64decode(h.split(" ",1)[1]).decode()
            u,p=raw.split(":",1)
            return u==USER and p==PASS
        except Exception: return False
    def need_auth(self):
        self.send_response(401); self.send_header("WWW-Authenticate",'Basic realm="Xray WebUI"'); self.end_headers(); self.wfile.write(b"Authentication required")
    def send(self,s):
        b=s.encode("utf-8"); self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def postdata(self):
        raw=self.rfile.read(int(self.headers.get("Content-Length","0"))).decode("utf-8")
        return urllib.parse.parse_qs(raw)
    def do_GET(self):
        if not self.auth_ok(): return self.need_auth()
        p=urllib.parse.urlparse(self.path).path
        if p=="/":
            p0="OK" if port(10808) else "FAIL"; p1="OK" if port(10809) else "OFF"; w="работает" if alive("/opt/etc/init.d/S27xray-watchdog") else "не работает"; ver=version().split(" ")[1] if version().startswith("Xray ") else "unknown"
            head='<div class="head"><h1>Xray панель</h1><p>Мониторинг и управление VLESS, failover, Proxy0, Proxy1 и watchdog-сервисами</p></div>'
            c1=card("Статус системы",f'<div class="chips"><div class="chip"><span class="dot"></span> Основной канал: <b>{"online" if active()=="primary" else "monitor"}</b></div><div class="chip"><span class="dot blue"></span> Резервный канал: <span class="muted">{"standby" if rf("/opt/etc/xray/vless-backup.url") else "не задан"}</span></div></div><div class="metrics"><div><div class="label">Proxy0</div><div class="value">{p0}</div></div><div><div class="label">Proxy1</div><div class="value">{p1}</div></div><div><div class="label">Watchdog</div><div class="value">{w}</div></div><div><div class="label">Профиль</div><div class="value">{active()}</div></div><div><div class="label">Xray</div><div class="value">{ver}</div></div></div>',"◉")
            c2=card("Proxy0 и Proxy1",f'<div class="proxy"><div><div class="pt"><span class="dot"></span> Proxy0: 10808 <span class="pill">{p0}</span></div><div class="details"><div><div class="label">Протокол</div><div>VLESS</div></div><div><div class="label">Режим</div><div>Failover</div></div><div><div class="label">Адрес</div><div>{rip()}:10808</div></div></div></div><div class="actions">{action("status","Статус","ghost")}{action("repair_proxy0","Ремонт Proxy0")}{action("switch_primary","Primary","green")}{action("switch_backup","Backup")}</div></div><div class="proxy"><div><div class="pt"><span class="dot {"red" if p1=="OFF" else ""}"></span> Proxy1: 10809 <span class="pill {"red" if p1=="OFF" else ""}">{p1}</span></div><div class="details"><div><div class="label">Протокол</div><div>VLESS</div></div><div><div class="label">Режим</div><div>Xray_main</div></div><div><div class="label">Адрес</div><div>{mip()}:10809</div></div></div></div><div class="actions">{action("xray_main_status","Статус","ghost")}{action("repair_proxy1","Ремонт Proxy1")}{action("restart_xray_main","Restart")}<a class="btn" href="/main">Настройки</a></div></div>',"⬡")
            c3=card("Backup и управление",f'<div class="backup"><div class="bi"><b>Backup конфигурации</b><br><span class="muted">Создать резервную копию</span><br><br>{action("backup","Создать backup","ghost")}</div><div class="bi"><b>Проверка после обновления</b><br><span class="muted">Порты, сервисы, SOCKS5</span><br><br>{action("post_test","Запустить проверку")}</div></div>',"▣")
            r1=card("Failover Primary / Backup",'<div class="flow"><div class="node"><div class="nt">Primary</div><div class="ns">Основной канал<br><span style="color:var(--green)">online</span></div></div><div class="arr">← →</div><div class="node"><div class="nt">Backup</div><div class="ns">Резервный канал<br><span style="color:var(--blue)">standby</span></div></div></div><a class="link" href="/failover">Настройки failover ›</a>',"↻")
            r2=card("Watchdog-и",f'<div class="watch"><div><b>Watchdog Proxy0</b><br><span class="muted">Проверка каждые 30 сек.</span></div><div class="pill">{"Активен" if alive("/opt/etc/init.d/S27xray-watchdog") else "Ошибка"}</div><div class="muted">S27</div></div><div class="watch"><div><b>Watchdog Proxy0 Repair</b><br><span class="muted">Контроль Proxy0</span></div><div class="pill">{"Активен" if alive("/opt/etc/init.d/S28xray-proxy0-watchdog") else "Ошибка"}</div><div class="muted">S28</div></div>',"⬡")
            r3=card("Обновление Xray core",f'<div class="core"><div><div class="muted">Версия</div><div class="cv">{ver}</div></div><div><div class="muted">Источник</div><div class="cv">GitHub</div></div><div><div class="muted">Статус</div><div style="color:var(--green)">✓ Готово</div></div><a class="btn" href="/core">Обновить core</a></div>',"⬢")
            lines=rf("/opt/var/log/xray-vless-events.log").splitlines()[-4:] or ["Событий пока нет"]; rows=""
            for line in lines:
                rows+=f'<div class="log"><div class="muted">—</div><div><span class="dot blue"></span> event</div><div>{esc(line)}</div><div class="rt">—</div></div>'
            r4=card("Логи и события",rows+'<a class="link" href="/logs">Перейти к логам ›</a>',"☷")
            return self.send(page("Панель","/",head+f'<div class="dash"><div class="stack">{c1}{c2}{c3}</div><div class="stack">{r1}{r2}{r3}{r4}</div></div>'))
        if p=="/failover":
            body='<div class="head"><h1>Failover Primary / Backup</h1><p>Управление основной и резервной VLESS-ссылкой</p></div>'+card("Действия",f'<div class="grid">{action("status","Краткий статус")}{action("switch_primary","Переключить Primary","green")}{action("switch_backup","Переключить Backup")}{action("restart_xray","Restart Xray")}{action("restart_failover","Restart Failover")}{action("repair_proxy0","Repair Proxy0")}</div>',"↻")+card("Обновить VLESS-ссылки",f'<form method="post" action="/update_failover"><label>Основная VLESS-ссылка</label><textarea name="primary">{esc(rf("/opt/etc/xray/vless-primary.url"))}</textarea><label>Резервная VLESS-ссылка</label><textarea name="backup">{esc(rf("/opt/etc/xray/vless-backup.url"))}</textarea><br><br><button class="primary" type="submit">Сохранить и перезапустить</button></form>',"◎")
            return self.send(page("Failover","/failover",body))
        if p=="/main":
            body='<div class="head"><h1>Xray_main / Proxy1</h1><p>Отдельная VLESS-ссылка без резервирования</p></div>'+card("Действия Proxy1",f'<div class="grid">{action("xray_main_status","Статус")}{action("restart_xray_main","Перезапустить")}{action("repair_proxy1","Починить Proxy1")}</div>',"◇")+card("Обновить VLESS для Xray_main",f'<form method="post" action="/update_main"><label>VLESS-ссылка Xray_main</label><textarea name="main">{esc(rf("/opt/etc/xray-main/vless-main.url"))}</textarea><br><br><button class="primary" type="submit">Сохранить и перезапустить Proxy1</button></form>',"◇")
            return self.send(page("Xray_main","/main",body))
        if p=="/watchdogs":
            return self.send(page("Watchdog-и","/watchdogs",'<div class="head"><h1>Watchdog-и</h1><p>Мониторинг и восстановление</p></div>'+card("Управление watchdog",f'<div class="grid">{action("watchdog_status","Статус watchdog")}{action("restart_watchdogs","Перезапустить watchdog-и")}</div>',"⬡")))
        if p=="/core":
            return self.send(page("Xray core","/core",'<div class="head"><h1>Обновление Xray core</h1><p>Обновление latest или test/pre-release из GitHub</p></div>'+card("Xray core",f'<div class="grid">{action("xray_version","Версия Xray")}{action("update_core_latest_backup","Latest GitHub + backup","green")}{action("update_core_latest_nobackup","Latest GitHub без backup")}{action("update_core_test_backup","Test/pre-release + backup","yellow")}{action("update_core_test_nobackup","Test/pre-release без backup","red")}{action("backup","Backup конфигурации")}</div><br><div class="notice">Обновление ядра может занять несколько минут.</div>',"⬢")))
        if p=="/logs":
            return self.send(page("Логи","/logs",'<div class="head"><h1>Логи</h1><p>Просмотр журналов</p></div>'+card("Журналы",f'<div class="grid">{action("logs_failover","Failover log")}{action("logs_events","События")}{action("logs_watchdog","Xray Watchdog")}{action("logs_proxy0_watchdog","Proxy0 Watchdog")}{action("logs_core_update","Core update")}{action("logs_xray_main","Xray_main")}</div>',"☷")))
        if p=="/settings":
            return self.send(page("Настройки","/settings",'<div class="head"><h1>Настройки</h1><p>Параметры WebUI</p></div>'+card("Настройки WebUI",f'<div class="details"><div><div class="label">Адрес</div><div>http://{esc(HOST)}:{PORT}</div></div><div><div class="label">Пользователь</div><div>{esc(USER)}</div></div><div><div class="label">Файл авторизации</div><div>{esc(AUTH)}</div></div></div><br><div class="notice">Сменить пароль: xray_webui_password</div>',"⚙")))
        self.send_error(404)
    def do_POST(self):
        if not self.auth_ok(): return self.need_auth()
        p=urllib.parse.urlparse(self.path).path; d=self.postdata()
        if p=="/action":
            a=d.get("action",[""])[0]
            if a not in A: return self.send(page("Ошибка","/",card("Ошибка","Неизвестное действие","⚠")))
            title,cmd,timeout=A[a]; rc,out=run(cmd,timeout=timeout)
            return self.send(page(title,"/",'<div class="head"><h1>Результат команды</h1><p>Выполнено действие из WebUI</p></div>'+card(title,f'<div class="details"><div><div class="label">Действие</div><div>{esc(a)}</div></div><div><div class="label">Код возврата</div><div>{rc}</div></div><div><div class="label">Команда</div><div>{esc(cmd)}</div></div></div><br><a class="btn" href="/">Назад</a>',"☷"),out))
        if p=="/update_failover":
            rc,out=update_failover(d.get("primary",[""])[0],d.get("backup",[""])[0])
            return self.send(page("Обновление Failover","/failover",card("Обновление Failover",f'Код возврата: {rc}<br><br><a class="btn" href="/failover">Назад</a>',"◎"),out))
        if p=="/update_main":
            rc,out=update_main(d.get("main",[""])[0])
            return self.send(page("Обновление Xray_main","/main",card("Обновление Xray_main",f'Код возврата: {rc}<br><br><a class="btn" href="/main">Назад</a>',"◇"),out))
        self.send_error(404)

ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY
    chmod +x "$WEBUI_APP"

    cat > "$WEBUI_INIT" <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
DESC="Xray WebUI"
PYTHON_BIN="/opt/bin/python3"
DAEMON="/opt/libexec/xray-webui.py"
PIDFILE="/opt/var/run/xray-webui.pid"
LOGFILE="/opt/var/log/xray-webui.log"
mkdir -p /opt/var/run /opt/var/log
[ -x "$PYTHON_BIN" ] || PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
is_running(){ [ -f "$PIDFILE" ] || return 1; PID="$(cat "$PIDFILE" 2>/dev/null)"; [ -n "$PID" ] || return 1; kill -0 "$PID" 2>/dev/null; }
start(){ printf " Запускаем %s... " "$DESC"; if is_running; then echo "уже запущен."; exit 0; fi; [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] || { echo "ошибка."; echo "python3 не найден"; exit 1; }; [ -f "$DAEMON" ] || { echo "ошибка."; echo "WebUI app не найден: $DAEMON"; exit 1; }; "$PYTHON_BIN" "$DAEMON" >> "$LOGFILE" 2>&1 & echo "$!" > "$PIDFILE"; sleep 2; if is_running; then echo "готово."; exit 0; fi; echo "ошибка."; tail -n 80 "$LOGFILE" 2>/dev/null || true; rm -f "$PIDFILE"; exit 1; }
stop(){ printf " Останавливаем %s... " "$DESC"; if ! is_running; then echo "не запущен."; rm -f "$PIDFILE"; exit 0; fi; PID="$(cat "$PIDFILE" 2>/dev/null)"; kill "$PID" 2>/dev/null || true; sleep 2; kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true; rm -f "$PIDFILE"; echo "готово."; }
status(){ printf " Проверяем %s... " "$DESC"; if is_running; then echo "работает. PID: $(cat "$PIDFILE")"; exit 0; fi; echo "не запущен."; exit 1; }
restart(){ "$0" stop; sleep 1; "$0" start; }
case "${1:-}" in start) start;; stop) stop;; restart) restart;; status) status;; *) echo "Использование: $0 {start|stop|restart|status}"; exit 1;; esac
EOF
    chmod +x "$WEBUI_INIT"

    cat > /opt/bin/xray_webui_status <<'EOF'
#!/bin/sh
echo "Xray WebUI:"
/opt/etc/init.d/S29xray-webui status 2>&1 || true
echo
echo "Auth:"
cat /opt/etc/xray-webui/auth.env 2>/dev/null || true
echo
echo "Port:"
netstat -lntp 2>/dev/null | grep 8090 || true
echo
echo "Recent log:"
tail -n 40 /opt/var/log/xray-webui.log 2>/dev/null || true
EOF
    chmod +x /opt/bin/xray_webui_status

    cat > /opt/bin/xray_webui_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log
touch /opt/var/log/xray-webui.log
tail -f /opt/var/log/xray-webui.log
EOF
    chmod +x /opt/bin/xray_webui_log

    cat > /opt/bin/xray_webui_password <<'EOF'
#!/bin/sh
AUTH="/opt/etc/xray-webui/auth.env"
[ -f "$AUTH" ] || { echo "Auth file not found: $AUTH"; exit 1; }
printf "New WebUI password: "
read PASS
[ -z "$PASS" ] && { echo "Password is empty"; exit 1; }
USER="$(grep '^WEBUI_USER=' "$AUTH" | cut -d= -f2- | tr -d '"')"
HOST="$(grep '^WEBUI_HOST=' "$AUTH" | cut -d= -f2- | tr -d '"')"
PORT="$(grep '^WEBUI_PORT=' "$AUTH" | cut -d= -f2- | tr -d '"')"
[ -z "$USER" ] && USER="admin"
[ -z "$HOST" ] && HOST="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 192.168.1.1)"
[ -z "$PORT" ] && PORT="8090"
cat > "$AUTH" <<EOF2
WEBUI_HOST="$HOST"
WEBUI_PORT="$PORT"
WEBUI_USER="$USER"
WEBUI_PASS="$PASS"
EOF2
chmod 600 "$AUTH"
/opt/etc/init.d/S29xray-webui restart
echo "Password updated."
EOF
    chmod +x /opt/bin/xray_webui_password

    python3 -m py_compile "$WEBUI_APP"
    "$WEBUI_INIT" restart
}


create_webui_manage_commands() {
    cat > /opt/bin/xray_webui_install <<'WEBUIINSTALL'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
ROUTER_IP_STORE="/opt/etc/xray/router-lan-ip"
WEBUI_DIR="/opt/etc/xray-webui"
WEBUI_APP="/opt/libexec/xray-webui.py"
WEBUI_INIT="/opt/etc/init.d/S29xray-webui"
WEBUI_AUTH="$WEBUI_DIR/auth.env"
WEBUI_PORT="8090"

mkdir -p "$WEBUI_DIR" /opt/libexec /opt/etc/init.d /opt/var/log /opt/var/run

if ! command -v python3 >/dev/null 2>&1; then
    opkg update
    opkg install python3
fi

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 192.168.1.1)"

if [ ! -f "$WEBUI_AUTH" ]; then
    PASS="$(dd if=/dev/urandom bs=24 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16)"
    [ -z "$PASS" ] && PASS="admin$(date +%s)"
    cat > "$WEBUI_AUTH" <<EOF
WEBUI_HOST="$ROUTER_LAN_IP"
WEBUI_PORT="$WEBUI_PORT"
WEBUI_USER="admin"
WEBUI_PASS="$PASS"
EOF
    chmod 600 "$WEBUI_AUTH"
fi

cat > "$WEBUI_APP" <<'PY'
#!/opt/bin/python3
import base64, html, os, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AUTH="/opt/etc/xray-webui/auth.env"
LOG="/opt/var/log/xray-webui.log"

def env():
d={}
try:
    for line in open(AUTH, encoding="utf-8"):
        line=line.strip()
        if line and not line.startswith("#") and "=" in line:
            k,v=line.split("=",1)
            d[k]=v.strip().strip('"').strip("'")
except Exception:
    pass
return d

E=env()
HOST=E.get("WEBUI_HOST","192.168.1.1")
PORT=int(E.get("WEBUI_PORT","8090"))
USER=E.get("WEBUI_USER","admin")
PASS=E.get("WEBUI_PASS","admin")

def run(cmd,timeout=180,extra=None):
e=os.environ.copy()
e["PATH"]="/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin"
if extra: e.update(extra)
try:
    p=subprocess.run(cmd,shell=True,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,env=e)
    return p.returncode,p.stdout
except subprocess.TimeoutExpired as x:
    return 124,(x.stdout or "")+"\\nTIMEOUT\\n"
except Exception as x:
    return 1,str(x)

def rf(path):
try: return open(path,encoding="utf-8").read().strip()
except Exception: return ""

def wf(path,data,mode=0o600):
os.makedirs(os.path.dirname(path),exist_ok=True)
open(path,"w",encoding="utf-8").write(data.strip()+"\\n")
os.chmod(path,mode)

def esc(x): return html.escape(str(x))
def rip(): return rf("/opt/etc/xray/router-lan-ip") or "192.168.1.1"
def mip(): return rf("/opt/etc/xray-main/router-lan-ip") or rip()
def active(): return rf("/opt/etc/xray/active-profile") or "unknown"
def alive(init): return run(init+" status >/dev/null 2>&1",20)[0]==0
def port(p): return run("netstat -lnt 2>/dev/null | grep -q ':%s'"%p,20)[0]==0
def xbin():
for p in ["/opt/sbin/xray","/opt/bin/xray"]:
    if os.path.exists(p) and os.access(p,os.X_OK): return p
return "xray"

def version():
rc,out=run(xbin()+" version | head -n 1",20)
return out.strip() if rc==0 else "unknown"

def gen(profile,url,host,port,out):
return run("/opt/bin/xray-vless-generate-config",extra={"PROFILE_NAME":profile,"VLESS_URL":url,"LISTEN_HOST":host,"LISTEN_PORT":str(port),"OUTPUT_CONFIG":out})

def update_failover(primary,backup):
primary=primary.strip(); backup=backup.strip()
if not primary.startswith("vless://"): return 1,"Основная ссылка должна начинаться с vless://"
wf("/opt/etc/xray/vless-primary.url",primary)
if backup:
    if not backup.startswith("vless://"): return 1,"Резервная ссылка должна начинаться с vless://"
    wf("/opt/etc/xray/vless-backup.url",backup)
else:
    try: os.remove("/opt/etc/xray/vless-backup.url")
    except FileNotFoundError: pass
rc,out=gen("primary",primary,rip(),10808,"/opt/etc/xray/config.json")
if rc: return rc,out
rc2,out2=run(xbin()+" run -test -config /opt/etc/xray/config.json",60)
if rc2: return rc2,out+"\\n"+out2
wf("/opt/etc/xray/active-profile","primary",0o644)
rc3,out3=run("/opt/etc/init.d/S24xray restart; sleep 5; /opt/bin/xray_proxy0_repair || true; /opt/etc/init.d/S25xray-failover restart; /opt/etc/init.d/S27xray-watchdog restart >/dev/null 2>&1 || true; /opt/etc/init.d/S28xray-proxy0-watchdog restart >/dev/null 2>&1 || true",240)
return rc3,out+"\\n"+out2+"\\n"+out3

def update_main(link):
link=link.strip()
if not link.startswith("vless://"): return 1,"Ссылка Xray_main должна начинаться с vless://"
wf("/opt/etc/xray-main/vless-main.url",link)
rc,out=run("/opt/bin/xray_main_generate",60)
if rc: return rc,out
rc2,out2=run(xbin()+" run -test -config /opt/etc/xray-main/config.json",60)
if rc2: return rc2,out+"\\n"+out2
rc3,out3=run("/opt/etc/init.d/S23xray-main restart; sleep 5; /opt/bin/xray_main_proxy1_repair || true",240)
return rc3,out+"\\n"+out2+"\\n"+out3

A={
"status":("Краткий статус","vless-failover-status",180),
"all_status":("Общий статус","xray_all_status",180),
"post_test":("Проверка после обновления","xray_post_update_test",180),
"events":("События переключения","xray_failover_events",180),
"xray_version":("Версия Xray core","xray_core_version",180),
"switch_primary":("Переключение на Primary","xray_switch primary",240),
"switch_backup":("Переключение на Backup","xray_switch backup",240),
"restart_failover":("Перезапуск failover","/opt/etc/init.d/S25xray-failover restart && /opt/etc/init.d/S25xray-failover status",180),
"restart_xray":("Перезапуск Xray","/opt/etc/init.d/S24xray restart && /opt/etc/init.d/S24xray status",180),
"repair_proxy0":("Восстановление Proxy0","xray_proxy0_repair",180),
"xray_main_status":("Статус Xray_main / Proxy1","xray_main_status",180),
"restart_xray_main":("Перезапуск Xray_main","/opt/etc/init.d/S23xray-main restart; sleep 5; xray_main_proxy1_repair; /opt/etc/init.d/S23xray-main status",240),
"repair_proxy1":("Восстановление Proxy1","xray_main_proxy1_repair",180),
"watchdog_status":("Статус watchdog","xray_watchdog_status && echo && xray_proxy0_watchdog_status",180),
"restart_watchdogs":("Перезапуск watchdog-ов","/opt/etc/init.d/S27xray-watchdog restart; /opt/etc/init.d/S28xray-proxy0-watchdog restart; /opt/etc/init.d/S27xray-watchdog status; /opt/etc/init.d/S28xray-proxy0-watchdog status",180),
"backup":("Backup конфигурации","xray_failover_backup",240),
"logs_failover":("Лог failover","tail -n 180 /opt/var/log/xray-vless-failover.log 2>/dev/null || true",180),
"logs_events":("События переключения","tail -n 180 /opt/var/log/xray-vless-events.log 2>/dev/null || true",180),
"logs_watchdog":("Лог Xray Watchdog","tail -n 180 /opt/var/log/xray-watchdog.log 2>/dev/null || true",180),
"logs_proxy0_watchdog":("Лог Proxy0 Watchdog","tail -n 180 /opt/var/log/xray-proxy0-watchdog.log 2>/dev/null || true",180),
"logs_core_update":("Лог обновления Xray core","tail -n 180 /opt/var/log/xray-core-update.log 2>/dev/null || true",180),
"logs_xray_main":("Лог Xray_main","tail -n 180 /opt/var/log/xray-main.log 2>/dev/null || true",180),
"update_core_latest_backup":("Обновление Xray latest с backup","XRAY_CORE_BACKUP=yes /opt/bin/xray_core_update_github latest",600),
"update_core_latest_nobackup":("Обновление Xray latest без backup","XRAY_CORE_BACKUP=no /opt/bin/xray_core_update_github latest",600),
"update_core_test_backup":("Обновление Xray test с backup","XRAY_CORE_BACKUP=yes /opt/bin/xray_core_update_github test",600),
"update_core_test_nobackup":("Обновление Xray test без backup","XRAY_CORE_BACKUP=no /opt/bin/xray_core_update_github test",600),
}

CSS="""
:root{--bg:#0d1624;--top:#111b2a;--rail:#0b1421;--a:#102a42;--card:#172436;--line:#2d3f55;--text:#e5edf7;--muted:#8ea1b7;--blue:#10a7ef;--green:#28c36a;--red:#ff615a;--yellow:#f0c64b}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 40% -10%,rgba(34,145,221,.14),transparent 42%),linear-gradient(180deg,#0d1624,#101a29);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;font-size:14px}.top{height:62px;background:#111b2a;display:flex;align-items:center;padding:0 26px;gap:24px;border-bottom:1px solid #0a101a;position:sticky;top:0;z-index:2}.logo{font-size:24px;font-weight:800;color:var(--blue)}.logo span{color:#e4edf7;font-weight:500}.sub{color:var(--muted);text-transform:uppercase;letter-spacing:.7px;border-left:1px solid #2c4057;padding-left:18px}.sp{flex:1}.ok{display:flex;gap:8px;align-items:center}.dot{width:9px;height:9px;border-radius:50%;background:var(--green);box-shadow:0 0 10px rgba(40,195,106,.85);display:inline-block}.dot.red{background:var(--red)}.dot.blue{background:var(--blue)}.shell{display:grid;grid-template-columns:176px 1fr;min-height:calc(100vh - 62px)}.side{background:linear-gradient(180deg,#0b1421,#0e1928);border-right:1px solid #142033;padding:12px 0}.side a{height:48px;display:grid;grid-template-columns:48px 1fr;align-items:center;color:#c9d7e7;text-decoration:none;border-left:3px solid transparent}.side a:hover,.side a.on{background:var(--a);border-left-color:var(--blue)}.ico{text-align:center;color:var(--blue);font-size:20px}.content{padding:18px}.head h1{margin:0 0 4px;font-size:26px}.head p{margin:0 0 16px;color:var(--muted)}.dash{display:grid;grid-template-columns:minmax(0,1.1fr) minmax(420px,.9fr);gap:16px}.stack{display:grid;gap:16px;align-content:start}.card{background:linear-gradient(180deg,rgba(28,43,64,.96),rgba(23,36,54,.96));border:1px solid var(--line);border-radius:12px;overflow:hidden;box-shadow:0 14px 34px rgba(0,0,0,.16)}.ch{height:54px;display:flex;align-items:center;padding:0 20px;border-bottom:1px solid rgba(59,82,108,.55);font-size:18px;font-weight:700}.ch .ci{color:var(--blue);margin-right:10px}.ch .dots{margin-left:auto;color:#657993}.cb{padding:18px 20px 20px}.chips{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-bottom:18px}.chip{min-height:52px;border:1px solid #334960;background:rgba(19,31,48,.62);border-radius:8px;padding:12px;display:flex;gap:10px;align-items:center}.chip b{color:var(--green)}.metrics{border-top:1px solid rgba(59,82,108,.42);padding-top:16px;display:grid;grid-template-columns:repeat(5,1fr);gap:12px}.label{color:var(--muted);font-size:13px;margin-bottom:6px}.value{font-size:19px;color:#f3f8ff}.proxy{border-top:1px solid rgba(59,82,108,.46);padding:18px 0;display:grid;grid-template-columns:1fr 330px;gap:18px;align-items:center}.proxy:first-child{border-top:0;padding-top:2px}.pt{display:flex;gap:10px;align-items:center;font-size:18px;margin-bottom:14px}.pill{padding:4px 9px;border-radius:6px;background:rgba(40,195,106,.14);color:var(--green);font-size:12px;font-weight:700;margin-left:auto}.pill.red{background:rgba(255,97,90,.14);color:#ff958f}.details{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.actions,.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(155px,1fr));gap:10px}button,.btn{border:1px solid #286f9d;background:#173b57;color:#dff6ff;border-radius:7px;padding:10px;min-height:38px;cursor:pointer;font-weight:700;text-decoration:none;text-align:center}button:hover,.btn:hover{background:#19517a;border-color:var(--blue)}.green{background:#174b38;border-color:#2d9b67}.red{background:#512b32;border-color:#a54850}.yellow{background:#51451c;border-color:#9e8120}.ghost{background:rgba(29,45,66,.55);border-color:#3b536d}.primary{background:linear-gradient(180deg,#21a9f0,#1479ba);border-color:#2db8ff}.flow{display:grid;grid-template-columns:1fr 70px 1fr;align-items:center;gap:16px;padding:10px 4px 18px}.node{min-height:92px;border:1px solid #40566f;background:rgba(16,27,43,.55);border-radius:10px;padding:18px;text-align:center}.nt{font-size:16px;margin-bottom:6px}.ns{color:var(--muted);font-size:13px}.arr{color:var(--muted);font-size:34px;text-align:center}.watch{display:grid;grid-template-columns:1fr 110px 160px;gap:12px;padding:14px 0;border-top:1px solid rgba(59,82,108,.42)}.watch:first-child{border-top:0}.core{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;align-items:end}.cv{font-size:20px;color:var(--blue)}.log{display:grid;grid-template-columns:76px 86px 1fr 120px;gap:12px;padding:8px 0;border-bottom:1px solid rgba(59,82,108,.26)}.rt{text-align:right;color:var(--muted)}.backup{display:grid;grid-template-columns:1fr 1fr;gap:12px}.bi{border:1px solid #334960;background:rgba(19,31,48,.5);border-radius:8px;padding:16px}textarea{width:100%;min-height:96px;background:#0f1a29;border:1px solid #334960;color:#e5edf7;border-radius:8px;padding:10px;font-family:monospace}pre{margin:0;background:#0a111c;border:1px solid #30445b;color:#dcefff;border-radius:10px;padding:14px;overflow:auto;max-height:70vh}.notice{border:1px solid #6b4d2d;background:#3b2d2d;color:#ffd9c2;border-radius:8px;padding:12px}.muted{color:var(--muted)}@media(max-width:1100px){.dash{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)}.proxy{grid-template-columns:1fr}.shell{grid-template-columns:1fr}.side{display:none}}
"""

def nav(active):
items=[("/","▦","Панель"),("/failover","◎","Failover"),("/main","◇","Proxy1"),("/watchdogs","⬡","Watchdog"),("/core","⬢","Ядро Xray"),("/logs","☷","Логи"),("/settings","⚙","Настройки")]
return '<nav class="side">'+''.join(f'<a class="{"on" if active==h else ""}" href="{h}"><span class="ico">{esc(i)}</span><span>{esc(t)}</span></a>' for h,i,t in items)+'</nav>'

def card(title,body,icon=""):
return f'<section class="card"><div class="ch"><span class="ci">{esc(icon)}</span>{esc(title)}<span class="dots">•••</span></div><div class="cb">{body}</div></section>'

def page(title,active,body,out=""):
out_html=card("Вывод команды",f"<pre>{esc(out)}</pre>","☷") if out else ""
return f'<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)}</title><style>{CSS}</style></head><body><div class="top"><div class="logo">KEENETIC <span>XRAY</span></div><div class="sub">Мониторинг и управление прокси</div><div class="sp"></div><div class="ok"><span class="dot"></span> Система работает</div><div class="avatar">A</div></div><div class="shell">{nav(active)}<main class="content">{body}{out_html}</main></div></body></html>'

def action(a,t,cls=""):
return f'<form method="post" action="/action" style="display:inline"><input type="hidden" name="action" value="{esc(a)}"><button class="{esc(cls)}" type="submit">{esc(t)}</button></form>'

class H(BaseHTTPRequestHandler):
def auth_ok(self):
    h=self.headers.get("Authorization","")
    if not h.startswith("Basic "): return False
    try:
        raw=base64.b64decode(h.split(" ",1)[1]).decode()
        u,p=raw.split(":",1)
        return u==USER and p==PASS
    except Exception: return False
def need_auth(self):
    self.send_response(401); self.send_header("WWW-Authenticate",'Basic realm="Xray WebUI"'); self.end_headers(); self.wfile.write(b"Authentication required")
def send(self,s):
    b=s.encode("utf-8"); self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
def postdata(self):
    raw=self.rfile.read(int(self.headers.get("Content-Length","0"))).decode("utf-8")
    return urllib.parse.parse_qs(raw)
def do_GET(self):
    if not self.auth_ok(): return self.need_auth()
    p=urllib.parse.urlparse(self.path).path
    if p=="/":
        p0="OK" if port(10808) else "FAIL"; p1="OK" if port(10809) else "OFF"; w="работает" if alive("/opt/etc/init.d/S27xray-watchdog") else "не работает"; ver=version().split(" ")[1] if version().startswith("Xray ") else "unknown"
        head='<div class="head"><h1>Xray панель</h1><p>Мониторинг и управление VLESS, failover, Proxy0, Proxy1 и watchdog-сервисами</p></div>'
        c1=card("Статус системы",f'<div class="chips"><div class="chip"><span class="dot"></span> Основной канал: <b>{"online" if active()=="primary" else "monitor"}</b></div><div class="chip"><span class="dot blue"></span> Резервный канал: <span class="muted">{"standby" if rf("/opt/etc/xray/vless-backup.url") else "не задан"}</span></div></div><div class="metrics"><div><div class="label">Proxy0</div><div class="value">{p0}</div></div><div><div class="label">Proxy1</div><div class="value">{p1}</div></div><div><div class="label">Watchdog</div><div class="value">{w}</div></div><div><div class="label">Профиль</div><div class="value">{active()}</div></div><div><div class="label">Xray</div><div class="value">{ver}</div></div></div>',"◉")
        c2=card("Proxy0 и Proxy1",f'<div class="proxy"><div><div class="pt"><span class="dot"></span> Proxy0: 10808 <span class="pill">{p0}</span></div><div class="details"><div><div class="label">Протокол</div><div>VLESS</div></div><div><div class="label">Режим</div><div>Failover</div></div><div><div class="label">Адрес</div><div>{rip()}:10808</div></div></div></div><div class="actions">{action("status","Статус","ghost")}{action("repair_proxy0","Ремонт Proxy0")}{action("switch_primary","Primary","green")}{action("switch_backup","Backup")}</div></div><div class="proxy"><div><div class="pt"><span class="dot {"red" if p1=="OFF" else ""}"></span> Proxy1: 10809 <span class="pill {"red" if p1=="OFF" else ""}">{p1}</span></div><div class="details"><div><div class="label">Протокол</div><div>VLESS</div></div><div><div class="label">Режим</div><div>Xray_main</div></div><div><div class="label">Адрес</div><div>{mip()}:10809</div></div></div></div><div class="actions">{action("xray_main_status","Статус","ghost")}{action("repair_proxy1","Ремонт Proxy1")}{action("restart_xray_main","Restart")}<a class="btn" href="/main">Настройки</a></div></div>',"⬡")
        c3=card("Backup и управление",f'<div class="backup"><div class="bi"><b>Backup конфигурации</b><br><span class="muted">Создать резервную копию</span><br><br>{action("backup","Создать backup","ghost")}</div><div class="bi"><b>Проверка после обновления</b><br><span class="muted">Порты, сервисы, SOCKS5</span><br><br>{action("post_test","Запустить проверку")}</div></div>',"▣")
        r1=card("Failover Primary / Backup",'<div class="flow"><div class="node"><div class="nt">Primary</div><div class="ns">Основной канал<br><span style="color:var(--green)">online</span></div></div><div class="arr">← →</div><div class="node"><div class="nt">Backup</div><div class="ns">Резервный канал<br><span style="color:var(--blue)">standby</span></div></div></div><a class="link" href="/failover">Настройки failover ›</a>',"↻")
        r2=card("Watchdog-и",f'<div class="watch"><div><b>Watchdog Proxy0</b><br><span class="muted">Проверка каждые 30 сек.</span></div><div class="pill">{"Активен" if alive("/opt/etc/init.d/S27xray-watchdog") else "Ошибка"}</div><div class="muted">S27</div></div><div class="watch"><div><b>Watchdog Proxy0 Repair</b><br><span class="muted">Контроль Proxy0</span></div><div class="pill">{"Активен" if alive("/opt/etc/init.d/S28xray-proxy0-watchdog") else "Ошибка"}</div><div class="muted">S28</div></div>',"⬡")
        r3=card("Обновление Xray core",f'<div class="core"><div><div class="muted">Версия</div><div class="cv">{ver}</div></div><div><div class="muted">Источник</div><div class="cv">GitHub</div></div><div><div class="muted">Статус</div><div style="color:var(--green)">✓ Готово</div></div><a class="btn" href="/core">Обновить core</a></div>',"⬢")
        lines=rf("/opt/var/log/xray-vless-events.log").splitlines()[-4:] or ["Событий пока нет"]; rows=""
        for line in lines:
            rows+=f'<div class="log"><div class="muted">—</div><div><span class="dot blue"></span> event</div><div>{esc(line)}</div><div class="rt">—</div></div>'
        r4=card("Логи и события",rows+'<a class="link" href="/logs">Перейти к логам ›</a>',"☷")
        return self.send(page("Панель","/",head+f'<div class="dash"><div class="stack">{c1}{c2}{c3}</div><div class="stack">{r1}{r2}{r3}{r4}</div></div>'))
    if p=="/failover":
        body='<div class="head"><h1>Failover Primary / Backup</h1><p>Управление основной и резервной VLESS-ссылкой</p></div>'+card("Действия",f'<div class="grid">{action("status","Краткий статус")}{action("switch_primary","Переключить Primary","green")}{action("switch_backup","Переключить Backup")}{action("restart_xray","Restart Xray")}{action("restart_failover","Restart Failover")}{action("repair_proxy0","Repair Proxy0")}</div>',"↻")+card("Обновить VLESS-ссылки",f'<form method="post" action="/update_failover"><label>Основная VLESS-ссылка</label><textarea name="primary">{esc(rf("/opt/etc/xray/vless-primary.url"))}</textarea><label>Резервная VLESS-ссылка</label><textarea name="backup">{esc(rf("/opt/etc/xray/vless-backup.url"))}</textarea><br><br><button class="primary" type="submit">Сохранить и перезапустить</button></form>',"◎")
        return self.send(page("Failover","/failover",body))
    if p=="/main":
        body='<div class="head"><h1>Xray_main / Proxy1</h1><p>Отдельная VLESS-ссылка без резервирования</p></div>'+card("Действия Proxy1",f'<div class="grid">{action("xray_main_status","Статус")}{action("restart_xray_main","Перезапустить")}{action("repair_proxy1","Починить Proxy1")}</div>',"◇")+card("Обновить VLESS для Xray_main",f'<form method="post" action="/update_main"><label>VLESS-ссылка Xray_main</label><textarea name="main">{esc(rf("/opt/etc/xray-main/vless-main.url"))}</textarea><br><br><button class="primary" type="submit">Сохранить и перезапустить Proxy1</button></form>',"◇")
        return self.send(page("Xray_main","/main",body))
    if p=="/watchdogs":
        return self.send(page("Watchdog-и","/watchdogs",'<div class="head"><h1>Watchdog-и</h1><p>Мониторинг и восстановление</p></div>'+card("Управление watchdog",f'<div class="grid">{action("watchdog_status","Статус watchdog")}{action("restart_watchdogs","Перезапустить watchdog-и")}</div>',"⬡")))
    if p=="/core":
        return self.send(page("Xray core","/core",'<div class="head"><h1>Обновление Xray core</h1><p>Обновление latest или test/pre-release из GitHub</p></div>'+card("Xray core",f'<div class="grid">{action("xray_version","Версия Xray")}{action("update_core_latest_backup","Latest GitHub + backup","green")}{action("update_core_latest_nobackup","Latest GitHub без backup")}{action("update_core_test_backup","Test/pre-release + backup","yellow")}{action("update_core_test_nobackup","Test/pre-release без backup","red")}{action("backup","Backup конфигурации")}</div><br><div class="notice">Обновление ядра может занять несколько минут.</div>',"⬢")))
    if p=="/logs":
        return self.send(page("Логи","/logs",'<div class="head"><h1>Логи</h1><p>Просмотр журналов</p></div>'+card("Журналы",f'<div class="grid">{action("logs_failover","Failover log")}{action("logs_events","События")}{action("logs_watchdog","Xray Watchdog")}{action("logs_proxy0_watchdog","Proxy0 Watchdog")}{action("logs_core_update","Core update")}{action("logs_xray_main","Xray_main")}</div>',"☷")))
    if p=="/settings":
        return self.send(page("Настройки","/settings",'<div class="head"><h1>Настройки</h1><p>Параметры WebUI</p></div>'+card("Настройки WebUI",f'<div class="details"><div><div class="label">Адрес</div><div>http://{esc(HOST)}:{PORT}</div></div><div><div class="label">Пользователь</div><div>{esc(USER)}</div></div><div><div class="label">Файл авторизации</div><div>{esc(AUTH)}</div></div></div><br><div class="notice">Сменить пароль: xray_webui_password</div>',"⚙")))
    self.send_error(404)
def do_POST(self):
    if not self.auth_ok(): return self.need_auth()
    p=urllib.parse.urlparse(self.path).path; d=self.postdata()
    if p=="/action":
        a=d.get("action",[""])[0]
        if a not in A: return self.send(page("Ошибка","/",card("Ошибка","Неизвестное действие","⚠")))
        title,cmd,timeout=A[a]; rc,out=run(cmd,timeout=timeout)
        return self.send(page(title,"/",'<div class="head"><h1>Результат команды</h1><p>Выполнено действие из WebUI</p></div>'+card(title,f'<div class="details"><div><div class="label">Действие</div><div>{esc(a)}</div></div><div><div class="label">Код возврата</div><div>{rc}</div></div><div><div class="label">Команда</div><div>{esc(cmd)}</div></div></div><br><a class="btn" href="/">Назад</a>',"☷"),out))
    if p=="/update_failover":
        rc,out=update_failover(d.get("primary",[""])[0],d.get("backup",[""])[0])
        return self.send(page("Обновление Failover","/failover",card("Обновление Failover",f'Код возврата: {rc}<br><br><a class="btn" href="/failover">Назад</a>',"◎"),out))
    if p=="/update_main":
        rc,out=update_main(d.get("main",[""])[0])
        return self.send(page("Обновление Xray_main","/main",card("Обновление Xray_main",f'Код возврата: {rc}<br><br><a class="btn" href="/main">Назад</a>',"◇"),out))
    self.send_error(404)

ThreadingHTTPServer((HOST,PORT),H).serve_forever()
PY
chmod +x "$WEBUI_APP"

cat > "$WEBUI_INIT" <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
DESC="Xray WebUI"
PYTHON_BIN="/opt/bin/python3"
DAEMON="/opt/libexec/xray-webui.py"
PIDFILE="/opt/var/run/xray-webui.pid"
LOGFILE="/opt/var/log/xray-webui.log"
mkdir -p /opt/var/run /opt/var/log
[ -x "$PYTHON_BIN" ] || PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
is_running(){ [ -f "$PIDFILE" ] || return 1; PID="$(cat "$PIDFILE" 2>/dev/null)"; [ -n "$PID" ] || return 1; kill -0 "$PID" 2>/dev/null; }
start(){ printf " Запускаем %s... " "$DESC"; if is_running; then echo "уже запущен."; exit 0; fi; [ -n "$PYTHON_BIN" ] && [ -x "$PYTHON_BIN" ] || { echo "ошибка."; echo "python3 не найден"; exit 1; }; [ -f "$DAEMON" ] || { echo "ошибка."; echo "WebUI app не найден: $DAEMON"; exit 1; }; "$PYTHON_BIN" "$DAEMON" >> "$LOGFILE" 2>&1 & echo "$!" > "$PIDFILE"; sleep 2; if is_running; then echo "готово."; exit 0; fi; echo "ошибка."; tail -n 80 "$LOGFILE" 2>/dev/null || true; rm -f "$PIDFILE"; exit 1; }
stop(){ printf " Останавливаем %s... " "$DESC"; if ! is_running; then echo "не запущен."; rm -f "$PIDFILE"; exit 0; fi; PID="$(cat "$PIDFILE" 2>/dev/null)"; kill "$PID" 2>/dev/null || true; sleep 2; kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true; rm -f "$PIDFILE"; echo "готово."; }
status(){ printf " Проверяем %s... " "$DESC"; if is_running; then echo "работает. PID: $(cat "$PIDFILE")"; exit 0; fi; echo "не запущен."; exit 1; }
restart(){ "$0" stop; sleep 1; "$0" start; }
case "${1:-}" in start) start;; stop) stop;; restart) restart;; status) status;; *) echo "Использование: $0 {start|stop|restart|status}"; exit 1;; esac
EOF
chmod +x "$WEBUI_INIT"

cat > /opt/bin/xray_webui_status <<'EOF'
#!/bin/sh
echo "Xray WebUI:"
/opt/etc/init.d/S29xray-webui status 2>&1 || true
echo
echo "Auth:"
cat /opt/etc/xray-webui/auth.env 2>/dev/null || true
echo
echo "Port:"
netstat -lntp 2>/dev/null | grep 8090 || true
echo
echo "Recent log:"
tail -n 40 /opt/var/log/xray-webui.log 2>/dev/null || true
EOF
chmod +x /opt/bin/xray_webui_status

cat > /opt/bin/xray_webui_log <<'EOF'
#!/bin/sh
mkdir -p /opt/var/log
touch /opt/var/log/xray-webui.log
tail -f /opt/var/log/xray-webui.log
EOF
chmod +x /opt/bin/xray_webui_log

cat > /opt/bin/xray_webui_password <<'EOF'
#!/bin/sh
AUTH="/opt/etc/xray-webui/auth.env"
[ -f "$AUTH" ] || { echo "Auth file not found: $AUTH"; exit 1; }
printf "New WebUI password: "
read PASS
[ -z "$PASS" ] && { echo "Password is empty"; exit 1; }
USER="$(grep '^WEBUI_USER=' "$AUTH" | cut -d= -f2- | tr -d '"')"
HOST="$(grep '^WEBUI_HOST=' "$AUTH" | cut -d= -f2- | tr -d '"')"
PORT="$(grep '^WEBUI_PORT=' "$AUTH" | cut -d= -f2- | tr -d '"')"
[ -z "$USER" ] && USER="admin"
[ -z "$HOST" ] && HOST="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 192.168.1.1)"
[ -z "$PORT" ] && PORT="8090"
cat > "$AUTH" <<EOF2
WEBUI_HOST="$HOST"
WEBUI_PORT="$PORT"
WEBUI_USER="$USER"
WEBUI_PASS="$PASS"
EOF2
chmod 600 "$AUTH"
/opt/etc/init.d/S29xray-webui restart
echo "Password updated."
EOF
chmod +x /opt/bin/xray_webui_password

python3 -m py_compile "$WEBUI_APP"
"$WEBUI_INIT" restart

echo "WebUI installed."
[ -f /opt/etc/xray-webui/auth.env ] && cat /opt/etc/xray-webui/auth.env || true
WEBUIINSTALL
    chmod +x /opt/bin/xray_webui_install

    cat > /opt/bin/xray_webui_remove <<'EOF'
#!/bin/sh
set -e
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH

/opt/etc/init.d/S29xray-webui stop >/dev/null 2>&1 || true
rm -f /opt/etc/init.d/S29xray-webui
rm -f /opt/libexec/xray-webui.py
rm -f /opt/bin/xray_webui_status /opt/bin/xray_webui_log /opt/bin/xray_webui_password
rm -rf /opt/etc/xray-webui
rm -f /opt/var/run/xray-webui.pid

echo "WebUI удалён."
EOF
    chmod +x /opt/bin/xray_webui_remove
}


create_menu() {
    cat > /opt/bin/failover <<'EOF'
#!/bin/sh
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/sbin:/bin:/usr/sbin:/usr/bin
export PATH
pause(){ echo; printf "Нажмите Enter для возврата..."; read _; }
clear_screen(){ clear 2>/dev/null || true; }
active_profile(){ cat /opt/etc/xray/active-profile 2>/dev/null || echo unknown; }
router_ip(){ cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 127.0.0.1; }
header(){ clear_screen; echo "======================================"; echo " Xray VLESS Control Menu"; echo "======================================"; echo; echo "Активный failover профиль: $(active_profile)"; echo "Router LAN IP: $(router_ip)"; echo; }
status_menu(){ while true; do header; echo "Статус / диагностика"; echo "--------------------------------------"; echo "1) Краткий статус failover"; echo "2) Общий статус всех Xray / Proxy"; echo "3) Doctor"; echo "4) Post-update test"; echo "5) Версия Xray core"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; vless-failover-status; pause;; 2) clear_screen; xray_all_status; pause;; 3) clear_screen; xray_failover_doctor; pause;; 4) clear_screen; xray_post_update_test; pause;; 5) clear_screen; xray_core_version; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
failover_menu(){ while true; do header; echo "Failover Primary / Backup"; echo "--------------------------------------"; echo "1) Обновить Primary / Backup VLESS-ссылки"; echo "2) Переключить вручную на Primary"; echo "3) Переключить вручную на Backup"; echo "4) Перезапустить failover-сервис"; echo "5) Перезапустить Xray failover core"; echo "6) Проверить SOCKS5"; echo "7) Показать ссылки"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_vless_update; pause;; 2) clear_screen; xray_switch primary; pause;; 3) clear_screen; xray_switch backup; pause;; 4) clear_screen; /opt/etc/init.d/S25xray-failover restart; pause;; 5) clear_screen; /opt/etc/init.d/S24xray restart; pause;; 6) clear_screen; IP="$(router_ip)"; curl -k -sS --socks5-hostname "$IP:10808" --connect-timeout 10 --max-time 20 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n' https://www.gstatic.com/generate_204 2>&1 || true; pause;; 7) clear_screen; echo "Primary:"; cat /opt/etc/xray/vless-primary.url 2>/dev/null; echo; echo "Backup:"; cat /opt/etc/xray/vless-backup.url 2>/dev/null || echo "not configured"; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
xray_main_menu(){ while true; do header; echo "Xray_main / Proxy1"; echo "--------------------------------------"; echo "1) Статус"; echo "2) Обновить VLESS"; echo "3) Перезапустить"; echo "4) Починить Proxy1"; echo "5) Живой лог"; echo "6) Показать ссылку"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_main_status; pause;; 2) clear_screen; xray_main_update; pause;; 3) clear_screen; /opt/etc/init.d/S23xray-main restart; sleep 5; xray_main_proxy1_repair; pause;; 4) clear_screen; xray_main_proxy1_repair; pause;; 5) clear_screen; xray_main_log;; 6) clear_screen; cat /opt/etc/xray-main/vless-main.url 2>/dev/null || echo "not configured"; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
watchdog_menu(){ while true; do header; echo "Watchdog-и"; echo "--------------------------------------"; echo "1) Статус Xray Watchdog"; echo "2) Лог Xray Watchdog"; echo "3) Статус Proxy0 Watchdog"; echo "4) Лог Proxy0 Watchdog"; echo "5) Перезапустить оба"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_watchdog_status; pause;; 2) clear_screen; xray_watchdog_log;; 3) clear_screen; xray_proxy0_watchdog_status; pause;; 4) clear_screen; xray_proxy0_watchdog_log;; 5) clear_screen; /opt/etc/init.d/S27xray-watchdog restart; /opt/etc/init.d/S28xray-proxy0-watchdog restart; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
core_update_menu(){ while true; do header; echo "Обновление Xray core"; echo "--------------------------------------"; echo "1) Версия"; echo "2) Обновить latest из GitHub"; echo "3) Обновить test/pre-release из GitHub"; echo "4) Лог обновления"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_core_version; pause;; 2) clear_screen; xray_core_update_latest; pause;; 3) clear_screen; xray_core_update_test; pause;; 4) clear_screen; xray_core_update_log;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
backup_menu(){ while true; do header; echo "Backup / Restore / Rollback"; echo "--------------------------------------"; echo "1) Backup конфигурации"; echo "2) Restore конфигурации"; echo "3) Rollback Xray core"; echo "4) Показать backup конфигурации"; echo "5) Показать backup Xray core"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_failover_backup; pause;; 2) clear_screen; xray_failover_restore; pause;; 3) clear_screen; xray_core_rollback; pause;; 4) clear_screen; ls -lh /opt/backup/xray-failover/*.tar.gz 2>/dev/null || echo "Нет backup-файлов"; pause;; 5) clear_screen; ls -lh /opt/backup/xray-core/xray.*.bak 2>/dev/null || echo "Нет backup-файлов"; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
logs_menu(){ while true; do header; echo "Логи"; echo "--------------------------------------"; echo "1) failover log"; echo "2) события"; echo "3) события live"; echo "4) watchdog log"; echo "5) proxy0 watchdog log"; echo "6) core update log"; echo "7) Xray_main log"; echo "8) поиск"; echo "9) очистить"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_failover_log;; 2) clear_screen; xray_failover_events; pause;; 3) clear_screen; xray_failover_events -f;; 4) clear_screen; xray_watchdog_log;; 5) clear_screen; xray_proxy0_watchdog_log;; 6) clear_screen; xray_core_update_log;; 7) clear_screen; xray_main_log;; 8) clear_screen; printf "Строка поиска: "; read p; xray_logs grep "$p"; pause;; 9) clear_screen; : > /opt/var/log/xray-vless-failover.log; : > /opt/var/log/xray-vless-events.log; : > /opt/var/log/xray-watchdog.log; : > /opt/var/log/xray-proxy0-watchdog.log; : > /opt/var/log/xray-core-update.log; : > /opt/var/log/xray-main.log; echo "Логи очищены."; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
proxy_menu(){ while true; do header; echo "Proxy repair"; echo "--------------------------------------"; echo "1) Починить Proxy0"; echo "2) Починить Proxy1"; echo "3) running-config Proxy0"; echo "4) running-config Proxy1"; echo "5) Починить оба"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_proxy0_repair; pause;; 2) clear_screen; xray_main_proxy1_repair; pause;; 3) clear_screen; ndmc -c "show running-config" 2>/dev/null | grep -A20 -i "interface Proxy0" || echo "Proxy0 не найден"; pause;; 4) clear_screen; ndmc -c "show running-config" 2>/dev/null | grep -A20 -i "interface Proxy1" || echo "Proxy1 не найден"; pause;; 5) clear_screen; xray_proxy0_repair || true; xray_main_proxy1_repair || true; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
webui_menu(){ while true; do header; echo "WebUI"; echo "--------------------------------------"; echo "1) Установить WebUI"; echo "2) Удалить WebUI"; echo "3) Статус WebUI"; echo "4) Лог WebUI"; echo "5) Сменить пароль WebUI"; echo "0) Назад"; echo; printf "Введите номер: "; read c; case "$c" in 1) clear_screen; xray_webui_install; pause;; 2) clear_screen; printf "Удалить WebUI? Введите 1 для подтверждения: "; read y; if [ "$y" = "1" ]; then xray_webui_remove; else echo "Отменено."; fi; pause;; 3) clear_screen; if command -v xray_webui_status >/dev/null 2>&1; then xray_webui_status; else echo "WebUI не установлен."; fi; pause;; 4) clear_screen; if command -v xray_webui_log >/dev/null 2>&1; then xray_webui_log; else echo "WebUI не установлен."; pause; fi;; 5) clear_screen; if command -v xray_webui_password >/dev/null 2>&1; then xray_webui_password; else echo "WebUI не установлен."; fi; pause;; 0) return;; *) echo "Неверный пункт"; pause;; esac; done; }
while true; do header; echo "Главное меню"; echo "--------------------------------------"; echo "1) Статус / диагностика"; echo "2) Failover Primary / Backup"; echo "3) Xray_main / Proxy1"; echo "4) Watchdog-и"; echo "5) Обновление Xray core"; echo "6) Backup / Restore / Rollback"; echo "7) Логи"; echo "8) Proxy repair"; echo "9) WebUI"; echo "0) Выход"; echo; printf "Введите номер: "; read c; case "$c" in 1) status_menu;; 2) failover_menu;; 3) xray_main_menu;; 4) watchdog_menu;; 5) core_update_menu;; 6) backup_menu;; 7) logs_menu;; 8) proxy_menu;; 9) webui_menu;; 0) echo "Выход."; exit 0;; *) echo "Неверный пункт."; pause;; esac; done
EOF
    chmod +x /opt/bin/failover
}

initial_configs_and_start() {
    XRAY_BIN="$(get_xray_bin)"
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"

    active="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    if [ "$active" = "backup" ] && [ -s "$BACKUP_STORE" ]; then
        url="$(cat "$BACKUP_STORE")"; profile="backup"
    else
        url="$(cat "$PRIMARY_STORE")"; profile="primary"; echo primary > "$ACTIVE_STORE"
    fi

    generate_config "$profile" "$url" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$XRAY_CONFIG"
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG"

    if [ "$INSTALL_XRAY_MAIN" = "yes" ] && [ -s "$XRAY_MAIN_URL_STORE" ]; then
        generate_config "Xray_main" "$(cat "$XRAY_MAIN_URL_STORE")" "$ROUTER_LAN_IP" "$MAIN_PORT" "$XRAY_MAIN_CONFIG"
        "$XRAY_BIN" run -test -config "$XRAY_MAIN_CONFIG"
    fi

    "$INIT_XRAY" restart
    sleep 5
    /opt/bin/xray_proxy0_repair || true

    if [ "$INSTALL_XRAY_MAIN" = "yes" ] && [ -s "$XRAY_MAIN_URL_STORE" ]; then
        "$INIT_XRAY_MAIN" restart
        sleep 5
        /opt/bin/xray_main_proxy1_repair || true
    fi

    "$INIT_FAILOVER" restart
    "$INIT_XRAY_WATCHDOG" restart
    "$INIT_PROXY0_WATCHDOG" restart
}

echo
echo "======================================"
echo " $APP_NAME"
echo " Version: $VERSION"
echo "======================================"
echo

echo "[1/13] Stop old services"
stop_old_services

echo "[2/13] Ensure packages"
ensure_packages

echo "[3/13] Prepare router IP and links"
prepare_links

echo "[4/13] Create generator"
create_generator

echo "[5/13] Create init scripts"
create_init_scripts

echo "[6/13] Create proxy repair commands"
create_proxy_repair_commands

echo "[7/13] Create failover daemon"
create_failover_daemon

echo "[8/13] Create watchdogs"
create_watchdogs

echo "[9/13] Create Xray_main commands"
create_xray_main_commands

echo "[10/13] Create update/switch/status commands"
create_update_switch_status_commands
create_core_update_commands
create_status_log_maintenance_commands
create_maintenance_tools

echo "[11/13] Create optional WebUI"
create_webui
create_webui_manage_commands

echo "[12/13] Create menu"
create_menu

echo "[13/13] Generate configs and start services"
initial_configs_and_start

echo
echo "======================================"
echo " ГОТОВО"
echo "======================================"
echo
echo "SOCKS failover: $(cat "$ROUTER_IP_STORE"):$SOCKS_PORT"
if [ "$INSTALL_XRAY_MAIN" = "yes" ] && [ -s "$XRAY_MAIN_URL_STORE" ]; then
    echo "SOCKS Xray_main: $(cat "$XRAY_MAIN_ROUTER_IP_STORE"):$MAIN_PORT"
fi
echo
if [ "$INSTALL_WEBUI" = "yes" ]; then
    echo "WebUI: http://$(cat "$ROUTER_IP_STORE"):8090"
    echo "WebUI auth:"
    cat /opt/etc/xray-webui/auth.env 2>/dev/null || true
    echo
fi

echo "Команды:"
echo "  failover"
echo "  vless-failover-status"
echo "  xray_vless_update"
echo "  xray_core_version"
echo "  xray_core_update_latest"
echo "  xray_core_update_test"
echo "  xray_failover_backup"
if [ "$INSTALL_WEBUI" = "yes" ]; then
    echo "  xray_webui_status"
    echo "  xray_webui_password"
fi
echo
