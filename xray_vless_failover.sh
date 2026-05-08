#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"

GENERATOR="/opt/bin/xray-vless-generate-config"
FAILOVER_DAEMON="/opt/bin/xray-vless-failover-daemon"
FAILOVER_STATUS="/opt/bin/vless-failover-status"
FAILOVER_MENU_CMD="/opt/bin/failover"
XRAY_CORE_UPDATE_CMD="/opt/bin/xray-core-update"
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

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

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
import re
import base64
import urllib.parse
import urllib.request

profile_name = os.environ.get("PROFILE_NAME", "vless-out")
source_url = os.environ["VLESS_URL"].strip()
listen_host = os.environ["LISTEN_HOST"]
listen_port = int(os.environ["LISTEN_PORT"])
output_config = os.environ["OUTPUT_CONFIG"]


def _decode_bytes(data):
    """Return text variants from raw subscription bytes."""
    variants = []

    for enc in ("utf-8", "latin-1"):
        try:
            text = data.decode(enc, errors="ignore").strip()
            if text and text not in variants:
                variants.append(text)
        except Exception:
            pass

    compact = re.sub(rb"\s+", b"", data)
    if compact:
        padding = b"=" * ((4 - len(compact) % 4) % 4)
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                decoded = decoder(compact + padding)
                text = decoded.decode("utf-8", errors="ignore").strip()
                if text and text not in variants:
                    variants.append(text)
            except Exception:
                pass

    return variants


def _extract_vless(text):
    match = re.search(r"vless://[^\s\r\n<>\"']+", text)
    if match:
        return match.group(0).strip()
    return ""


def resolve_vless_url(value):
    value = value.strip()

    if value.startswith("vless://"):
        return value

    parsed = urllib.parse.urlparse(value)
    if parsed.scheme not in ("http", "https"):
        raise SystemExit("ERROR: expected vless:// link or http(s) subscription link")

    req = urllib.request.Request(
        value,
        headers={
            "User-Agent": "Keenetic-Xray-Failover/1.0",
            "Accept": "text/plain,*/*",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            payload = response.read()
    except Exception as exc:
        raise SystemExit(f"ERROR: failed to download subscription: {exc}")

    for text in _decode_bytes(payload):
        found = _extract_vless(text)
        if found:
            return found

    raise SystemExit("ERROR: subscription does not contain vless:// links")


url = resolve_vless_url(source_url)
u = urllib.parse.urlparse(url)

if u.scheme != "vless":
    raise SystemExit("ERROR: only vless:// links are supported after subscription resolving")

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

print("Создан config:", output_config)
print("Профиль:", profile_name)
print("Источник:", "подписка" if source_url != url else "прямая VLESS-ссылка")
print("Сервер:", server)
print("Порт:", port)
print("Транспорт:", network)
print("Защита:", security)
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

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

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
    PROFILE_LABEL="$(profile_display_name "$PROFILE")"

    echo "Проверяем временный SOCKS5 профиля: $PROFILE_LABEL"

    if ! generate_profile_config "$PROFILE" "$URL" "$TEMP_HOST" "$PORT" "$TMP_CONFIG" >/dev/null; then
        echo "Не удалось сгенерировать временный config для профиля $PROFILE_LABEL."
        return 1
    fi

    if ! test_xray_config "$TMP_CONFIG" >/dev/null; then
        echo "Временный config Xray не прошёл проверку для профиля $PROFILE_LABEL."
        return 1
    fi

    "$XRAY_BIN" run -config "$TMP_CONFIG" > "$TMP_LOG" 2>&1 &
    TMP_PID="$!"
    TMP_TEST_PIDS="$TMP_TEST_PIDS $TMP_PID"

    sleep 3

    if ! kill -0 "$TMP_PID" 2>/dev/null; then
        echo "Временный Xray не запустился для профиля $PROFILE_LABEL."
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

    TARGET_LABEL="$(profile_display_name "$TARGET")"
    TMP_SWITCH_CONFIG="$TMP_DIR/xray-switch-$TARGET.json"
    OLD_CONFIG="$TMP_DIR/xray-config-before-switch.json"

    echo "======================================"
    echo "ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET_LABEL"
    echo "======================================"

    echo "[1/6] Генерируем временный config для профиля $TARGET_LABEL..."
    if ! generate_profile_config "$TARGET" "$URL" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: не удалось сгенерировать config для профиля $TARGET_LABEL."
        return 1
    fi

    echo "[2/6] Проверяем временный config..."
    if ! test_xray_config "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: config Xray не прошёл проверку для профиля $TARGET_LABEL."
        return 1
    fi

    cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true

    echo "[3/6] Применяем новый config..."
    cp "$TMP_SWITCH_CONFIG" "$XRAY_CONFIG"

    echo "[4/6] Перезапускаем Xray..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 2

    if ! "$INIT_SCRIPT" start; then
        echo "ОШИБКА: Xray не запустился после переключения на профиль $TARGET_LABEL."
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
    echo "Активный профиль теперь: $TARGET_LABEL"
}

mkdir -p "$TMP_DIR"

PRIMARY_FAIL_COUNT="0"
PRIMARY_RECOVERY_COUNT="0"
BACKUP_FAIL_COUNT="0"

while true; do
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    ACTIVE_LABEL="$(profile_display_name "$ACTIVE")"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"

    echo
    echo "[$NOW] Активный профиль: $ACTIVE_LABEL"

    if [ "$ACTIVE" = "primary" ]; then
        echo "Проверяем активный Основной профиль через $ROUTER_LAN_IP:$SOCKS_PORT..."

        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
            echo "Основной профиль доступен."
            PRIMARY_FAIL_COUNT="0"
        else
            PRIMARY_FAIL_COUNT=$((PRIMARY_FAIL_COUNT + 1))
            echo "Основной профиль НЕДОСТУПЕН. Неудачная проверка: $PRIMARY_FAIL_COUNT/$FAILOVER_FAILURES_REQUIRED."

            if [ "$PRIMARY_FAIL_COUNT" -lt "$FAILOVER_FAILURES_REQUIRED" ]; then
                echo "Ждём следующую проверку."
            elif [ -s "$BACKUP_STORE" ]; then
                echo "Проверяем Резервный профиль перед переключением..."
                if test_vless_temp "backup" "$(cat "$BACKUP_STORE")" "$TEMP_BACKUP_PORT"; then
                    if switch_to_profile "backup"; then
                        PRIMARY_FAIL_COUNT="0"
                        PRIMARY_RECOVERY_COUNT="0"
                        BACKUP_FAIL_COUNT="0"
                    else
                        echo "Переключение на Резервный профиль не удалось."
                    fi
                else
                    echo "Резервный профиль тоже недоступен. Остаёмся на config Основного профиля."
                fi
            else
                echo "VLESS-ссылка Резервного профиля не настроена."
            fi
        fi

    elif [ "$ACTIVE" = "backup" ]; then
        echo "Проверяем активный Резервный профиль через $ROUTER_LAN_IP:$SOCKS_PORT..."

        if test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
            echo "Резервный профиль доступен."
            BACKUP_FAIL_COUNT="0"
        else
            BACKUP_FAIL_COUNT=$((BACKUP_FAIL_COUNT + 1))
            echo "Резервный профиль НЕДОСТУПЕН. Неудачная проверка Резервного профиля: $BACKUP_FAIL_COUNT."
        fi

        echo "Проверяем, восстановился ли Основной профиль..."

        if test_vless_temp "primary" "$(cat "$PRIMARY_STORE")" "$TEMP_PRIMARY_PORT"; then
            PRIMARY_RECOVERY_COUNT=$((PRIMARY_RECOVERY_COUNT + 1))
            echo "Основной профиль доступен. Успешная проверка восстановления: $PRIMARY_RECOVERY_COUNT/$RECOVERY_SUCCESSES_REQUIRED."

            if [ "$PRIMARY_RECOVERY_COUNT" -ge "$RECOVERY_SUCCESSES_REQUIRED" ]; then
                echo "Основной профиль стабильно доступен. Возвращаемся на Основной профиль."
                if switch_to_profile "primary"; then
                    PRIMARY_FAIL_COUNT="0"
                    PRIMARY_RECOVERY_COUNT="0"
                    BACKUP_FAIL_COUNT="0"
                else
                    echo "Переключение на Основной профиль не удалось."
                fi
            else
                echo "Ждём ещё одну успешную проверку Основного профиля."
            fi
        else
            PRIMARY_RECOVERY_COUNT="0"
            echo "Основной профиль всё ещё недоступен. Остаёмся на Резервном профиле."
        fi
    else
        echo "Неизвестное значение active-profile. Пробуем вернуться на Основной профиль."
        switch_to_profile "primary" || echo "Переключение на Основной профиль не удалось."
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
ACTIVE="$(cat /opt/etc/xray/active-profile 2>/dev/null || echo unknown)"
case "$ACTIVE" in
    primary) echo "Основной" ;;
    backup) echo "Резервный" ;;
    *) echo "$ACTIVE" ;;
esac

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


create_xray_core_update_command() {
    echo "Создаём команду обновления ядра Xray..."

    cat > "$XRAY_CORE_UPDATE_CMD" <<'COREUPDATE'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_BIN="/opt/bin/xray"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
BACKUP_DIR="$XRAY_DIR/backups"
TMP_DIR="/opt/tmp/xray-core-update"
RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases"
LATEST_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

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

detect_asset_name() {
    ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$ARCH" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i486|i586|i686) echo "Xray-linux-32.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*|armv8l) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
        armv5*|arm) echo "Xray-linux-arm32-v5.zip" ;;
        mips64el|mips64le) echo "Xray-linux-mips64le.zip" ;;
        mips64) echo "Xray-linux-mips64.zip" ;;
        mipsel|mipsle) echo "Xray-linux-mips32le.zip" ;;
        mips) echo "Xray-linux-mips32.zip" ;;
        riscv64) echo "Xray-linux-riscv64.zip" ;;
        *) echo "" ;;
    esac
}

choose_release_json() {
    MODE="$1"
    OUT_JSON="$2"

    if [ "$MODE" = "stable" ]; then
        curl -fsSL -H "User-Agent: xray-core-update" -o "$OUT_JSON" "$LATEST_API"
    else
        ALL_JSON="$TMP_DIR/releases.json"
        curl -fsSL -H "User-Agent: xray-core-update" -o "$ALL_JSON" "$RELEASES_API"
        python3 - "$ALL_JSON" "$OUT_JSON" <<'PY'
import json
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    releases = json.load(f)
for release in releases:
    if release.get('prerelease'):
        with open(dst, 'w', encoding='utf-8') as out:
            json.dump(release, out)
        break
else:
    raise SystemExit('Не найден pre-release Xray-core в GitHub releases')
PY
    fi
}

extract_release_field() {
    JSON_FILE="$1"
    FIELD="$2"
    python3 - "$JSON_FILE" "$FIELD" <<'PY'
import json
import sys
path, field = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get(field, ''))
PY
}

extract_asset_url() {
    JSON_FILE="$1"
    ASSET_NAME="$2"
    python3 - "$JSON_FILE" "$ASSET_NAME" <<'PY'
import json
import sys
path, asset_name = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
for asset in data.get('assets', []):
    if asset.get('name') == asset_name:
        print(asset.get('browser_download_url', ''))
        break
PY
}

make_backup() {
    TS="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || date +%s)"
    DEST="$BACKUP_DIR/$TS"
    mkdir -p "$DEST"
    [ -x "$XRAY_BIN" ] && cp "$XRAY_BIN" "$DEST/xray" || true
    [ -s "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "$DEST/config.json" || true
    if [ -d "$XRAY_DIR" ]; then
        cp "$XRAY_DIR"/vless-*.url "$DEST" 2>/dev/null || true
        cp "$XRAY_DIR"/active-profile "$DEST" 2>/dev/null || true
        cp "$XRAY_DIR"/router-lan-ip "$DEST" 2>/dev/null || true
    fi
    echo "$DEST"
}

install_unzip_if_needed() {
    if command -v unzip >/dev/null 2>&1; then
        return 0
    fi
    echo "unzip не найден. Пробуем установить unzip через opkg..."
    if command -v opkg >/dev/null 2>&1; then
        opkg update
        opkg install unzip
    else
        echo "ОШИБКА: unzip не найден и opkg недоступен."
        exit 1
    fi
}

echo
echo "======================================"
echo " Обновление ядра Xray-core"
echo "======================================"
echo

command -v curl >/dev/null 2>&1 || { echo "ОШИБКА: curl не найден."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ОШИБКА: python3 не найден."; exit 1; }
install_unzip_if_needed

CURRENT_XRAY="$(get_xray_bin)"
[ -n "$CURRENT_XRAY" ] && XRAY_BIN="$CURRENT_XRAY"

echo "Текущий xray: ${XRAY_BIN:-не найден}"
if [ -x "$XRAY_BIN" ]; then
    "$XRAY_BIN" version 2>/dev/null | head -n 3 || true
fi

echo
while true; do
    read_tty "Сделать бэкап текущего ядра и config? [Y/n]: "
    case "$REPLY" in
        ""|y|Y|yes|YES|д|Д|да|ДА) DO_BACKUP="1"; break ;;
        n|N|no|NO|н|Н|нет|НЕТ) DO_BACKUP="0"; break ;;
        *) echo "Введите y или n." ;;
    esac
done

echo
while true; do
    echo "Выберите канал обновления:"
    echo "1 Stable"
    echo "2 Pre-release"
    read_tty "Ваш выбор [1/2]: "
    case "$REPLY" in
        1) RELEASE_MODE="stable"; break ;;
        2) RELEASE_MODE="prerelease"; break ;;
        *) echo "Введите 1 или 2." ;;
    esac
done

ASSET_NAME="$(detect_asset_name)"
if [ -z "$ASSET_NAME" ]; then
    echo "ОШИБКА: не удалось определить asset для архитектуры: $(uname -m 2>/dev/null || echo unknown)"
    echo "Поддерживаемые архитектуры: x86_64, aarch64, armv7, armv6, mips/mipsel/mips64, riscv64."
    exit 1
fi

echo
echo "Архитектура: $(uname -m 2>/dev/null || echo unknown)"
echo "Asset Xray-core: $ASSET_NAME"
echo "Канал: $RELEASE_MODE"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR" "$BACKUP_DIR"
RELEASE_JSON="$TMP_DIR/release.json"
ZIP_FILE="$TMP_DIR/$ASSET_NAME"
choose_release_json "$RELEASE_MODE" "$RELEASE_JSON"
TAG_NAME="$(extract_release_field "$RELEASE_JSON" tag_name)"
RELEASE_NAME="$(extract_release_field "$RELEASE_JSON" name)"
ASSET_URL="$(extract_asset_url "$RELEASE_JSON" "$ASSET_NAME")"

if [ -z "$ASSET_URL" ]; then
    echo "ОШИБКА: в релизе $TAG_NAME не найден asset $ASSET_NAME."
    exit 1
fi

echo "Релиз: ${RELEASE_NAME:-$TAG_NAME}"
echo "Скачиваем Xray-core..."
curl -fL -H "User-Agent: xray-core-update" -o "$ZIP_FILE" "$ASSET_URL"

echo "Распаковываем..."
unzip -oq "$ZIP_FILE" -d "$TMP_DIR/extract"

if [ ! -f "$TMP_DIR/extract/xray" ]; then
    echo "ОШИБКА: в архиве не найден бинарник xray."
    exit 1
fi

chmod +x "$TMP_DIR/extract/xray"
echo "Проверяем новый бинарник..."
"$TMP_DIR/extract/xray" version | head -n 3

if [ "$DO_BACKUP" = "1" ]; then
    BACKUP_PATH="$(make_backup)"
    echo "Бэкап создан: $BACKUP_PATH"
else
    echo "Бэкап пропущен по выбору пользователя."
fi

if [ -x "$FAILOVER_INIT" ]; then
    echo "Останавливаем failover..."
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

if [ -x "$INIT_SCRIPT" ]; then
    echo "Останавливаем Xray..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
fi

TARGET_BIN="/opt/bin/xray"
mkdir -p /opt/bin
cp "$TMP_DIR/extract/xray" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

echo "Новое ядро установлено: $TARGET_BIN"
"$TARGET_BIN" version | head -n 3

if [ -s "$XRAY_CONFIG" ]; then
    echo "Проверяем текущий config новым ядром..."
    if ! "$TARGET_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        "$TARGET_BIN" test -config "$XRAY_CONFIG"
    fi
fi

if [ -x "$INIT_SCRIPT" ]; then
    echo "Запускаем Xray..."
    "$INIT_SCRIPT" start
fi

if [ -x "$FAILOVER_INIT" ]; then
    echo "Запускаем failover..."
    "$FAILOVER_INIT" start
fi

echo
echo "Обновление ядра Xray-core завершено."
COREUPDATE

    chmod +x "$XRAY_CORE_UPDATE_CMD"
}

create_menu_command() {
    echo "Создаём меню failover..."

    cat > "$FAILOVER_MENU_CMD" <<'MENU'
#!/bin/sh

STATUS_CMD="/opt/bin/vless-failover-status"
UPDATE_CMD="/opt/bin/vless-failover-update"
XRAY_CORE_UPDATE_CMD="/opt/bin/xray-core-update"
XRAY_INIT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
XRAY_CONFIG="/opt/etc/xray/config.json"
ACTIVE_STORE="/opt/etc/xray/active-profile"
ROUTER_IP_STORE="/opt/etc/xray/router-lan-ip"
SOCKS_PORT="10808"
CHECK_URL="https://www.gstatic.com/generate_204"
LOGFILE="/opt/var/log/xray-vless-failover.log"

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
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

pause_menu() {
    echo
    printf "Нажмите Enter для возврата в меню..."
    IFS= read -r _
}

show_header() {
    clear 2>/dev/null || true
    echo "======================================"
    echo " Xray VLESS Failover"
    echo "======================================"
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
    ACTIVE_LABEL="$(profile_display_name "$ACTIVE")"
    echo "Активный профиль: $ACTIVE_LABEL"
    if [ -s "$ROUTER_IP_STORE" ]; then
        ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
        echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"
    fi
    echo
}

show_realtime_log() {
    echo "Лог failover в реальном времени: $LOGFILE"
    echo "Для выхода нажмите Ctrl+C."
    echo
    if [ -f "$LOGFILE" ]; then
        tail -f "$LOGFILE"
    else
        echo "Лог пока не найден: $LOGFILE"
        pause_menu
    fi
}

run_diagnostics() {
    echo "======================================"
    echo " Диагностика Xray VLESS Failover"
    echo "======================================"
    echo
    echo "Активный профиль:"
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
    profile_display_name "$ACTIVE"
    echo
    echo "Статус Xray:"
    [ -x "$XRAY_INIT" ] && "$XRAY_INIT" status || echo "Init-скрипт Xray не найден: $XRAY_INIT"
    echo
    echo "Статус failover:"
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" status || echo "Init-скрипт failover не найден: $FAILOVER_INIT"
    echo
    echo "Проверка shell-команд:"
    command -v curl >/dev/null 2>&1 && echo "curl: найден" || echo "curl: НЕ найден"
    command -v python3 >/dev/null 2>&1 && echo "python3: найден" || echo "python3: НЕ найден"
    XRAY_BIN="$(get_xray_bin)"
    if [ -n "$XRAY_BIN" ]; then
        echo "xray: $XRAY_BIN"
        "$XRAY_BIN" version 2>/dev/null | head -n 3 || true
    else
        echo "xray: НЕ найден"
    fi
    echo
    echo "Проверка Xray config:"
    if [ -n "$XRAY_BIN" ] && [ -s "$XRAY_CONFIG" ]; then
        if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || "$XRAY_BIN" test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
            echo "config.json: OK"
        else
            echo "config.json: ОШИБКА"
        fi
    else
        echo "config.json не найден или xray недоступен."
    fi
    echo
    echo "SOCKS5 port:"
    netstat -lntp 2>/dev/null | grep "$SOCKS_PORT" || netstat -lnt 2>/dev/null | grep "$SOCKS_PORT" || echo "Порт $SOCKS_PORT не найден в LISTEN."
    echo
    if [ -s "$ROUTER_IP_STORE" ]; then
        ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
        echo "Проверка выхода через SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT:"
        if command -v curl >/dev/null 2>&1; then
            RESULT="$(curl -k -sS \
                --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" \
                --connect-timeout 5 \
                --max-time 10 \
                -o /dev/null \
                -w 'http_code=%{http_code} time_total=%{time_total}' \
                "$CHECK_URL" 2>&1)" && STATUS="0" || STATUS="$?"
            echo "$RESULT"
            HTTP_CODE="$(printf "%s\n" "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"
            if [ "$STATUS" = "0" ] && [ "$HTTP_CODE" = "204" ]; then
                echo "SOCKS5-проверка: OK"
            else
                echo "SOCKS5-проверка: ОШИБКА"
            fi
        else
            echo "curl не найден."
        fi
    else
        echo "Файл LAN-IP не найден: $ROUTER_IP_STORE"
    fi
    echo
    echo "Proxy0:"
    if command -v ndmc >/dev/null 2>&1; then
        ndmc -c "show running-config" 2>/dev/null | grep -A12 -i "interface Proxy0" || echo "Proxy0 не найден в running-config."
    else
        echo "ndmc не найден."
    fi
    echo
    echo "Последние строки failover-лога:"
    tail -n 30 "$LOGFILE" 2>/dev/null || echo "Лог пока не найден: $LOGFILE"
    pause_menu
}

while true; do
    show_header
    echo "1 Обновление VLESS"
    echo "2 Лог в реальном времени"
    echo "3 Диагностика"
    echo "4 Обновление ядра Xray"
    echo "0 Выход"
    echo
    printf "Выберите пункт: "
    IFS= read -r MENU_CHOICE
    case "$MENU_CHOICE" in
        1)
            [ -x "$UPDATE_CMD" ] && "$UPDATE_CMD" || { echo "Команда обновления не найдена: $UPDATE_CMD"; pause_menu; }
            ;;
        2) show_realtime_log ;;
        3) run_diagnostics ;;
        4)
            if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
                "$XRAY_CORE_UPDATE_CMD"
            else
                echo "Команда обновления ядра не найдена: $XRAY_CORE_UPDATE_CMD"
            fi
            pause_menu
            ;;
        0) echo "Выход."; exit 0 ;;
        *) echo "Неизвестный пункт: $MENU_CHOICE"; pause_menu ;;
    esac
done
MENU

    chmod +x "$FAILOVER_MENU_CMD"
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

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

validate_profile_input() {
    PROFILE="$1"
    SOURCE_VALUE="$2"
    HOST="$3"
    PORT="$4"
    OUT_CONFIG="$5"
    LABEL="$(profile_display_name "$PROFILE")"

    if [ -z "$SOURCE_VALUE" ]; then
        echo "ОШИБКА: ссылка профиля $LABEL пустая."
        return 1
    fi

    PROFILE_NAME="$PROFILE"     VLESS_URL="$SOURCE_VALUE"     LISTEN_HOST="$HOST"     LISTEN_PORT="$PORT"     OUTPUT_CONFIG="$OUT_CONFIG"     "$GENERATOR"

    test_xray_config "$OUT_CONFIG"
}

ask_required_profile_input() {
    PROFILE="$1"
    LABEL="$(profile_display_name "$PROFILE")"
    HOST="$2"
    PORT="$3"
    OUT_CONFIG="$4"

    while true; do
        read_tty "VLESS-ссылка или ссылка подписки $LABEL профиля: "
        CANDIDATE="$REPLY"

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_INPUT_RESULT="$CANDIDATE"
            return 0
        fi

        echo
        echo "Ссылка профиля $LABEL неверная или подписка недоступна."
        echo "Поддерживаются форматы:"
        echo "- vless://..."
        echo "- https://... ссылка подписки, внутри которой есть vless://"
        echo "Попробуйте ввести ссылку заново."
        echo
    done
}

ask_optional_profile_input() {
    PROFILE="$1"
    LABEL="$(profile_display_name "$PROFILE")"
    HOST="$2"
    PORT="$3"
    OUT_CONFIG="$4"

    while true; do
        read_tty "VLESS-ссылка или ссылка подписки $LABEL профиля, опционально. Enter - пропустить: "
        CANDIDATE="$REPLY"

        if [ -z "$CANDIDATE" ]; then
            PROFILE_INPUT_RESULT=""
            return 0
        fi

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_INPUT_RESULT="$CANDIDATE"
            return 0
        fi

        echo
        echo "Ссылка профиля $LABEL неверная или подписка недоступна."
        echo "Введите корректную ссылку заново или нажмите Enter, чтобы пропустить $LABEL профиль."
        echo
    done
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

mkdir -p "$XRAY_DIR" "$TMP_DIR"

ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
PRIMARY_VLESS="$PROFILE_INPUT_RESULT"

ask_optional_profile_input "backup" "127.0.0.1" "19081" "$TMP_BACKUP_CONFIG"
BACKUP_VLESS="$PROFILE_INPUT_RESULT"

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

echo "Готово. Активный профиль сброшен на Основной."
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
    echo "ОШИБКА: сохранённая VLESS-ссылка Основного профиля не найдена: \$PRIMARY_STORE"
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
    sh -n "$XRAY_CORE_UPDATE_CMD"
    sh -n "$FAILOVER_MENU_CMD"
    sh -n "$FAILOVER_UPDATE_CMD"
    sh -n "$FAILOVER_INSTALLER_UPDATE_CMD"
    sh -n "$INIT_SCRIPT"
    sh -n "$FAILOVER_INIT"
}

validate_profile_input() {
    PROFILE="$1"
    SOURCE_VALUE="$2"
    HOST="$3"
    PORT="$4"
    OUT_CONFIG="$5"
    LABEL="$(profile_display_name "$PROFILE")"

    if [ -z "$SOURCE_VALUE" ]; then
        echo "ОШИБКА: ссылка профиля $LABEL пустая."
        return 1
    fi

    PROFILE_NAME="$PROFILE"     VLESS_URL="$SOURCE_VALUE"     LISTEN_HOST="$HOST"     LISTEN_PORT="$PORT"     OUTPUT_CONFIG="$OUT_CONFIG"     "$GENERATOR"

    test_xray_config "$OUT_CONFIG"
}

ask_required_profile_input() {
    PROFILE="$1"
    LABEL="$(profile_display_name "$PROFILE")"
    HOST="$2"
    PORT="$3"
    OUT_CONFIG="$4"

    while true; do
        read_tty "VLESS-ссылка или ссылка подписки $LABEL профиля: "
        CANDIDATE="$REPLY"

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_INPUT_RESULT="$CANDIDATE"
            return 0
        fi

        echo
        echo "Ссылка профиля $LABEL неверная или подписка недоступна."
        echo "Поддерживаются форматы:"
        echo "- vless://..."
        echo "- https://... ссылка подписки, внутри которой есть vless://"
        echo "Попробуйте ввести ссылку заново."
        echo
    done
}

ask_optional_profile_input() {
    PROFILE="$1"
    LABEL="$(profile_display_name "$PROFILE")"
    HOST="$2"
    PORT="$3"
    OUT_CONFIG="$4"

    while true; do
        read_tty "VLESS-ссылка или ссылка подписки $LABEL профиля, опционально. Enter - пропустить: "
        CANDIDATE="$REPLY"

        if [ -z "$CANDIDATE" ]; then
            PROFILE_INPUT_RESULT=""
            return 0
        fi

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_INPUT_RESULT="$CANDIDATE"
            return 0
        fi

        echo
        echo "Ссылка профиля $LABEL неверная или подписка недоступна."
        echo "Введите корректную ссылку заново или нажмите Enter, чтобы пропустить $LABEL профиль."
        echo
    done
}

echo
echo "======================================"
echo " Установщик Xray VLESS Failover"
echo " Entware / Keenetic edition"
echo "======================================"
echo "Интервал проверки: $CHECK_INTERVAL секунд"
echo "Ошибок перед переходом на Резервный профиль: $FAILOVER_FAILURES_REQUIRED"
echo "Успешных проверок перед возвратом на Основной профиль: $RECOVERY_SUCCESSES_REQUIRED"
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

create_generator

echo "[3/10] Готовим VLESS-ссылки или ссылки подписок..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"

if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    echo "Используем сохранённую ссылку Основного профиля."
    PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"

    if ! validate_profile_input "primary" "$PRIMARY_VLESS" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"; then
        echo "Сохранённая ссылка Основного профиля неверная или подписка недоступна. Нужно ввести заново."
        ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
        PRIMARY_VLESS="$PROFILE_INPUT_RESULT"
    fi

    if [ -s "$BACKUP_STORE" ]; then
        echo "Используем сохранённую ссылку Резервного профиля."
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"

        if ! validate_profile_input "backup" "$BACKUP_VLESS" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"; then
            echo "Сохранённая ссылка Резервного профиля неверная или подписка недоступна."
            ask_optional_profile_input "backup" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"
            BACKUP_VLESS="$PROFILE_INPUT_RESULT"
        fi
    else
        echo "VLESS-ссылка Резервного профиля не задана."
        BACKUP_VLESS=""
    fi
else
    ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
    PRIMARY_VLESS="$PROFILE_INPUT_RESULT"

    ask_optional_profile_input "backup" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"
    BACKUP_VLESS="$PROFILE_INPUT_RESULT"
fi

create_xray_init
create_failover_daemon
create_status_command
create_xray_core_update_command
create_menu_command
create_failover_update_command
create_failover_installer_update_command
create_failover_init

check_generated_scripts

echo "Проверяем config Основного профиля во временном файле..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем config Резервного профиля во временном файле..."
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
    echo "VLESS-ссылка Резервного профиля сохранена."
else
    rm -f "$BACKUP_STORE"
    echo "VLESS-ссылка Резервного профиля не задана."
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
echo "VLESS Основного профиля: $PRIMARY_STORE"
echo "VLESS Резервного профиля: $BACKUP_STORE"
echo "Файл активного профиля: $ACTIVE_STORE"
echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"
echo "Proxy: $PROXY_IFACE"
echo "Failover log: /opt/var/log/xray-vless-failover.log"
echo
echo "Команды:"
echo "failover"
echo "xray-core-update"
echo "vless-failover-status"
echo "vless-failover-update"
echo "xray-failover-update"
echo "failover-installer-update"
echo "xray-failover-installer-update"
echo "$FAILOVER_INIT status|restart|stop|start"
