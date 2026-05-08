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
REPO_FAILOVER_RAW_URL="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover.sh"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"
GLOBAL_PRIORITY="16375"

CHECK_INTERVAL="10"
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
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
    "")
        ;;
    *)
        echo "Использование: $0 [--reuse-failover]"
        exit 1
        ;;
esac

read_tty() {
    prompt="$1"

    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
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

test_xray_config() {
    CONFIG_FILE="$1"

    if "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi

    "$XRAY_BIN" test -config "$CONFIG_FILE"
}

ensure_packages() {
    echo "[1/10] Проверяем Entware и пакеты..."

    if ! command -v opkg >/dev/null 2>&1; then
        echo "ОШИБКА: opkg не найден. Entware недоступен."
        exit 1
    fi

    NEED_UPDATE="0"
    command -v curl >/dev/null 2>&1 || NEED_UPDATE="1"
    command -v python3 >/dev/null 2>&1 || NEED_UPDATE="1"

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        NEED_UPDATE="1"
    fi

    if [ "$NEED_UPDATE" = "1" ]; then
        opkg update
    fi

    if ! command -v curl >/dev/null 2>&1; then
        opkg install curl ca-bundle
    else
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    command -v python3 >/dev/null 2>&1 || opkg install python3

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        if opkg install xray-core; then
            echo "Установлен xray-core."
        elif opkg install xray; then
            echo "Установлен xray."
        else
            echo "ОШИБКА: не удалось установить xray/xray-core."
            exit 1
        fi
    fi
}

detect_router_ip() {
    if [ -n "${ROUTER_IP:-}" ]; then
        echo "$ROUTER_IP"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        FOUND_IP="$(
            for iface in br0 Bridge0 Home home lan0 lan br-lan; do
                ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
            done | awk 'NF { print; exit }'
        )"

        if [ -n "$FOUND_IP" ]; then
            echo "$FOUND_IP"
            return 0
        fi

        FOUND_IP="$(
            ip -4 addr show scope global 2>/dev/null | awk '
                /inet / {
                    ip=$2
                    sub(/\/.*/, "", ip)
                    if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {
                        print ip
                        exit
                    }
                }'
        )"

        if [ -n "$FOUND_IP" ]; then
            echo "$FOUND_IP"
            return 0
        fi
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        FOUND_IP="$(
            ifconfig 2>/dev/null | awk '
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
                }'
        )"

        if [ -n "$FOUND_IP" ]; then
            echo "$FOUND_IP"
            return 0
        fi
    fi

    return 1
}

create_generator() {
    echo "[4/10] Создаём генератор config..."

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
        stream["tcpSettings"] = {"header": {"type": header_type}}

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
    "log": {"loglevel": "warning"},
    "inbounds": [
        {
            "tag": "socks-in",
            "listen": listen_host,
            "port": listen_port,
            "protocol": "socks",
            "settings": {"auth": "noauth", "udp": True},
            "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic"]}
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
                        "users": [user]
                    }
                ]
            },
            "streamSettings": stream
        },
        {"tag": "direct", "protocol": "freedom"},
        {"tag": "block", "protocol": "blackhole"}
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
    echo "[5/10] Создаём init-скрипт Xray..."

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
    echo "[7/10] Настраиваем Proxy0..."

    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Proxy0 настройте вручную."
        return 0
    fi

    if ndmc -c "interface $PROXY_IFACE" \
        && ndmc -c "interface $PROXY_IFACE proxy protocol socks5" \
        && ndmc -c "interface $PROXY_IFACE proxy socks5-udp" \
        && ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" \
        && ndmc -c "interface $PROXY_IFACE description Xray-Failover" \
        && ndmc -c "interface $PROXY_IFACE ip global $GLOBAL_PRIORITY" \
        && ndmc -c "interface $PROXY_IFACE up" \
        && ndmc -c "system configuration save"
    then
        echo "$PROXY_IFACE -> SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: Proxy0 не удалось полностью настроить. Проверьте вручную."
        return 0
    fi
}

create_failover_daemon() {
    echo "[6/10] Создаём failover-daemon..."

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
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
CHECK_URL="https://www.gstatic.com/generate_204"

TMP_DIR="/opt/tmp"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"

TMP_TEST_PIDS=""

cleanup_children() {
    for p in $TMP_TEST_PIDS; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
}

trap 'cleanup_children; exit 0' INT TERM

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

test_xray_config() {
    CONFIG_FILE="$1"

    if "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi

    "$XRAY_BIN" test -config "$CONFIG_FILE"
}

XRAY_BIN="$(get_xray_bin)"

[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден."; exit 1; }
[ -x "$GENERATOR" ] || { echo "ОШИБКА: генератор не найден: $GENERATOR"; exit 1; }
[ -s "$ROUTER_IP_STORE" ] || { echo "ОШИБКА: LAN-IP не найден: $ROUTER_IP_STORE"; exit 1; }

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

    HTTP_CODE="$(printf "%s\n" "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"
    [ "$STATUS" = "0" ] && [ "$HTTP_CODE" = "204" ]
}

wait_for_socks_port() {
    i=1

    while [ "$i" -le 10 ]; do
        netstat -lnt 2>/dev/null | grep -q "$ROUTER_LAN_IP:$SOCKS_PORT" && return 0
        netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT" && return 0
        sleep 1
        i=$((i + 1))
    done

    return 1
}

restart_proxy0() {
    if command -v ndmc >/dev/null 2>&1; then
        echo "Перезапускаем Proxy0..."
        ndmc -c "interface $PROXY_IFACE down" || true
        sleep 2
        ndmc -c "interface $PROXY_IFACE up" || true
        ndmc -c "system configuration save" || true
    fi
}

generate_profile_config() {
    PROFILE_NAME="$1" \
    VLESS_URL="$2" \
    LISTEN_HOST="$3" \
    LISTEN_PORT="$4" \
    OUTPUT_CONFIG="$5" \
    "$GENERATOR"
}

test_vless_temp() {
    PROFILE="$1"
    URL="$2"
    PORT="$3"
    TMP_CONFIG="$TMP_DIR/xray-failover-test-$PROFILE.json"
    TMP_LOG="$TMP_DIR/xray-failover-test-$PROFILE.log"

    echo "Проверяем временный SOCKS5 профиля: $PROFILE"

    if ! generate_profile_config "$PROFILE" "$URL" "$TEMP_HOST" "$PORT" "$TMP_CONFIG" >/dev/null; then
        echo "Не удалось сгенерировать временный config для $PROFILE."
        return 1
    fi

    if ! test_xray_config "$TMP_CONFIG" >/dev/null; then
        echo "Временный config Xray не прошёл проверку для $PROFILE."
        return 1
    fi

    "$XRAY_BIN" run -config "$TMP_CONFIG" > "$TMP_LOG" 2>&1 &
    TMP_PID="$!"
    TMP_TEST_PIDS="$TMP_TEST_PIDS $TMP_PID"

    sleep 3

    if ! kill -0 "$TMP_PID" 2>/dev/null; then
        echo "Временный Xray не запустился для $PROFILE."
        cat "$TMP_LOG"
        wait "$TMP_PID" 2>/dev/null || true
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

rollback_config() {
    OLD_CONFIG="$1"

    if [ -s "$OLD_CONFIG" ]; then
        echo "Откатываем предыдущий Xray config..."
        cp "$OLD_CONFIG" "$XRAY_CONFIG"
        "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
        sleep 1
        "$INIT_SCRIPT" start >/dev/null 2>&1 || true
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: старый config для rollback не найден."
    fi
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

    TMP_SWITCH_CONFIG="$TMP_DIR/xray-switch-$TARGET.json"
    OLD_CONFIG="$TMP_DIR/xray-config-before-switch.json"

    echo "======================================"
    echo "ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET"
    echo "======================================"

    echo "[1/6] Генерируем временный config для $TARGET..."
    if ! generate_profile_config "$TARGET" "$URL" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: не удалось сгенерировать config для $TARGET."
        return 1
    fi

    echo "[2/6] Проверяем временный config..."
    if ! test_xray_config "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: config Xray не прошёл проверку для $TARGET."
        return 1
    fi

    cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true

    echo "[3/6] Применяем новый config..."
    cp "$TMP_SWITCH_CONFIG" "$XRAY_CONFIG"

    echo "[4/6] Перезапускаем Xray..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 2

    if ! "$INIT_SCRIPT" start; then
        echo "ОШИБКА: Xray не запустился после переключения на $TARGET."
        rollback_config "$OLD_CONFIG"
        return 1
    fi

    echo "[5/6] Проверяем SOCKS5 endpoint..."
    if ! wait_for_socks_port; then
        echo "ОШИБКА: SOCKS5-порт не поднялся."
        rollback_config "$OLD_CONFIG"
        return 1
    fi

    if ! test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
        echo "ОШИБКА: основной SOCKS5 endpoint не прошёл проверку."
        rollback_config "$OLD_CONFIG"
        return 1
    fi

    echo "[6/6] Перезапускаем Proxy0..."
    restart_proxy0

    echo "$TARGET" > "$ACTIVE_STORE"
    sleep 5
    echo "Активный профиль теперь: $TARGET"
}

mkdir -p "$TMP_DIR"

PRIMARY_FAIL_COUNT="0"
PRIMARY_RECOVERY_COUNT="0"
BACKUP_FAIL_COUNT="0"

while true; do
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"

    echo
    echo "[$NOW] Активный профиль: $ACTIVE"

    if [ "$ACTIVE" = "primary" ]; then
        echo "Проверяем active primary через $ROUTER_LAN_IP:$SOCKS_PORT..."

        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
            echo "Primary OK."
            PRIMARY_FAIL_COUNT="0"
        else
            PRIMARY_FAIL_COUNT=$((PRIMARY_FAIL_COUNT + 1))
            echo "Primary НЕ ДОСТУПЕН. Неудачная проверка: $PRIMARY_FAIL_COUNT/$FAILOVER_FAILURES_REQUIRED."

            if [ "$PRIMARY_FAIL_COUNT" -lt "$FAILOVER_FAILURES_REQUIRED" ]; then
                echo "Ждём следующую проверку."
            elif [ -s "$BACKUP_STORE" ]; then
                echo "Проверяем backup перед переключением..."
                if test_vless_temp "backup" "$(cat "$BACKUP_STORE")" "$TEMP_BACKUP_PORT"; then
                    if switch_to_profile "backup"; then
                        PRIMARY_FAIL_COUNT="0"
                        PRIMARY_RECOVERY_COUNT="0"
                        BACKUP_FAIL_COUNT="0"
                    else
                        echo "Переключение на backup не удалось."
                    fi
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
            BACKUP_FAIL_COUNT="0"
        else
            BACKUP_FAIL_COUNT=$((BACKUP_FAIL_COUNT + 1))
            echo "Backup НЕ ДОСТУПЕН. Неудачная проверка backup: $BACKUP_FAIL_COUNT."
        fi

        echo "Проверяем, вернулся ли primary..."

        if test_vless_temp "primary" "$(cat "$PRIMARY_STORE")" "$TEMP_PRIMARY_PORT"; then
            PRIMARY_RECOVERY_COUNT=$((PRIMARY_RECOVERY_COUNT + 1))
            echo "Primary доступен. Успешная проверка восстановления: $PRIMARY_RECOVERY_COUNT/$RECOVERY_SUCCESSES_REQUIRED."

            if [ "$PRIMARY_RECOVERY_COUNT" -ge "$RECOVERY_SUCCESSES_REQUIRED" ]; then
                echo "Primary стабильно доступен. Возвращаемся на primary."
                if switch_to_profile "primary"; then
                    PRIMARY_FAIL_COUNT="0"
                    PRIMARY_RECOVERY_COUNT="0"
                    BACKUP_FAIL_COUNT="0"
                else
                    echo "Переключение на primary не удалось."
                fi
            else
                echo "Ждём ещё одну успешную проверку primary."
            fi
        else
            PRIMARY_RECOVERY_COUNT="0"
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
    echo "[8/10] Создаём init-скрипт failover..."

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
        echo "Daemon не найден: \$DAEMON"
        exit 1
    fi

    "\$DAEMON" >> "\$LOGFILE" 2>&1 &
    echo "\$!" > "\$PIDFILE"

    sleep 2

    if is_running; then
        echo "готово."
        exit 0
    fi

    echo "ошибка."
    tail -n 30 "\$LOGFILE" 2>/dev/null
    rm -f "\$PIDFILE"
    exit 1
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
    fi

    echo "не запущен."
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
    *) echo "Использование: \$0 {start|stop|restart|status}"; exit 1 ;;
esac
INIT

    chmod +x "$FAILOVER_INIT"
}

create_status_command() {
    echo "Создаём команду статуса..."

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
netstat -lntp 2>/dev/null | grep 10808 || netstat -lnt 2>/dev/null | grep 10808 || true

echo
echo "Proxy0:"
ndmc -c "show running-config" 2>/dev/null | grep -A12 -i "interface Proxy0" || true

echo
echo "Последние строки failover-лога:"
tail -n 30 /opt/var/log/xray-vless-failover.log 2>/dev/null || true
STATUS

    chmod +x "$FAILOVER_STATUS"
}

create_failover_update_command() {
    echo "[9/10] Создаём команду обновления ссылок..."

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
TMP_DIR="/opt/tmp"

read_tty() {
    prompt="$1"

    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
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

test_xray_config() {
    CONFIG_FILE="$1"

    if "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi

    "$XRAY_BIN" test -config "$CONFIG_FILE"
}

XRAY_BIN="$(get_xray_bin)"

[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден."; exit 1; }
[ -x "$GENERATOR" ] || { echo "ОШИБКА: генератор не найден: $GENERATOR"; exit 1; }
[ -s "$ROUTER_IP_STORE" ] || { echo "ОШИБКА: LAN-IP не найден: $ROUTER_IP_STORE"; exit 1; }

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-update-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-update-backup.json"
OLD_CONFIG="$TMP_DIR/xray-config-before-vless-update.json"

echo "======================================"
echo " Обновление VLESS-ссылок failover"
echo "======================================"
echo "LAN-IP роутера: $ROUTER_LAN_IP"

read_tty "New Primary VLESS link: "
PRIMARY_VLESS="$REPLY"

[ -n "$PRIMARY_VLESS" ] || { echo "ОШИБКА: Primary VLESS-ссылка пустая."; exit 1; }

echo "Backup VLESS link опциональна. Для пропуска нажмите Enter."
read_tty "New Backup VLESS link, optional. Press Enter to skip: "
BACKUP_VLESS="$REPLY"

mkdir -p "$XRAY_DIR" "$TMP_DIR"

echo "Проверяем новый primary config во временном файле..."
PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем новый backup config во временном файле..."
    PROFILE_NAME="backup" \
    VLESS_URL="$BACKUP_VLESS" \
    LISTEN_HOST="127.0.0.1" \
    LISTEN_PORT="19081" \
    OUTPUT_CONFIG="$TMP_BACKUP_CONFIG" \
    "$GENERATOR"

    test_xray_config "$TMP_BACKUP_CONFIG"
fi

if [ -x "$FAILOVER_INIT" ]; then
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
else
    rm -f "$BACKUP_STORE"
fi

cp "$TMP_PRIMARY_CONFIG" "$XRAY_CONFIG"
echo "primary" > "$ACTIVE_STORE"

if ! "$INIT_SCRIPT" restart; then
    echo "ОШИБКА: Xray не перезапустился. Откатываем старый config."
    [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
    "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

if [ -x "$FAILOVER_INIT" ]; then
    "$FAILOVER_INIT" start
fi

echo "Готово. Активный профиль сброшен на primary."
VUPDATE

    chmod +x "$FAILOVER_UPDATE_CMD"
    ln -sf "$FAILOVER_UPDATE_CMD" "$FAILOVER_UPDATE_ALIAS"
}

create_failover_installer_update_command() {
    echo "[10/10] Создаём команду обновления установщика..."

    cat > "$FAILOVER_INSTALLER_UPDATE_CMD" <<UPDATER
#!/bin/sh
set -e

REPO_FAILOVER_RAW_URL="$REPO_FAILOVER_RAW_URL"
TMP_INSTALLER="/opt/tmp/xray_vless_failover.sh"
PRIMARY_STORE="$PRIMARY_STORE"

command -v opkg >/dev/null 2>&1 || { echo "ОШИБКА: opkg не найден."; exit 1; }

if ! command -v curl >/dev/null 2>&1; then
    opkg update
    opkg install curl ca-bundle
fi

[ -s "\$PRIMARY_STORE" ] || {
    echo "ОШИБКА: сохранённая Primary VLESS-ссылка не найдена: \$PRIMARY_STORE"
    echo "Сначала выполните установщик или vless-failover-update."
    exit 1
}

mkdir -p /opt/tmp
curl -fsSL -o "\$TMP_INSTALLER" "\$REPO_FAILOVER_RAW_URL"
sh -n "\$TMP_INSTALLER"
chmod +x "\$TMP_INSTALLER"
"\$TMP_INSTALLER" --reuse-failover
UPDATER

    chmod +x "$FAILOVER_INSTALLER_UPDATE_CMD"
    ln -sf "$FAILOVER_INSTALLER_UPDATE_CMD" "$FAILOVER_INSTALLER_UPDATE_ALIAS"
}

check_generated_scripts() {
    echo "Проверяем shell-синтаксис созданных скриптов..."

    sh -n "$GENERATOR"
    sh -n "$FAILOVER_DAEMON"
    sh -n "$FAILOVER_UPDATE_CMD"
    sh -n "$FAILOVER_INSTALLER_UPDATE_CMD"
    sh -n "$INIT_SCRIPT"
    sh -n "$FAILOVER_INIT"
}

echo
echo "======================================"
echo " Установщик Xray VLESS Failover"
echo " Entware / Keenetic edition"
echo "======================================"
echo "Интервал проверки: $CHECK_INTERVAL секунд"
echo "Попыток перед backup: $FAILOVER_FAILURES_REQUIRED"
echo "Успешных проверок перед возвратом: $RECOVERY_SUCCESSES_REQUIRED"
echo

ensure_packages

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден после установки."; exit 1; }

mkdir -p "$XRAY_DIR" "$TMP_DIR" /opt/var/run /opt/var/log /opt/etc/init.d /opt/bin

if [ -x "$FAILOVER_INIT" ]; then
    echo "Останавливаем старый failover-daemon перед установкой..."
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

echo "[2/10] Определяем LAN-IP роутера..."
ROUTER_LAN_IP="$(detect_router_ip | head -n 1)"

if [ -n "$ROUTER_LAN_IP" ]; then
    echo "Автоматически найден LAN-IP: $ROUTER_LAN_IP"
    read_tty "Нажмите Enter, чтобы использовать его, или введите другой LAN-IP: "
    if [ -n "$REPLY" ]; then
        ROUTER_LAN_IP="$REPLY"
    fi
else
    read_tty "Введите LAN-IP роутера, например 192.168.1.1: "
    ROUTER_LAN_IP="$REPLY"
fi

[ -n "$ROUTER_LAN_IP" ] || { echo "ОШИБКА: LAN-IP роутера пустой."; exit 1; }
printf "%s\n" "$ROUTER_LAN_IP" > "$ROUTER_IP_STORE"

echo "LAN-IP роутера: $ROUTER_LAN_IP"
echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"

echo "[3/10] Готовим VLESS-ссылки..."
if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"
    if [ -s "$BACKUP_STORE" ]; then
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"
    else
        BACKUP_VLESS=""
    fi
else
    read_tty "Primary VLESS link: "
    PRIMARY_VLESS="$REPLY"
    [ -n "$PRIMARY_VLESS" ] || { echo "ОШИБКА: Primary VLESS-ссылка пустая."; exit 1; }

    echo "Backup VLESS link опциональна. Для пропуска нажмите Enter."
    read_tty "Backup VLESS link, optional. Press Enter to skip: "
    BACKUP_VLESS="$REPLY"
fi

create_generator
create_xray_init
create_failover_daemon
create_status_command
create_failover_update_command
create_failover_installer_update_command
create_failover_init

check_generated_scripts

echo "Проверяем primary config во временном файле..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем backup config во временном файле..."
    TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"
    PROFILE_NAME="backup" \
    VLESS_URL="$BACKUP_VLESS" \
    LISTEN_HOST="127.0.0.1" \
    LISTEN_PORT="$TEMP_BACKUP_PORT" \
    OUTPUT_CONFIG="$TMP_BACKUP_CONFIG" \
    "$GENERATOR"

    test_xray_config "$TMP_BACKUP_CONFIG"
fi

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
    echo "Backup-ссылка сохранена."
else
    rm -f "$BACKUP_STORE"
    echo "Backup-ссылка не задана."
fi

cp "$TMP_PRIMARY_CONFIG" "$XRAY_CONFIG"
echo "primary" > "$ACTIVE_STORE"

echo "Запускаем Xray..."
"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
sleep 1
"$INIT_SCRIPT" start
sleep 2

configure_proxy0

echo "Запускаем failover-сервис..."
"$FAILOVER_INIT" stop >/dev/null 2>&1 || true
sleep 1
"$FAILOVER_INIT" start

echo
echo "======================================"
echo " ГОТОВО"
echo "======================================"
echo "Xray config: $XRAY_CONFIG"
echo "Primary VLESS: $PRIMARY_STORE"
echo "Backup VLESS: $BACKUP_STORE"
echo "Активный профиль: $ACTIVE_STORE"
echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"
echo "Proxy: $PROXY_IFACE"
echo "Failover log: /opt/var/log/xray-vless-failover.log"
echo
echo "Команды:"
echo "vless-failover-status"
echo "vless-failover-update"
echo "xray-failover-update"
echo "failover-installer-update"
echo "xray-failover-installer-update"
echo "$FAILOVER_INIT status|restart|stop|start"
