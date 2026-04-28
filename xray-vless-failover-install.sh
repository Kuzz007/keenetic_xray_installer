#!/bin/sh

set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"

GENERATOR="/opt/bin/xray-vless-generate-config"
FAILOVER_DAEMON="/opt/bin/xray-vless-failover-daemon"
FAILOVER_STATUS="/opt/bin/vless-failover-status"
FAILOVER_UPDATE_CMD="/opt/bin/vless-failover-update"
FAILOVER_UPDATE_ALIAS="/opt/bin/xray-failover-update"

FAILOVER_INSTALLER_UPDATE_CMD="/opt/bin/xray-failover-installer-update"
FAILOVER_INSTALLER_UPDATE_ALIAS="/opt/bin/failover-installer-update"
REPO_FAILOVER_RAW_URL="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-vless-failover-install.sh"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"
GLOBAL_PRIORITY="16375"

CHECK_INTERVAL="10"
CHECK_URL="https://www.gstatic.com/generate_204"

TMP_DIR="/opt/tmp"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"

REUSE_FAILOVER="0"

case "${1:-}" in
    --reuse-failover)
        REUSE_FAILOVER="1"
        ;;
esac

echo
echo "======================================"
echo " Установщик Xray VLESS Failover"
echo " Прямой запуск в Entware, без GitHub"
echo "======================================"
echo
echo "Что будет сделано:"
echo "- установка недостающих пакетов: curl, ca-bundle, python3, xray/xray-core"
echo "- запрос Primary VLESS-ссылки"
echo "- запрос Backup VLESS-ссылки, можно пропустить Enter"
echo "- создание /opt/etc/xray/config.json"
echo "- создание сервиса Xray: /opt/etc/init.d/S24xray"
echo "- создание failover-сервиса: /opt/etc/init.d/S25xray-failover"
echo "- настройка Proxy0 в Keenetic"
echo "- создание команд: vless-failover-update, failover-installer-update, vless-failover-status"
echo
echo "Интервал проверки failover: $CHECK_INTERVAL секунд"
echo

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

ensure_packages() {
    echo
    echo "[1/10] Проверяем Entware и необходимые пакеты..."

    if ! command -v opkg >/dev/null 2>&1; then
        echo "ОШИБКА: команда opkg не найдена. Entware недоступен."
        exit 1
    fi

    NEED_UPDATE="0"

    if ! command -v curl >/dev/null 2>&1; then
        NEED_UPDATE="1"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        NEED_UPDATE="1"
    fi

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        NEED_UPDATE="1"
    fi

    if [ "$NEED_UPDATE" = "1" ]; then
        echo "Обновляем список пакетов Entware..."
        opkg update
    else
        echo "Основные зависимости уже установлены."
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Устанавливаем curl и ca-bundle..."
        opkg install curl ca-bundle
    else
        echo "curl найден."
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Устанавливаем python3..."
        opkg install python3
    else
        echo "python3 найден."
    fi

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        echo "Устанавливаем xray / xray-core..."
        if opkg install xray xray-core; then
            echo "Установлены xray + xray-core."
        elif opkg install xray-core; then
            echo "Установлен xray-core."
        else
            echo "ОШИБКА: не удалось установить xray/xray-core."
            exit 1
        fi
    else
        echo "xray найден."
    fi
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

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

create_generator() {
    echo
    echo "[4/10] Создаём общий генератор Xray config..."
    echo "Файл: $GENERATOR"

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
            "listen": listen_host,
            "port": listen_port,
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
            "tag": profile_name,
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

create_xray_init() {
    echo
    echo "[5/10] Создаём init-скрипт Xray..."
    echo "Файл: $INIT_SCRIPT"

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
}

configure_proxy0() {
    echo
    echo "[7/10] Настраиваем Proxy0 в Keenetic..."

    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Proxy0 нужно настроить вручную."
        return 0
    fi

    ndmc -c "interface $PROXY_IFACE" \
        && ndmc -c "interface $PROXY_IFACE proxy protocol socks5" \
        && ndmc -c "interface $PROXY_IFACE proxy socks5-udp" \
        && ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" \
        && ndmc -c "interface $PROXY_IFACE description Xray-Failover" \
        && ndmc -c "interface $PROXY_IFACE ip global $GLOBAL_PRIORITY" \
        && ndmc -c "interface $PROXY_IFACE up" \
        && ndmc -c "system configuration save"

    echo "Proxy0 настроен:"
    echo "$PROXY_IFACE -> SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT"
}

create_failover_daemon() {
    echo
    echo "[6/10] Создаём failover-daemon..."
    echo "Файл: $FAILOVER_DAEMON"

    cat > "$FAILOVER_DAEMON" <<'DAEMON'
#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"

GENERATOR="/opt/bin/xray-vless-generate-config"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"

CHECK_INTERVAL="10"
CHECK_URL="https://www.gstatic.com/generate_204"

TMP_DIR="/opt/tmp"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

XRAY_BIN="$(get_xray_bin)"

if [ -z "$XRAY_BIN" ]; then
    echo "ОШИБКА: xray не найден."
    exit 1
fi

if [ ! -x "$GENERATOR" ]; then
    echo "ОШИБКА: генератор не найден: $GENERATOR"
    exit 1
fi

if [ ! -s "$ROUTER_IP_STORE" ]; then
    echo "ОШИБКА: файл LAN-IP роутера не найден: $ROUTER_IP_STORE"
    exit 1
fi

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"

test_socks_endpoint() {
    HOST="$1"
    PORT="$2"

    RESULT="$(curl -k -sS \
        --socks5-hostname "$HOST:$PORT" \
        --connect-timeout 5 \
        --max-time 10 \
        -o /dev/null \
        -w 'http_code=%{http_code} time_total=%{time_total}' \
        "$CHECK_URL" 2>&1)" && STATUS="0" || STATUS="$?"

    echo "$RESULT"

    if [ "$STATUS" = "0" ]; then
        return 0
    fi

    return 1
}

wait_for_socks_port() {
    PORT_UP="0"
    i=1

    while [ "$i" -le 10 ]; do
        if netstat -lnt 2>/dev/null | grep -q "$ROUTER_LAN_IP:$SOCKS_PORT"; then
            PORT_UP="1"
            break
        fi

        if netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT"; then
            PORT_UP="1"
            break
        fi

        sleep 1
        i=$((i + 1))
    done

    [ "$PORT_UP" = "1" ]
}

restart_proxy0() {
    if command -v ndmc >/dev/null 2>&1; then
        echo "Перезапускаем Proxy0..."
        ndmc -c "interface $PROXY_IFACE down" || true
        sleep 2
        ndmc -c "interface $PROXY_IFACE up" || true
        ndmc -c "system configuration save" || true
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден, Proxy0 не перезапущен."
    fi
}

generate_profile_config() {
    PROFILE="$1"
    URL="$2"
    HOST="$3"
    PORT="$4"
    OUT="$5"

    PROFILE_NAME="$PROFILE" \
    VLESS_URL="$URL" \
    LISTEN_HOST="$HOST" \
    LISTEN_PORT="$PORT" \
    OUTPUT_CONFIG="$OUT" \
    "$GENERATOR"
}

test_vless_temp() {
    PROFILE="$1"
    URL="$2"
    PORT="$3"

    TMP_CONFIG="$TMP_DIR/xray-failover-test-$PROFILE.json"
    TMP_LOG="$TMP_DIR/xray-failover-test-$PROFILE.log"

    echo "Проверяем неактивный профиль через временный SOCKS5: $PROFILE"

    generate_profile_config "$PROFILE" "$URL" "$TEMP_HOST" "$PORT" "$TMP_CONFIG" >/dev/null

    "$XRAY_BIN" run -test -config "$TMP_CONFIG" >/dev/null

    "$XRAY_BIN" run -config "$TMP_CONFIG" > "$TMP_LOG" 2>&1 &
    TMP_PID="$!"

    sleep 3

    if ! kill -0 "$TMP_PID" 2>/dev/null; then
        echo "Временный Xray не запустился для профиля $PROFILE."
        cat "$TMP_LOG"
        return 1
    fi

    if test_socks_endpoint "$TEMP_HOST" "$PORT"; then
        kill "$TMP_PID" 2>/dev/null || true
        wait "$TMP_PID" 2>/dev/null || true
        return 0
    fi

    kill "$TMP_PID" 2>/dev/null || true
    wait "$TMP_PID" 2>/dev/null || true
    return 1
}

switch_to_profile() {
    TARGET="$1"

    if [ "$TARGET" = "primary" ]; then
        URL="$(cat "$PRIMARY_STORE")"
    elif [ "$TARGET" = "backup" ]; then
        URL="$(cat "$BACKUP_STORE")"
    else
        echo "ОШИБКА: неизвестный профиль: $TARGET"
        return 1
    fi

    echo
    echo "======================================"
    echo " ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET"
    echo "======================================"

    echo "[1/5] Генерируем config.json для профиля: $TARGET"
    generate_profile_config "$TARGET" "$URL" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$XRAY_CONFIG"

    echo "[2/5] Проверяем Xray config..."
    "$XRAY_BIN" run -test -config "$XRAY_CONFIG"

    echo "[3/5] Перезапускаем Xray..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 2
    "$INIT_SCRIPT" start

    echo "Ждём появления SOCKS5-порта $ROUTER_LAN_IP:$SOCKS_PORT..."
    if ! wait_for_socks_port; then
        echo "ОШИБКА: после переключения SOCKS5-порт не поднялся."
        return 1
    fi

    echo "[4/5] Проверяем основной SOCKS5 endpoint..."
    if ! test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
        echo "ОШИБКА: основной SOCKS5 endpoint не прошёл проверку."
        return 1
    fi

    echo "[5/5] Перезапускаем Proxy0..."
    restart_proxy0

    echo "$TARGET" > "$ACTIVE_STORE"

    echo "Пауза 5 секунд после переключения..."
    sleep 5

    echo "Активный профиль теперь: $TARGET"
}

mkdir -p "$TMP_DIR"

while true; do
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"

    echo
    echo "[$NOW] Активный профиль: $ACTIVE"

    if [ "$ACTIVE" = "primary" ]; then
        echo "Проверяем active primary через $ROUTER_LAN_IP:$SOCKS_PORT..."

        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
            echo "Primary OK."
        else
            echo "Primary НЕ ДОСТУПЕН."

            if [ -s "$BACKUP_STORE" ]; then
                echo "Проверяем backup перед переключением..."

                if test_vless_temp "backup" "$(cat "$BACKUP_STORE")" "$TEMP_BACKUP_PORT"; then
                    switch_to_profile "backup" || echo "Переключение на backup не удалось."
                else
                    echo "Backup тоже недоступен. Остаёмся на primary config."
                fi
            else
                echo "Backup-ссылка не настроена."
            fi
        fi

    elif [ "$ACTIVE" = "backup" ]; then
        echo "Проверяем active backup через $ROUTER_LAN_IP:$SOCKS_PORT..."

        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
            echo "Backup OK."
        else
            echo "Backup НЕ ДОСТУПЕН."
        fi

        echo "Проверяем, вернулся ли primary..."

        if test_vless_temp "primary" "$(cat "$PRIMARY_STORE")" "$TEMP_PRIMARY_PORT"; then
            echo "Primary снова доступен."
            switch_to_profile "primary" || echo "Переключение на primary не удалось."
        else
            echo "Primary всё ещё недоступен. Остаёмся на backup."
        fi

    else
        echo "Неизвестный active-profile. Пробуем вернуться на primary."
        switch_to_profile "primary" || echo "Переключение на primary не удалось."
    fi

    sleep "$CHECK_INTERVAL"
done
DAEMON

    chmod +x "$FAILOVER_DAEMON"
}

create_failover_init() {
    echo
    echo "[8/10] Создаём init-скрипт failover без nohup и без rc.func..."
    echo "Файл: $FAILOVER_INIT"

    cat > "$FAILOVER_INIT" <<INIT
#!/bin/sh

ENABLED=yes
DESC="Xray VLESS Failover"
DAEMON="$FAILOVER_DAEMON"
PIDFILE="/opt/var/run/xray-vless-failover.pid"
LOGFILE="/opt/var/log/xray-vless-failover.log"

mkdir -p /opt/var/run /opt/var/log

is_running() {
    [ -f "\$PIDFILE" ] || return 1
    PID="\$(cat "\$PIDFILE" 2>/dev/null)"
    [ -n "\$PID" ] || return 1
    kill -0 "\$PID" 2>/dev/null
}

start() {
    printf " Запускаем %s... " "\$DESC"

    if is_running; then
        echo "уже запущен."
        exit 0
    fi

    if [ ! -x "\$DAEMON" ]; then
        echo "ошибка."
        echo "Daemon не найден или не исполняемый: \$DAEMON"
        exit 1
    fi

    "\$DAEMON" >> "\$LOGFILE" 2>&1 &
    echo "\$!" > "\$PIDFILE"

    sleep 2

    if is_running; then
        echo "готово."
        exit 0
    else
        echo "ошибка."
        echo "Последние строки лога:"
        tail -n 30 "\$LOGFILE" 2>/dev/null
        rm -f "\$PIDFILE"
        exit 1
    fi
}

stop() {
    printf " Останавливаем %s... " "\$DESC"

    if ! is_running; then
        echo "не запущен."
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
    echo "готово."
}

status() {
    printf " Проверяем %s... " "\$DESC"

    if is_running; then
        PID="\$(cat "\$PIDFILE")"
        echo "работает. PID: \$PID"
        exit 0
    else
        echo "не запущен."
        exit 1
    fi
}

restart() {
    "\$0" stop
    sleep 1
    "\$0" start
}

case "\$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        restart
        ;;
    status)
        status
        ;;
    *)
        echo "Использование: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
INIT

    chmod +x "$FAILOVER_INIT"
}

create_status_command() {
    echo
    echo "Создаём команду статуса:"
    echo "$FAILOVER_STATUS"

    cat > "$FAILOVER_STATUS" <<'STATUS'
#!/bin/sh

echo "Активный профиль:"
cat /opt/etc/xray/active-profile 2>/dev/null || echo "unknown"

echo
echo "Статус Xray:"
/opt/etc/init.d/S24xray status

echo
echo "Статус failover:"
/opt/etc/init.d/S25xray-failover status

echo
echo "SOCKS5 port:"
netstat -lntp 2>/dev/null | grep 10808 || true

echo
echo "Proxy0:"
ndmc -c "show running-config" 2>/dev/null | grep -A12 -i "interface Proxy0" || true

echo
echo "Последние строки failover-лога:"
tail -n 20 /opt/var/log/xray-vless-failover.log 2>/dev/null || true
STATUS

    chmod +x "$FAILOVER_STATUS"
}

create_failover_update_command() {
    echo
    echo "[9/10] Создаём команду обновления Primary/Backup ссылок без переустановки..."
    echo "Файл: $FAILOVER_UPDATE_CMD"

    cat > "$FAILOVER_UPDATE_CMD" <<'VUPDATE'
#!/bin/sh

set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"

GENERATOR="/opt/bin/xray-vless-generate-config"

INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"

SOCKS_PORT="10808"

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

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

XRAY_BIN="$(get_xray_bin)"

if [ -z "$XRAY_BIN" ]; then
    echo "ОШИБКА: xray не найден."
    exit 1
fi

if [ ! -x "$GENERATOR" ]; then
    echo "ОШИБКА: генератор не найден:"
    echo "$GENERATOR"
    exit 1
fi

if [ ! -s "$ROUTER_IP_STORE" ]; then
    echo "ОШИБКА: файл LAN-IP роутера не найден:"
    echo "$ROUTER_IP_STORE"
    exit 1
fi

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"

echo
echo "======================================"
echo " Обновление VLESS-ссылок failover"
echo "======================================"
echo
echo "LAN-IP роутера:"
echo "$ROUTER_LAN_IP"
echo
echo "Текущие файлы:"
echo "Primary: $PRIMARY_STORE"
echo "Backup:  $BACKUP_STORE"
echo

read_tty "New Primary VLESS link: " PRIMARY_VLESS

if [ -z "$PRIMARY_VLESS" ]; then
    echo "ОШИБКА: Primary VLESS-ссылка пустая."
    exit 1
fi

echo
echo "Backup VLESS link опциональна."
echo "Если резервная ссылка не нужна — нажмите Enter."
read_tty "New Backup VLESS link, optional. Press Enter to skip: " BACKUP_VLESS

mkdir -p "$XRAY_DIR"

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
    echo "Backup VLESS сохранён."
else
    rm -f "$BACKUP_STORE"
    echo "Backup VLESS удалён/пропущен."
fi

echo
echo "Пересоздаём config.json для primary..."

PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$XRAY_CONFIG" \
"$GENERATOR"

echo
echo "Проверяем Xray config..."
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"

echo "primary" > "$ACTIVE_STORE"

echo
echo "Перезапускаем Xray..."
"$INIT_SCRIPT" restart

echo
echo "Перезапускаем failover-сервис..."
if [ -x "$FAILOVER_INIT" ]; then
    "$FAILOVER_INIT" restart
else
    echo "ПРЕДУПРЕЖДЕНИЕ: failover init-скрипт не найден:"
    echo "$FAILOVER_INIT"
fi

echo
echo "Готово."
echo "Primary VLESS обновлён: $PRIMARY_STORE"
if [ -s "$BACKUP_STORE" ]; then
    echo "Backup VLESS обновлён: $BACKUP_STORE"
else
    echo "Backup VLESS не задан."
fi
echo "Активный профиль сброшен на primary."
VUPDATE

    chmod +x "$FAILOVER_UPDATE_CMD"
    ln -sf "$FAILOVER_UPDATE_CMD" "$FAILOVER_UPDATE_ALIAS"

    echo "Команды созданы:"
    echo "$FAILOVER_UPDATE_CMD"
    echo "$FAILOVER_UPDATE_ALIAS"
}

create_failover_installer_update_command() {
    echo
    echo "[10/10] Создаём команду обновления failover-установщика из GitHub..."
    echo "Файл: $FAILOVER_INSTALLER_UPDATE_CMD"

    cat > "$FAILOVER_INSTALLER_UPDATE_CMD" <<UPDATER
#!/bin/sh

set -e

REPO_FAILOVER_RAW_URL="$REPO_FAILOVER_RAW_URL"
TMP_INSTALLER="/opt/tmp/xray-vless-failover-install.sh"
PRIMARY_STORE="$PRIMARY_STORE"

echo
echo "======================================"
echo " Обновление Xray VLESS Failover Installer"
echo "======================================"
echo
echo "Репозиторий:"
echo "\$REPO_FAILOVER_RAW_URL"
echo

if ! command -v opkg >/dev/null 2>&1; then
    echo "ОШИБКА: opkg не найден. Entware недоступен."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl не найден. Устанавливаем curl и ca-bundle..."
    opkg update
    opkg install curl ca-bundle
fi

if [ ! -s "\$PRIMARY_STORE" ]; then
    echo "ОШИБКА: сохранённая Primary VLESS-ссылка не найдена:"
    echo "\$PRIMARY_STORE"
    echo
    echo "Сначала запустите failover-установщик вручную или выполните:"
    echo "vless-failover-update"
    exit 1
fi

mkdir -p /opt/tmp

echo "Скачиваем свежий failover-установщик..."
curl -fsSL -o "\$TMP_INSTALLER" "\$REPO_FAILOVER_RAW_URL"

echo "Проверяем shell-синтаксис..."
sh -n "\$TMP_INSTALLER"

chmod +x "\$TMP_INSTALLER"

echo
echo "Запускаем свежий failover-установщик с сохранёнными ссылками..."
echo

"\$TMP_INSTALLER" --reuse-failover
UPDATER

    chmod +x "$FAILOVER_INSTALLER_UPDATE_CMD"
    ln -sf "$FAILOVER_INSTALLER_UPDATE_CMD" "$FAILOVER_INSTALLER_UPDATE_ALIAS"

    echo "Команды созданы:"
    echo "$FAILOVER_INSTALLER_UPDATE_CMD"
    echo "$FAILOVER_INSTALLER_UPDATE_ALIAS"
}

ensure_packages

XRAY_BIN="$(get_xray_bin)"

if [ -z "$XRAY_BIN" ]; then
    echo "ОШИБКА: xray не найден после установки."
    exit 1
fi

mkdir -p "$XRAY_DIR" "$TMP_DIR" /opt/var/run /opt/var/log

echo
echo "[2/10] Определяем LAN-IP роутера..."

ROUTER_LAN_IP="$(detect_router_ip | head -n 1)"

if [ -z "$ROUTER_LAN_IP" ]; then
    read_tty "Введите LAN-IP роутера, например 192.168.1.1: " ROUTER_LAN_IP
fi

if [ -z "$ROUTER_LAN_IP" ]; then
    echo "ОШИБКА: LAN-IP роутера пустой."
    exit 1
fi

printf "%s\n" "$ROUTER_LAN_IP" > "$ROUTER_IP_STORE"

echo "LAN-IP роутера: $ROUTER_LAN_IP"
echo "Основной SOCKS5 будет: $ROUTER_LAN_IP:$SOCKS_PORT"

echo
echo "[3/10] Готовим VLESS-ссылки..."

if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    echo "Используем сохранённую Primary VLESS-ссылку:"
    echo "$PRIMARY_STORE"
    PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"

    if [ -s "$BACKUP_STORE" ]; then
        echo "Используем сохранённую Backup VLESS-ссылку:"
        echo "$BACKUP_STORE"
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"
    else
        echo "Backup VLESS не задан."
        BACKUP_VLESS=""
    fi
else
    read_tty "Primary VLESS link: " PRIMARY_VLESS

    if [ -z "$PRIMARY_VLESS" ]; then
        echo "ОШИБКА: Primary VLESS-ссылка пустая."
        exit 1
    fi

    echo
    echo "Backup VLESS link опциональна."
    echo "Для пропуска просто нажмите Enter."
    read_tty "Backup VLESS link, optional. Press Enter to skip: " BACKUP_VLESS
fi

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
    echo "Backup-ссылка сохранена."
else
    rm -f "$BACKUP_STORE"
    echo "Backup-ссылка не задана. Failover будет только мониторить primary."
fi

create_generator
create_xray_init
create_failover_daemon
create_status_command
create_failover_update_command
create_failover_installer_update_command

echo
echo "Генерируем основной Xray config для primary..."

PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$XRAY_CONFIG" \
"$GENERATOR"

echo
echo "Проверяем Xray config..."
"$XRAY_BIN" run -test -config "$XRAY_CONFIG"

echo "primary" > "$ACTIVE_STORE"

echo
echo "Запускаем Xray с primary..."
"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
sleep 1
"$INIT_SCRIPT" start
sleep 2

configure_proxy0
create_failover_init

echo
echo "Запускаем failover-сервис..."

"$FAILOVER_INIT" stop >/dev/null 2>&1 || true
sleep 1
"$FAILOVER_INIT" start

echo
echo "======================================"
echo " ГОТОВО"
echo "======================================"
echo
echo "Xray config:"
echo "$XRAY_CONFIG"
echo
echo "Primary VLESS:"
echo "$PRIMARY_STORE"
echo
echo "Backup VLESS:"
echo "$BACKUP_STORE"
echo
echo "Активный профиль:"
echo "$ACTIVE_STORE"
echo
echo "SOCKS5:"
echo "$ROUTER_LAN_IP:$SOCKS_PORT"
echo
echo "Proxy:"
echo "$PROXY_IFACE"
echo
echo "Failover log:"
echo "/opt/var/log/xray-vless-failover.log"
echo
echo "Команды:"
echo "vless-failover-status"
echo "vless-failover-update"
echo "xray-failover-update"
echo "failover-installer-update"
echo "xray-failover-installer-update"
echo "$FAILOVER_INIT status"
echo "$FAILOVER_INIT restart"
echo "$FAILOVER_INIT stop"
echo "$FAILOVER_INIT start"
echo
SH

chmod +x /opt/tmp/xray-vless-failover-install.sh

echo
echo "Проверяем shell-синтаксис..."
sh -n /opt/tmp/xray-vless-failover-install.sh

echo
echo "Запускаем установщик failover..."
/opt/tmp/xray-vless-failover-install.sh
