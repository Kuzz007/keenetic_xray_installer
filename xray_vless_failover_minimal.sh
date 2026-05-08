#!/bin/sh
set -e

# Xray VLESS Failover Minimal Edition
# Для Entware во встроенной памяти.
# Без python3, без подписок, без cron, без обновления ядра.
# Поддерживает только прямые vless:// ссылки.

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"

GENERATOR="/opt/bin/xray-vless-generate-config-minimal"
FAILOVER_DAEMON="/opt/bin/xray-vless-failover-daemon-minimal"
FAILOVER_STATUS="/opt/bin/vless-failover-status"
FAILOVER_UPDATE_CMD="/opt/bin/vless-failover-update"
FAILOVER_MENU_CMD="/opt/bin/failover"
FAILOVER_SWITCH_CMD="/opt/bin/xray-failover-switch"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"

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
REUSE_FAILOVER="0"

case "${1:-}" in
    --reuse-failover) REUSE_FAILOVER="1" ;;
    "") ;;
    *) echo "Использование: $0 [--reuse-failover]"; exit 1 ;;
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

test_xray_config() {
    CONFIG_FILE="$1"
    if "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        return 0
    fi
    "$XRAY_BIN" test -config "$CONFIG_FILE"
}

safe_cleanup_low_space() {
    rm -rf /opt/var/cache/* /opt/var/opkg-lists/* 2>/dev/null || true
    rm -f "$TMP_DIR"/xray-failover-test-*.json 2>/dev/null || true
    rm -f "$TMP_DIR"/xray-failover-test-*.log 2>/dev/null || true
    rm -f "$TMP_DIR"/xray-switch-*.json 2>/dev/null || true
    rm -f "$TMP_DIR"/xray-install-primary.json 2>/dev/null || true
    rm -f "$TMP_DIR"/xray-install-backup.json 2>/dev/null || true
}

ensure_packages() {
    echo "[1/8] Проверяем Entware и минимальные пакеты..."
    command -v opkg >/dev/null 2>&1 || { echo "ОШИБКА: opkg не найден."; exit 1; }

    mkdir -p "$TMP_DIR" /opt/var/cache /opt/var/opkg-lists

    echo "Свободное место до установки:"
    df -h /opt 2>/dev/null || true

    safe_cleanup_low_space
    opkg update

    if ! command -v xray >/dev/null 2>&1 && [ ! -x /opt/bin/xray ]; then
        echo "Устанавливаем xray-core / xray..."
        if opkg install xray-core; then
            echo "Установлен xray-core."
        elif opkg install xray; then
            echo "Установлен xray."
        else
            echo "ОШИБКА: не удалось установить xray/xray-core."
            echo "Для встроенной памяти попробуйте вручную:"
            echo "rm -rf /opt/tmp/* /opt/var/opkg-lists/* /opt/var/cache/*"
            echo "opkg update && opkg install xray-core"
            exit 1
        fi
    else
        echo "xray найден."
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "Устанавливаем curl и ca-bundle..."
        opkg install curl ca-bundle
    else
        echo "curl найден."
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    safe_cleanup_low_space

    echo "Свободное место после установки пакетов:"
    df -h /opt 2>/dev/null || true
}

detect_router_ip() {
    if [ -n "${ROUTER_IP:-}" ]; then echo "$ROUTER_IP"; return 0; fi

    if command -v ip >/dev/null 2>&1; then
        FOUND_IP="$(
            for iface in br0 Bridge0 Home home lan0 lan br-lan; do
                ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }'
            done | awk 'NF { print; exit }'
        )"
        [ -n "$FOUND_IP" ] && { echo "$FOUND_IP"; return 0; }

        FOUND_IP="$(
            ip -4 addr show scope global 2>/dev/null | awk '
                /inet / {
                    ip=$2; sub(/\/.*/, "", ip)
                    if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print ip; exit }
                }'
        )"
        [ -n "$FOUND_IP" ] && { echo "$FOUND_IP"; return 0; }
    fi

    if command -v ifconfig >/dev/null 2>&1; then
        FOUND_IP="$(
            ifconfig 2>/dev/null | awk '
                /inet / {
                    ip=""
                    for (i=1;i<=NF;i++) {
                        if ($i == "inet") ip=$(i+1)
                        else if ($i ~ /^addr:/) { ip=$i; sub(/^addr:/, "", ip) }
                        if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) { print ip; exit }
                    }
                }'
        )"
        [ -n "$FOUND_IP" ] && { echo "$FOUND_IP"; return 0; }
    fi

    return 1
}

create_generator() {
    echo "[4/8] Создаём минимальный генератор config..."
    cat > "$GENERATOR" <<'GEN'
#!/bin/sh
set -e

json_escape() {
    printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

url_decode_light() {
    printf "%s" "$1" \
        | sed 's/%2F/\//Ig; s/%3A/:/Ig; s/%3F/?/Ig; s/%26/\&/Ig; s/%3D/=/Ig; s/%20/ /Ig'
}

get_param() {
    KEY="$1"
    printf "%s" "$QUERY" | tr '&' '\n' | awk -F= -v k="$KEY" '$1 == k { print substr($0, length(k) + 2); exit }'
}

PROFILE_NAME="${PROFILE_NAME:-vless-out}"
VLESS_URL="${VLESS_URL:-}"
LISTEN_HOST="${LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${LISTEN_PORT:-10808}"
OUTPUT_CONFIG="${OUTPUT_CONFIG:-/opt/tmp/xray-generated.json}"

case "$VLESS_URL" in
    vless://*) ;;
    *)
        echo "ERROR: minimal edition supports only direct vless:// links."
        echo "ERROR: subscription URLs require full edition with python3."
        exit 1
        ;;
esac

NOFRAG="${VLESS_URL%%#*}"
BODY="${NOFRAG#vless://}"

case "$BODY" in
    *\?*) BASE="${BODY%%\?*}"; QUERY="${BODY#*\?}" ;;
    *) BASE="$BODY"; QUERY="" ;;
esac

UUID="${BASE%@*}"
HOSTPORT="${BASE#*@}"

if [ "$UUID" = "$BASE" ] || [ -z "$UUID" ] || [ -z "$HOSTPORT" ]; then
    echo "ERROR: invalid vless:// link."
    exit 1
fi

HOST="${HOSTPORT%:*}"
PORT="${HOSTPORT##*:}"

if [ -z "$HOST" ] || [ -z "$PORT" ] || [ "$HOST" = "$HOSTPORT" ]; then
    echo "ERROR: host or port is missing."
    exit 1
fi

TYPE="$(get_param type)"
ENCRYPTION="$(get_param encryption)"
SECURITY="$(get_param security)"
FLOW="$(get_param flow)"
SNI="$(get_param sni)"
FP="$(get_param fp)"
PBK="$(get_param pbk)"
SID="$(get_param sid)"
SPX="$(get_param spx)"
ALPN="$(get_param alpn)"
ALLOW_INSECURE="$(get_param allowInsecure)"
HEADER_TYPE="$(get_param headerType)"

[ -n "$TYPE" ] || TYPE="tcp"
[ -n "$ENCRYPTION" ] || ENCRYPTION="none"
[ -n "$SECURITY" ] || SECURITY="none"
[ -n "$SNI" ] || SNI="$HOST"
[ -n "$FP" ] || FP="chrome"
[ -n "$SPX" ] || SPX="%2F"

if [ "$TYPE" != "tcp" ]; then
    echo "ERROR: minimal edition currently supports only type=tcp."
    exit 1
fi

UUID_E="$(json_escape "$UUID")"
HOST_E="$(json_escape "$HOST")"
PROFILE_E="$(json_escape "$PROFILE_NAME")"
LISTEN_E="$(json_escape "$LISTEN_HOST")"
ENCRYPTION_E="$(json_escape "$ENCRYPTION")"
SECURITY_E="$(json_escape "$SECURITY")"
SNI_E="$(json_escape "$SNI")"
FP_E="$(json_escape "$FP")"
PBK_E="$(json_escape "$PBK")"
SID_E="$(json_escape "$SID")"
SPX_D="$(url_decode_light "$SPX")"
SPX_E="$(json_escape "$SPX_D")"
FLOW_E="$(json_escape "$FLOW")"
HEADER_TYPE_E="$(json_escape "$HEADER_TYPE")"

mkdir -p "$(dirname "$OUTPUT_CONFIG")"

{
cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "$LISTEN_E",
      "port": $LISTEN_PORT,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
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
      "tag": "$PROFILE_E",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$HOST_E",
            "port": $PORT,
            "users": [
              {
                "id": "$UUID_E",
                "encryption": "$ENCRYPTION_E"$(if [ -n "$FLOW" ]; then printf ',\n                "flow": "%s"' "$FLOW_E"; fi)
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "$TYPE",
        "security": "$SECURITY_E"
EOF

if [ "$SECURITY" = "reality" ]; then
    [ -n "$PBK" ] || { echo "ERROR: REALITY pbk is missing." >&2; exit 1; }
cat <<EOF
        ,
        "realitySettings": {
          "serverName": "$SNI_E",
          "fingerprint": "$FP_E",
          "publicKey": "$PBK_E",
          "shortId": "$SID_E",
          "spiderX": "$SPX_E"
        }
EOF
elif [ "$SECURITY" = "tls" ]; then
    ALLOW_BOOL="false"
    case "$(printf "%s" "$ALLOW_INSECURE" | tr 'A-Z' 'a-z')" in
        1|true|yes) ALLOW_BOOL="true" ;;
    esac
cat <<EOF
        ,
        "tlsSettings": {
          "serverName": "$SNI_E",
          "allowInsecure": $ALLOW_BOOL
        }
EOF
fi

if [ -n "$HEADER_TYPE" ] && [ "$HEADER_TYPE" != "none" ]; then
cat <<EOF
        ,
        "tcpSettings": {
          "header": {
            "type": "$HEADER_TYPE_E"
          }
        }
EOF
fi

cat <<EOF
      }
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
EOF
} > "$OUTPUT_CONFIG"

echo "Создан config: $OUTPUT_CONFIG"
echo "Профиль: $PROFILE_NAME"
echo "Сервер: $HOST"
echo "Порт: $PORT"
echo "Транспорт: $TYPE"
echo "Защита: $SECURITY"
echo "SOCKS5: $LISTEN_HOST:$LISTEN_PORT"
GEN

    chmod +x "$GENERATOR"
}

create_xray_init() {
    echo "[5/8] Создаём init-скрипт Xray..."
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
    echo "[6/8] Настраиваем Proxy0..."
    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Proxy0 настройте вручную."
        return 0
    fi

    if ndmc -c "interface $PROXY_IFACE" \
        && ndmc -c "interface $PROXY_IFACE proxy protocol socks5" \
        && ndmc -c "interface $PROXY_IFACE proxy socks5-udp" \
        && ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_LAN_IP $SOCKS_PORT" \
        && ndmc -c "interface $PROXY_IFACE description Xray-Failover-Minimal" \        && ndmc -c "interface $PROXY_IFACE no ip global" \
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
    echo "[7/8] Создаём failover-daemon..."
    cat > "$FAILOVER_DAEMON" <<'DAEMON'
#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
GENERATOR="/opt/bin/xray-vless-generate-config-minimal"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"

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

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then command -v xray
    elif [ -x /opt/bin/xray ]; then echo "/opt/bin/xray"
    else echo ""
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

write_history() {
    EVENT="$1"
    mkdir -p "$(dirname "$HISTORY_LOG")"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    echo "$NOW $EVENT" >> "$HISTORY_LOG"
}

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
    PROFILE_LABEL="$(profile_display_name "$PROFILE")"
    TMP_CONFIG="$TMP_DIR/xray-failover-test-$PROFILE.json"
    TMP_LOG="$TMP_DIR/xray-failover-test-$PROFILE.log"

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
    TARGET_LABEL="$(profile_display_name "$TARGET")"

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
    echo "ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET_LABEL"
    echo "======================================"

    if ! generate_profile_config "$TARGET" "$URL" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: не удалось сгенерировать config для профиля $TARGET_LABEL."
        return 1
    fi

    if ! test_xray_config "$TMP_SWITCH_CONFIG"; then
        echo "ОШИБКА: config Xray не прошёл проверку для профиля $TARGET_LABEL."
        return 1
    fi

    cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true
    cp "$TMP_SWITCH_CONFIG" "$XRAY_CONFIG"

    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    sleep 2

    if ! "$INIT_SCRIPT" start; then
        echo "ОШИБКА: Xray не запустился после переключения на профиль $TARGET_LABEL."
        rollback_config "$OLD_CONFIG"
        write_history "rollback target=$TARGET reason=xray_start_failed"
        return 1
    fi

    if ! wait_for_socks_port; then
        echo "ОШИБКА: SOCKS5-порт не поднялся."
        rollback_config "$OLD_CONFIG"
        write_history "rollback target=$TARGET reason=socks_port_down"
        return 1
    fi

    if ! test_socks_endpoint "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
        echo "ОШИБКА: основной SOCKS5 endpoint не прошёл проверку."
        rollback_config "$OLD_CONFIG"
        write_history "rollback target=$TARGET reason=socks_check_failed"
        return 1
    fi

    restart_proxy0
    echo "$TARGET" > "$ACTIVE_STORE"
    write_history "switch target=$TARGET"
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
    echo "[8/8] Создаём init-скрипт failover..."
    cat > "$FAILOVER_INIT" <<INIT
#!/bin/sh

ENABLED=yes
DESC="Xray VLESS Failover Minimal"
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
    FAILOVER_STATUS="${FAILOVER_STATUS:-/opt/bin/vless-failover-status}"
    mkdir -p "$(dirname "$FAILOVER_STATUS")"

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
echo "Xray config test:"
XRAY_BIN="$(command -v xray 2>/dev/null || echo /opt/bin/xray)"
if [ -x "$XRAY_BIN" ]; then
    "$XRAY_BIN" run -test -config /opt/etc/xray/config.json >/dev/null 2>&1 \
        || "$XRAY_BIN" test -config /opt/etc/xray/config.json
else
    echo "xray не найден."
fi

echo
echo "Проверка SOCKS5 через generate_204:"
ROUTER_IP="$(cat /opt/etc/xray/router-lan-ip 2>/dev/null || echo 127.0.0.1)"
curl -k -sS --socks5-hostname "$ROUTER_IP:10808" \
    --connect-timeout 5 \
    --max-time 10 \
    -o /dev/null \
    -w 'http_code=%{http_code} time_total=%{time_total}\n' \
    https://www.gstatic.com/generate_204 2>&1 || true

echo
echo "Последние строки failover-лога:"
tail -n 30 /opt/var/log/xray-vless-failover.log 2>/dev/null || true

echo
echo "Свободное место:"
df -h /opt 2>/dev/null || true
STATUS
    chmod +x "$FAILOVER_STATUS"
}

create_update_command() {
    FAILOVER_UPDATE_CMD="${FAILOVER_UPDATE_CMD:-/opt/bin/vless-failover-update}"
    mkdir -p "$(dirname "$FAILOVER_UPDATE_CMD")"

    cat > "$FAILOVER_UPDATE_CMD" <<'VUPDATE'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
GENERATOR="/opt/bin/xray-vless-generate-config-minimal"
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
    if command -v xray >/dev/null 2>&1; then command -v xray
    elif [ -x /opt/bin/xray ]; then echo "/opt/bin/xray"
    else echo ""
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
echo " Обновление VLESS-ссылок"
echo " Minimal edition: только прямые vless://"
echo "======================================"

while true; do
    read_tty "Новая VLESS-ссылка Основного профиля: "
    PRIMARY_VLESS="$REPLY"

    [ -n "$PRIMARY_VLESS" ] || { echo "Ссылка пустая."; continue; }

    if PROFILE_NAME="primary" VLESS_URL="$PRIMARY_VLESS" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="$SOCKS_PORT" OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" "$GENERATOR" >/dev/null \
        && test_xray_config "$TMP_PRIMARY_CONFIG" >/dev/null
    then
        break
    fi

    echo "ОШИБКА: ссылка Основного профиля некорректна. Введите заново."
done

while true; do
    echo "VLESS-ссылка Резервного профиля опциональна. Для пропуска нажмите Enter."
    read_tty "Новая VLESS-ссылка Резервного профиля: "
    BACKUP_VLESS="$REPLY"

    [ -z "$BACKUP_VLESS" ] && break

    if PROFILE_NAME="backup" VLESS_URL="$BACKUP_VLESS" LISTEN_HOST="127.0.0.1" LISTEN_PORT="19081" OUTPUT_CONFIG="$TMP_BACKUP_CONFIG" "$GENERATOR" >/dev/null \
        && test_xray_config "$TMP_BACKUP_CONFIG" >/dev/null
    then
        break
    fi

    echo "ОШИБКА: ссылка Резервного профиля некорректна."
    echo "Введите корректную ссылку или нажмите Enter, чтобы пропустить."
done

[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
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

[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start || true
rm -f "$TMP_PRIMARY_CONFIG" "$TMP_BACKUP_CONFIG" 2>/dev/null || true

echo "Готово. Активный профиль сброшен на Основной."
VUPDATE
    chmod +x "$FAILOVER_UPDATE_CMD"
}

create_switch_command() {
    FAILOVER_SWITCH_CMD="${FAILOVER_SWITCH_CMD:-/opt/bin/xray-failover-switch}"
    mkdir -p "$(dirname "$FAILOVER_SWITCH_CMD")"

    cat > "$FAILOVER_SWITCH_CMD" <<'SWITCH'
#!/bin/sh

ACTIVE_STORE="/opt/etc/xray/active-profile"
PRIMARY_STORE="/opt/etc/xray/vless-primary.url"
BACKUP_STORE="/opt/etc/xray/vless-backup.url"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
LOG="/opt/var/log/xray-vless-failover.log"

echo "Ручное переключение профиля"
echo "1 Основной"
echo "2 Резервный"
echo "0 Выход"
printf "Выберите пункт: "
IFS= read -r choice

case "$choice" in
    1)
        [ -s "$PRIMARY_STORE" ] || { echo "Основная ссылка не найдена."; exit 1; }
        echo "primary" > "$ACTIVE_STORE"
        "$FAILOVER_INIT" restart
        echo "Запрошен Основной профиль. Подробности в логе: $LOG"
        ;;
    2)
        [ -s "$BACKUP_STORE" ] || { echo "Резервная ссылка не найдена."; exit 1; }
        echo "backup" > "$ACTIVE_STORE"
        "$FAILOVER_INIT" restart
        echo "Запрошен Резервный профиль. Подробности в логе: $LOG"
        ;;
    0)
        exit 0
        ;;
    *)
        echo "Неверный пункт."
        exit 1
        ;;
esac
SWITCH
    chmod +x "$FAILOVER_SWITCH_CMD"
}

create_menu_command() {
    FAILOVER_MENU_CMD="${FAILOVER_MENU_CMD:-/opt/bin/failover}"
    mkdir -p "$(dirname "$FAILOVER_MENU_CMD")"

    cat > "$FAILOVER_MENU_CMD" <<'MENU'
#!/bin/sh

LOGFILE="/opt/var/log/xray-vless-failover.log"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"

pause() {
    echo
    printf "Нажмите Enter для возврата в меню..."
    IFS= read -r _
}

show_menu() {
    clear
    echo "======================================"
    echo " Xray VLESS Failover Minimal"
    echo "======================================"
    echo "1 Обновление VLESS-ссылок"
    echo "2 Лог в реальном времени"
    echo "3 Диагностика"
    echo "4 История переключений"
    echo "5 Ручное переключение профиля"
    echo "0 Выход"
    echo "======================================"
    printf "Выберите пункт: "
}

while true; do
    show_menu
    IFS= read -r choice

    case "$choice" in
        1)
            /opt/bin/vless-failover-update
            pause
            ;;
        2)
            if [ -f "$LOGFILE" ]; then
                tail -f "$LOGFILE"
            else
                echo "Лог не найден: $LOGFILE"
                pause
            fi
            ;;
        3)
            /opt/bin/vless-failover-status
            pause
            ;;
        4)
            if [ -f "$HISTORY_LOG" ]; then
                tail -n 80 "$HISTORY_LOG"
            else
                echo "История переключений пока пуста."
            fi
            pause
            ;;
        5)
            /opt/bin/xray-failover-switch
            pause
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Неверный пункт."
            pause
            ;;
    esac
done
MENU
    chmod +x "$FAILOVER_MENU_CMD"
}

echo
echo "======================================"
echo " Xray VLESS Failover Minimal"
echo " Для встроенной памяти Entware"
echo "======================================"
echo "Интервал проверки: $CHECK_INTERVAL секунд"
echo "Ошибок перед переходом на Резервный профиль: $FAILOVER_FAILURES_REQUIRED"
echo "Успешных проверок перед возвратом на Основной профиль: $RECOVERY_SUCCESSES_REQUIRED"
echo "Ограничение: только прямые vless:// ссылки, без подписок."
echo

ensure_packages

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден после установки."; exit 1; }

mkdir -p "$XRAY_DIR" "$TMP_DIR" /opt/var/run /opt/var/log /opt/etc/init.d /opt/bin

if [ -x "$FAILOVER_INIT" ]; then
    echo "Останавливаем старый failover-daemon перед установкой..."
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

echo "[2/8] Определяем LAN-IP роутера..."
ROUTER_LAN_IP="$(detect_router_ip | head -n 1)"

if [ -n "$ROUTER_LAN_IP" ]; then
    echo "Автоматически найден LAN-IP: $ROUTER_LAN_IP"
    read_tty "Нажмите Enter, чтобы использовать его, или введите другой LAN-IP: "
    [ -n "$REPLY" ] && ROUTER_LAN_IP="$REPLY"
else
    read_tty "Введите LAN-IP роутера, например 192.168.1.1: "
    ROUTER_LAN_IP="$REPLY"
fi

[ -n "$ROUTER_LAN_IP" ] || { echo "ОШИБКА: LAN-IP роутера пустой."; exit 1; }
printf "%s\n" "$ROUTER_LAN_IP" > "$ROUTER_IP_STORE"

echo "LAN-IP роутера: $ROUTER_LAN_IP"
echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"

echo "[3/8] Готовим VLESS-ссылки..."
if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"
    [ -s "$BACKUP_STORE" ] && BACKUP_VLESS="$(cat "$BACKUP_STORE")" || BACKUP_VLESS=""
else
    read_tty "VLESS-ссылка Основного профиля: "
    PRIMARY_VLESS="$REPLY"
    [ -n "$PRIMARY_VLESS" ] || { echo "ОШИБКА: Primary VLESS-ссылка пустая."; exit 1; }

    echo "VLESS-ссылка Резервного профиля опциональна. Для пропуска нажмите Enter."
    read_tty "VLESS-ссылка Резервного профиля: "
    BACKUP_VLESS="$REPLY"
fi

create_generator
create_xray_init
create_failover_daemon
create_failover_init
create_status_command
create_update_command
create_switch_command
create_menu_command

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

safe_cleanup_low_space

echo
echo "======================================"
echo " ГОТОВО"
echo "======================================"
echo "Minimal edition установлена."
echo "Xray config: $XRAY_CONFIG"
echo "VLESS Основного профиля: $PRIMARY_STORE"
echo "VLESS Резервного профиля: $BACKUP_STORE"
echo "Файл активного профиля: $ACTIVE_STORE"
echo "SOCKS5: $ROUTER_LAN_IP:$SOCKS_PORT"
echo "Proxy: $PROXY_IFACE"
echo "Proxy0 настроен без глобального приоритета: используется только для правил/доменной маршрутизации."
echo "Failover log: /opt/var/log/xray-vless-failover.log"
echo
echo "Команды:"
echo "failover"
echo "vless-failover-status"
echo "vless-failover-update"
echo "$FAILOVER_INIT status|restart|stop|start"
echo
echo "Свободное место:"
df -h /opt 2>/dev/null || true
