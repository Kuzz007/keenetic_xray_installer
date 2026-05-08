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
SUBSCRIPTION_UPDATE_CMD="/opt/bin/vless-subscription-update"
SUBSCRIPTION_AUTO_CMD="/opt/bin/vless-subscription-auto-update"
FAILOVER_UPDATE_CMD="/opt/bin/vless-failover-update"
FAILOVER_UPDATE_ALIAS="/opt/bin/xray-failover-update"

FAILOVER_INSTALLER_UPDATE_CMD="/opt/bin/xray-failover-installer-update"
FAILOVER_INSTALLER_UPDATE_ALIAS="/opt/bin/failover-installer-update"
REPO_FAILOVER_RAW_URL="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover.sh"

PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
PRIMARY_SOURCE="$XRAY_DIR/vless-primary.source"
BACKUP_SOURCE="$XRAY_DIR/vless-backup.source"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
RESOLVER="/opt/bin/xray-vless-resolve-input"
LOCK_DIR="/opt/var/run/xray-failover.lock"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"

CHECK_INTERVAL="10"
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
CHECK_URL="https://www.gstatic.com/generate_204"
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
IP_CHECK_URL="https://api.ipify.org"
DNS_CHECK_URL="https://cp.cloudflare.com/generate_204"
FAILOVER_CONF="$XRAY_DIR/failover.conf"
[ -s "$FAILOVER_CONF" ] && . "$FAILOVER_CONF"

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

acquire_lock() {
    LOCK_DIR="${LOCK_DIR:-/opt/var/run/xray-failover.lock}"
    mkdir -p "$(dirname "$LOCK_DIR")"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return 0
    fi
    echo "ОШИБКА: уже выполняется другая операция failover. Lock: $LOCK_DIR"
    return 1
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
    command -v crond >/dev/null 2>&1 || NEED_UPDATE="1"

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


    if ! command -v crond >/dev/null 2>&1; then
        echo "Устанавливаем cron/cronie для автообновления подписок..."
        opkg install cron >/dev/null 2>&1 \
            || opkg install cronie >/dev/null 2>&1 \
            || opkg install busybox-cron >/dev/null 2>&1 \
            || echo "ПРЕДУПРЕЖДЕНИЕ: cron/cronie не удалось установить. Автообновление подписок можно будет включить после ручной установки cron."
    else
        echo "crond найден."
    fi

    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log 2>/dev/null || true
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true

    if command -v crond >/dev/null 2>&1; then
        if ! ps 2>/dev/null | grep -i '[c]rond' >/dev/null 2>&1; then
            echo "Запускаем crond..."
            if [ -x /opt/etc/init.d/S10cron ]; then
                /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
            elif [ -x /opt/etc/init.d/S10crond ]; then
                /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
            else
                crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
            fi
        else
            echo "crond уже запущен."
        fi
    fi

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


create_resolver() {
    echo "Создаём resolver VLESS/подписок..."

    RESOLVER="${RESOLVER:-/opt/bin/xray-vless-resolve-input}"
    mkdir -p "$(dirname "$RESOLVER")"

    cat > "$RESOLVER" <<'RESOLVE'
#!/bin/sh
set -e

MODE="${1:-interactive}"
SOURCE_VALUE="${2:-}"
PROFILE_LABEL="${3:-профиль}"

if [ -z "$SOURCE_VALUE" ]; then
    echo "ОШИБКА: пустая ссылка." >&2
    exit 1
fi

python3 - "$MODE" "$SOURCE_VALUE" "$PROFILE_LABEL" <<'PYRESOLVER'
import base64
import re
import sys
import urllib.parse
import urllib.request

mode, value, profile_label = sys.argv[1], sys.argv[2].strip(), sys.argv[3]

def decode_variants(data):
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

def extract_vless_links(text):
    links = []
    for m in re.finditer(r"vless://[^\s\r\n<>\"']+", text):
        link = m.group(0).strip()
        if link not in links:
            links.append(link)
    return links

def label_for(link, idx):
    try:
        u = urllib.parse.urlparse(link)
        frag = urllib.parse.unquote(u.fragment or "").strip()
        host = u.hostname or "unknown-host"
        port = u.port or 443
        if frag:
            return f"{idx}. {frag} ({host}:{port})"
        return f"{idx}. {host}:{port}"
    except Exception:
        return f"{idx}. VLESS profile"

def download_subscription(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Keenetic-Xray-Failover/1.0", "Accept": "text/plain,*/*"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read()

if value.startswith("vless://"):
    print(value)
    raise SystemExit(0)

parsed = urllib.parse.urlparse(value)
if parsed.scheme not in ("http", "https"):
    raise SystemExit("ОШИБКА: нужен формат vless:// или http(s) ссылка подписки")

try:
    payload = download_subscription(value)
except Exception as exc:
    raise SystemExit(f"ОШИБКА: не удалось скачать подписку: {exc}")

links = []
for text in decode_variants(payload):
    for link in extract_vless_links(text):
        if link not in links:
            links.append(link)

if not links:
    raise SystemExit("ОШИБКА: в подписке не найдено vless:// ссылок")

if len(links) == 1 or mode != "interactive":
    print(links[0])
    raise SystemExit(0)

print(f"В подписке для профиля {profile_label} найдено VLESS-профилей: {len(links)}", file=sys.stderr)
for i, link in enumerate(links, 1):
    print(label_for(link, i), file=sys.stderr)
while True:
    try:
        choice = input("Выберите номер профиля: ").strip()
    except EOFError:
        print(links[0])
        raise SystemExit(0)
    if choice.isdigit() and 1 <= int(choice) <= len(links):
        print(links[int(choice)-1])
        raise SystemExit(0)
    print("Введите корректный номер профиля.", file=sys.stderr)
PYRESOLVER
RESOLVE

    chmod +x "$RESOLVER"
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
        && ndmc -c "interface $PROXY_IFACE no ip global" \
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
PRIMARY_SOURCE="$XRAY_DIR/vless-primary.source"
BACKUP_SOURCE="$XRAY_DIR/vless-backup.source"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
RESOLVER="/opt/bin/xray-vless-resolve-input"
LOCK_DIR="/opt/var/run/xray-failover.lock"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"

CHECK_INTERVAL="10"
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
CHECK_URL="https://www.gstatic.com/generate_204"
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
IP_CHECK_URL="https://api.ipify.org"
DNS_CHECK_URL="https://cp.cloudflare.com/generate_204"

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

write_history() {
    EVENT="$1"
    DETAIL="$2"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    mkdir -p "$(dirname "$HISTORY_LOG")" 2>/dev/null || true
    echo "$NOW $EVENT $DETAIL" >> "$HISTORY_LOG"
}

profile_external_ip() {
    HOST="$1"
    PORT="$2"
    curl -k -sS \
        --socks5-hostname "$HOST:$PORT" \
        --connect-timeout 5 \
        --max-time 10 \
        "$IP_CHECK_URL" 2>/dev/null || true
}

test_https_healthcheck_through_socks() {
    HOST="$1"
    PORT="$2"
    HTTP_CODE="$(curl -k -sS \
        --socks5-hostname "$HOST:$PORT" \
        --connect-timeout 5 \
        --max-time 10 \
        -o /dev/null \
        -w '%{http_code}' \
        "$DNS_CHECK_URL" 2>/dev/null || true)"
    [ "$HTTP_CODE" = "204" ]
}

test_socks_endpoint() {
    HOST="$1"
    PORT="$2"
    OK_COUNT="0"

    for URL in $CHECK_URLS; do
        RESULT="$(curl -k -sS \
            --socks5-hostname "$HOST:$PORT" \
            --connect-timeout 5 \
            --max-time 10 \
            -o /dev/null \
            -w 'url=%{url_effective} http_code=%{http_code} time_total=%{time_total}' \
            "$URL" 2>/dev/null || true)"

        echo "$RESULT"
        HTTP_CODE="$(echo "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"

        case "$HTTP_CODE" in
            204|200|301|302)
                OK_COUNT="$((OK_COUNT + 1))"
                ;;
        esac
    done

    if [ "$OK_COUNT" -gt 0 ]; then
        EXT_IP="$(profile_external_ip "$HOST" "$PORT")"
        if [ -n "$EXT_IP" ]; then
            echo "Внешний IP через туннель: $EXT_IP"
        else
            echo "Внешний IP через туннель: не удалось определить"
        fi

        if test_https_healthcheck_through_socks "$HOST" "$PORT"; then
            echo "Дополнительная HTTPS-проверка через туннель: OK"
        else
            echo "Дополнительная HTTPS-проверка через туннель: нестабильна"
        fi
        return 0
    fi

    return 1
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
        write_history "rollback" "$TARGET_LABEL socks_check_failed"
        rollback_config "$OLD_CONFIG"
        return 1
    fi

    echo "[6/6] Перезапускаем Proxy0..."
    restart_proxy0

    echo "$TARGET" > "$ACTIVE_STORE"
    sleep 5
    write_history "switch" "$TARGET_LABEL"
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

XRAY_CONFIG="/opt/etc/xray/config.json"
ACTIVE_STORE="/opt/etc/xray/active-profile"
ROUTER_IP_STORE="/opt/etc/xray/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
RESOLVER="/opt/bin/xray-vless-resolve-input"
LOCK_DIR="/opt/var/run/xray-failover.lock"
LOGFILE="/opt/var/log/xray-vless-failover.log"
SOCKS_PORT="10808"
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
IP_CHECK_URL="https://api.ipify.org"
DNS_CHECK_URL="https://cp.cloudflare.com/generate_204"

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

echo "Активный профиль:"
ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
profile_display_name "$ACTIVE"

echo
echo "Статус Xray:"
/opt/etc/init.d/S24xray status

echo
echo "Статус failover:"
/opt/etc/init.d/S25xray-failover status

echo
echo "Версия Xray:"
XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -n 1 || echo "xray не найден"

echo
echo "Проверка config.json:"
if [ -n "$XRAY_BIN" ] && [ -s "$XRAY_CONFIG" ]; then
    if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || "$XRAY_BIN" test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        echo "config.json: OK"
    else
        echo "config.json: ОШИБКА"
    fi
else
    echo "config.json или xray не найден"
fi

echo
echo "SOCKS5 port:"
netstat -lntp 2>/dev/null | grep "$SOCKS_PORT" || netstat -lnt 2>/dev/null | grep "$SOCKS_PORT" || true

if [ -s "$ROUTER_IP_STORE" ] && command -v curl >/dev/null 2>&1; then
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
    echo
    echo "Health-check через SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT:"
    OK="0"
    for URL in $CHECK_URLS; do
        RESULT="$(curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w 'url=%{url_effective} http_code=%{http_code} time_total=%{time_total}' "$URL" 2>&1)" && ST="0" || ST="$?"
        echo "$RESULT"
        CODE="$(printf "%s\n" "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"
        [ "$ST" = "0" ] && [ "$CODE" = "204" ] && OK="1"
    done
    [ "$OK" = "1" ] && echo "Health-check: OK" || echo "Health-check: ОШИБКА"
    echo
    echo "Внешний IP через туннель:"
    curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 "$IP_CHECK_URL" 2>/dev/null || echo "не удалось получить"
    echo
    echo "Дополнительная HTTPS-проверка через туннель:"
    HTTP_CODE="$(curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$DNS_CHECK_URL" 2>/dev/null || true)"
    [ "$HTTP_CODE" = "204" ] && echo "OK" || echo "нестабильна"
fi

echo
echo "Proxy0:"
ndmc -c "show running-config" 2>/dev/null | grep -A12 -i "interface Proxy0" || true

echo
echo "История переключений:"
tail -n 20 "$HISTORY_LOG" 2>/dev/null || echo "История пока пустая."

echo
echo "Последние строки failover-лога:"
tail -n 30 "$LOGFILE" 2>/dev/null || true
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
LOCK_DIR="/opt/var/run/xray-failover.lock"
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

acquire_lock

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
SUBSCRIPTION_UPDATE_CMD="/opt/bin/vless-subscription-update"
SUBSCRIPTION_AUTO_CMD="/opt/bin/vless-subscription-auto-update"
XRAY_CORE_UPDATE_CMD="/opt/bin/xray-core-update"
GENERATOR="/opt/bin/xray-vless-generate-config"
RESOLVER="/opt/bin/xray-vless-resolve-input"
XRAY_INIT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
XRAY_CONFIG="/opt/etc/xray/config.json"
XRAY_DIR="/opt/etc/xray"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
PRIMARY_SOURCE="$XRAY_DIR/vless-primary.source"
BACKUP_SOURCE="$XRAY_DIR/vless-backup.source"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
FAILOVER_CONF="$XRAY_DIR/failover.conf"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
RESOLVER="/opt/bin/xray-vless-resolve-input"
LOCK_DIR="/opt/var/run/xray-failover.lock"
LOCK_DIR="/opt/var/run/xray-failover.lock"
TMP_DIR="/opt/tmp"
SOCKS_PORT="10808"
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
IP_CHECK_URL="https://api.ipify.org"
DNS_CHECK_URL="https://cp.cloudflare.com/generate_204"
LOGFILE="/opt/var/log/xray-vless-failover.log"
LATEST_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

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

pause_menu() { echo; printf "Нажмите Enter для возврата в меню..."; IFS= read -r _; }

acquire_lock() {
    LOCK_DIR="${LOCK_DIR:-/opt/var/run/xray-failover.lock}"
    mkdir -p "$(dirname "$LOCK_DIR")"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return 0
    fi
    echo "ОШИБКА: уже выполняется другая операция failover. Lock: $LOCK_DIR"
    return 1
}

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; trap - EXIT INT TERM; }

write_history() {
    EVENT="$1"; DETAIL="$2"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    mkdir -p "$(dirname "$HISTORY_LOG")" 2>/dev/null || true
    echo "$NOW $EVENT $DETAIL" >> "$HISTORY_LOG"
}

test_xray_config() {
    XRAY_BIN="$(get_xray_bin)"
    [ -n "$XRAY_BIN" ] || return 1
    "$XRAY_BIN" run -test -config "$1" >/dev/null 2>&1 || "$XRAY_BIN" test -config "$1" >/dev/null 2>&1
}

show_header() {
    clear 2>/dev/null || true
    echo "======================================"
    echo " Xray VLESS Failover"
    echo "======================================"
    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
    echo "Активный профиль: $(profile_display_name "$ACTIVE")"
    [ -s "$ROUTER_IP_STORE" ] && echo "SOCKS5: $(cat "$ROUTER_IP_STORE"):$SOCKS_PORT"
    echo
}

resolve_saved_profile() {
    PROFILE="$1"; STORE="$2"
    LABEL="$(profile_display_name "$PROFILE")"
    [ -s "$STORE" ] || return 1
    INPUT="$(cat "$STORE")"
    if [ -x "$RESOLVER" ]; then
        "$RESOLVER" noninteractive "$INPUT" "$LABEL"
    else
        echo "$INPUT"
    fi
}

extract_server_port() {
    INPUT="$1"
    python3 - "$INPUT" <<'PY'
import sys, urllib.parse
u=urllib.parse.urlparse(sys.argv[1].strip())
if u.scheme != 'vless' or not u.hostname:
    raise SystemExit(1)
print(f"{u.hostname} {u.port or 443}")
PY
}

check_tcp_server() {
    PROFILE="$1"; STORE="$2"
    LABEL="$(profile_display_name "$PROFILE")"
    echo "TCP-проверка сервера профиля $LABEL:"
    VLESS="$(resolve_saved_profile "$PROFILE" "$STORE" 2>/dev/null)" || { echo "  ссылка не задана или не резолвится"; return 1; }
    HP="$(extract_server_port "$VLESS" 2>/dev/null)" || { echo "  не удалось извлечь host/port"; return 1; }
    HOST="$(echo "$HP" | awk '{print $1}')"
    PORT="$(echo "$HP" | awk '{print $2}')"
    python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
host=sys.argv[1]; port=int(sys.argv[2])
try:
    s=socket.create_connection((host, port), timeout=5)
    s.close()
    print(f"  OK: {host}:{port} доступен")
except Exception as e:
    print(f"  ОШИБКА: {host}:{port} недоступен: {e}")
    raise SystemExit(1)
PY
}

curl_socks_check() {
    HOST="$1"; PORT="$2"; OK="0"
    for URL in $CHECK_URLS; do
        RESULT="$(curl -k -sS --socks5-hostname "$HOST:$PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w 'url=%{url_effective} http_code=%{http_code} time_total=%{time_total}' "$URL" 2>&1)" && ST="0" || ST="$?"
        echo "$RESULT"
        CODE="$(printf "%s\n" "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"
        [ "$ST" = "0" ] && [ "$CODE" = "204" ] && OK="1"
    done
    [ "$OK" = "1" ]
}

show_external_ip() {
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 127.0.0.1)"
    echo "Внешний IP через активный профиль:"
    curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 "$IP_CHECK_URL" 2>/dev/null || echo "не удалось получить"
    echo
}

check_dns_tunnel() {
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 127.0.0.1)"
    echo "Дополнительная HTTPS-проверка через туннель:"
    HTTP_CODE="$(curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$DNS_CHECK_URL" 2>/dev/null || true)"
    if [ "$HTTP_CODE" = "204" ]; then
        echo "OK"
    else
        echo "нестабильна"
    fi
}

manual_switch() {
    acquire_lock || { pause_menu; return; }
    echo "Выберите профиль для ручного переключения:"
    echo "1 Основной"
    echo "2 Резервный"
    echo "0 Назад"
    printf "Ваш выбор: "; IFS= read -r CH
    case "$CH" in
        1) TARGET="primary"; STORE="$PRIMARY_STORE" ;;
        2) TARGET="backup"; STORE="$BACKUP_STORE" ;;
        0) release_lock; return ;;
        *) echo "Неверный пункт."; release_lock; pause_menu; return ;;
    esac
    LABEL="$(profile_display_name "$TARGET")"
    [ -s "$STORE" ] || { echo "Ссылка профиля $LABEL не задана."; release_lock; pause_menu; return; }
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 127.0.0.1)"
    TMP_CONFIG="$TMP_DIR/xray-manual-$TARGET.json"
    OLD_CONFIG="$TMP_DIR/xray-manual-before.json"
    VLESS="$(resolve_saved_profile "$TARGET" "$STORE")" || { echo "Не удалось получить ссылку профиля $LABEL."; release_lock; pause_menu; return; }
    echo "Генерируем config профиля $LABEL..."
    PROFILE_NAME="$TARGET" VLESS_URL="$VLESS" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="$SOCKS_PORT" OUTPUT_CONFIG="$TMP_CONFIG" "$GENERATOR" || { release_lock; pause_menu; return; }
    test_xray_config "$TMP_CONFIG" || { echo "Config профиля $LABEL не прошёл проверку."; release_lock; pause_menu; return; }
    cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
    cp "$TMP_CONFIG" "$XRAY_CONFIG"
    "$XRAY_INIT" stop >/dev/null 2>&1 || true
    sleep 1
    if ! "$XRAY_INIT" start; then
        echo "Xray не запустился. Откат."
        [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
        "$XRAY_INIT" start >/dev/null 2>&1 || true
        [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
        release_lock; pause_menu; return
    fi
    sleep 2
    if ! curl_socks_check "$ROUTER_LAN_IP" "$SOCKS_PORT"; then
        echo "SOCKS5 проверка не прошла. Откат."
        "$XRAY_INIT" stop >/dev/null 2>&1 || true
        [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
        "$XRAY_INIT" start >/dev/null 2>&1 || true
        [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
        release_lock; pause_menu; return
    fi
    echo "$TARGET" > "$ACTIVE_STORE"
    write_history "manual_switch" "$LABEL"
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    echo "Ручное переключение на $LABEL выполнено."
    release_lock
    pause_menu
}

show_history() {
    echo "История переключений: $HISTORY_LOG"
    echo
    tail -n 80 "$HISTORY_LOG" 2>/dev/null || echo "История пока пустая."
    pause_menu
}

settings_menu() {
    mkdir -p "$XRAY_DIR"
    [ -s "$FAILOVER_CONF" ] || cat > "$FAILOVER_CONF" <<CONF
CHECK_INTERVAL=10
FAILOVER_FAILURES_REQUIRED=2
RECOVERY_SUCCESSES_REQUIRED=2
CHECK_URL=https://www.gstatic.com/generate_204
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
LOG_MAX_SIZE=1048576
CONF
    echo "Текущие настройки:"
    cat "$FAILOVER_CONF"
    echo
    echo "1 Изменить CHECK_INTERVAL"
    echo "2 Изменить FAILOVER_FAILURES_REQUIRED"
    echo "3 Изменить RECOVERY_SUCCESSES_REQUIRED"
    echo "4 Изменить CHECK_URLS"
    echo "0 Назад"
    printf "Ваш выбор: "; IFS= read -r CH
    case "$CH" in
        1) KEY="CHECK_INTERVAL" ;;
        2) KEY="FAILOVER_FAILURES_REQUIRED" ;;
        3) KEY="RECOVERY_SUCCESSES_REQUIRED" ;;
        4) KEY="CHECK_URLS" ;;
        0) return ;;
        *) echo "Неверный пункт."; pause_menu; return ;;
    esac
    printf "Новое значение для %s: " "$KEY"; IFS= read -r VAL
    [ -n "$VAL" ] || { echo "Пустое значение не принято."; pause_menu; return; }
    grep -v "^$KEY=" "$FAILOVER_CONF" > "$FAILOVER_CONF.tmp" 2>/dev/null || true
    echo "$KEY=\"$VAL\"" >> "$FAILOVER_CONF.tmp"
    mv "$FAILOVER_CONF.tmp" "$FAILOVER_CONF"
    chmod 600 "$FAILOVER_CONF"
    echo "Сохранено. Перезапустите failover-daemon для применения."
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" restart || true
    pause_menu
}

check_xray_version() {
    XRAY_BIN="$(get_xray_bin)"
    echo "Текущая версия:"
    [ -n "$XRAY_BIN" ] && "$XRAY_BIN" version 2>/dev/null | head -n 1 || echo "xray не найден"
    echo
    echo "Последний stable release Xray-core на GitHub:"
    if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
        curl -fsSL -H "User-Agent: xray-version-check" "$LATEST_API" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("tag_name", "unknown"), d.get("name", ""))' || echo "не удалось получить версию"
    else
        echo "нужны curl и python3"
    fi
    pause_menu
}

uninstall_failover() {
    echo "Будут удалены failover-компоненты. Xray можно оставить."
    printf "Продолжить? [y/N]: "; IFS= read -r A
    case "$A" in y|Y|yes|YES|д|Д|да|ДА) ;; *) echo "Отменено."; pause_menu; return ;; esac
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
    rm -f /opt/bin/failover /opt/bin/vless-failover-update /opt/bin/xray-failover-update /opt/bin/xray-core-update
    rm -f /opt/bin/xray-vless-failover-daemon /opt/bin/xray-vless-generate-config /opt/bin/xray-vless-resolve-input
    rm -f /opt/etc/init.d/S25xray-failover
    rm -rf "$LOCK_DIR"
    echo "Failover-компоненты удалены. /opt/etc/xray сохранён."
    pause_menu
}

show_realtime_log() {
    echo "Лог failover в реальном времени: $LOGFILE"
    echo "Для выхода нажмите Ctrl+C."
    echo
    [ -f "$LOGFILE" ] && tail -f "$LOGFILE" || { echo "Лог пока не найден: $LOGFILE"; pause_menu; }
}

run_diagnostics() {
    echo "======================================"
    echo " Диагностика Xray VLESS Failover"
    echo "======================================"
    [ -x "$STATUS_CMD" ] && "$STATUS_CMD" || true
    echo
    show_external_ip
    check_dns_tunnel
    echo
    check_tcp_server primary "$PRIMARY_STORE" || true
    check_tcp_server backup "$BACKUP_STORE" || true
    echo
    echo "Health-check несколькими URL:"
    ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 127.0.0.1)"
    curl_socks_check "$ROUTER_LAN_IP" "$SOCKS_PORT" && echo "Health-check: OK" || echo "Health-check: ОШИБКА"
    echo
    echo "Последние строки лога:"
    tail -n 30 "$LOGFILE" 2>/dev/null || true
    pause_menu
}

while true; do
    show_header
    echo "1 Обновление VLESS/подписок вручную"
    echo "2 Обновить подписки"
    echo "3 Автообновление подписок"
    echo "4 Лог в реальном времени"
    echo "5 Диагностика"
    echo "6 Обновление ядра Xray"
    echo "7 Настройки failover"
    echo "8 История переключений"
    echo "9 Ручное переключение профиля"
    echo "10 Проверить версию Xray"
    echo "11 Удаление / деинсталляция"
    echo "0 Выход"
    echo
    printf "Выберите пункт: "
    IFS= read -r MENU_CHOICE
    case "$MENU_CHOICE" in
        1)
            if [ -x "$UPDATE_CMD" ]; then
                "$UPDATE_CMD"
            else
                echo "Команда обновления не найдена: $UPDATE_CMD"
                pause_menu
            fi
            ;;
        2)
            if [ -x "$SUBSCRIPTION_UPDATE_CMD" ]; then
                "$SUBSCRIPTION_UPDATE_CMD"
            else
                echo "Команда обновления подписок не найдена: $SUBSCRIPTION_UPDATE_CMD"
                pause_menu
            fi
            ;;
        3)
            SUBSCRIPTION_AUTO_CMD="${SUBSCRIPTION_AUTO_CMD:-/opt/bin/vless-subscription-auto-update}"
            if [ -x "$SUBSCRIPTION_AUTO_CMD" ]; then
                "$SUBSCRIPTION_AUTO_CMD"
            else
                echo "Команда автообновления подписок не найдена: $SUBSCRIPTION_AUTO_CMD"
                pause_menu
            fi
            ;;
        4)
            show_realtime_log
            ;;
        5)
            run_diagnostics
            ;;
        6)
            if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
                "$XRAY_CORE_UPDATE_CMD"
            else
                echo "Команда обновления ядра не найдена: $XRAY_CORE_UPDATE_CMD"
                pause_menu
            fi
            ;;
        7)
            settings_menu
            ;;
        8)
            show_history
            ;;
        9)
            manual_switch
            ;;
        10)
            check_xray_version
            ;;
        11)
            uninstall_failover
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Неизвестный пункт: $MENU_CHOICE"
            pause_menu
            ;;
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
PRIMARY_SOURCE="$XRAY_DIR/vless-primary.source"
BACKUP_SOURCE="$XRAY_DIR/vless-backup.source"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
RESOLVER="/opt/bin/xray-vless-resolve-input"
LOCK_DIR="/opt/var/run/xray-failover.lock"
GENERATOR="/opt/bin/xray-vless-generate-config"
RESOLVER="/opt/bin/xray-vless-resolve-input"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
SOCKS_PORT="10808"
TMP_DIR="/opt/tmp"
LOCK_DIR="/opt/var/run/xray-failover.lock"

acquire_lock() {
    LOCK_DIR="${LOCK_DIR:-/opt/var/run/xray-failover.lock}"
    mkdir -p "$(dirname "$LOCK_DIR")"

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return 0
    fi
    echo "ОШИБКА: уже выполняется другая операция failover. Lock: $LOCK_DIR"
    return 1
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

    RESOLVED_VALUE="$SOURCE_VALUE"
    if [ -x "${RESOLVER:-/opt/bin/xray-vless-resolve-input}" ]; then
        if ! RESOLVED_VALUE="$(${RESOLVER:-/opt/bin/xray-vless-resolve-input} interactive "$SOURCE_VALUE" "$LABEL")"; then
            return 1
        fi
    fi

    PROFILE_NAME="$PROFILE"     VLESS_URL="$RESOLVED_VALUE"     LISTEN_HOST="$HOST"     LISTEN_PORT="$PORT"     OUTPUT_CONFIG="$OUT_CONFIG"     "$GENERATOR"

    PROFILE_RESOLVED_RESULT="$RESOLVED_VALUE"
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
            PROFILE_SOURCE_RESULT="$CANDIDATE"
            PROFILE_INPUT_RESULT="${PROFILE_RESOLVED_RESULT:-$CANDIDATE}"
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
            PROFILE_SOURCE_RESULT=""
            PROFILE_INPUT_RESULT=""
            return 0
        fi

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_SOURCE_RESULT="$CANDIDATE"
            PROFILE_INPUT_RESULT="${PROFILE_RESOLVED_RESULT:-$CANDIDATE}"
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

acquire_lock
mkdir -p "$XRAY_DIR" "$TMP_DIR"

ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
PRIMARY_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
PRIMARY_VLESS="$PROFILE_INPUT_RESULT"

ask_optional_profile_input "backup" "127.0.0.1" "19081" "$TMP_BACKUP_CONFIG"
BACKUP_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
BACKUP_VLESS="$PROFILE_INPUT_RESULT"

if [ -x "$FAILOVER_INIT" ]; then
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"
printf "%s\n" "${PRIMARY_SOURCE_VALUE:-$PRIMARY_VLESS}" > "$PRIMARY_SOURCE"
chmod 600 "$PRIMARY_SOURCE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
    printf "%s\n" "${BACKUP_SOURCE_VALUE:-$BACKUP_VLESS}" > "$BACKUP_SOURCE"
    chmod 600 "$BACKUP_SOURCE"
else
    rm -f "$BACKUP_STORE" "$BACKUP_SOURCE"
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

create_subscription_update_command() {
    echo "[10/10] Создаём команду обновления подписок..."

    cat > "$SUBSCRIPTION_UPDATE_CMD" <<'SUBUPDATE'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
PRIMARY_SOURCE="$XRAY_DIR/vless-primary.source"
BACKUP_SOURCE="$XRAY_DIR/vless-backup.source"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
GENERATOR="/opt/bin/xray-vless-generate-config"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
LOCK_DIR="/opt/var/run/xray-failover.lock"
TMP_DIR="/opt/tmp"
SOCKS_PORT="10808"

acquire_lock() {
    LOCK_DIR="${LOCK_DIR:-/opt/var/run/xray-failover.lock}"
    mkdir -p "$(dirname "$LOCK_DIR")"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid"
        trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM
        return 0
    fi
    echo "ОШИБКА: уже выполняется другая операция failover. Lock: $LOCK_DIR"
    return 1
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

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

resolve_subscription_update() {
    SOURCE_VALUE="$1"
    PREVIOUS_VALUE="$2"
    LABEL="$3"

    python3 - "$SOURCE_VALUE" "$PREVIOUS_VALUE" "$LABEL" <<'PY'
import base64
import re
import sys
import urllib.parse
import urllib.request

source, previous, label = sys.argv[1].strip(), sys.argv[2].strip(), sys.argv[3]

def decode_variants(data):
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

def extract_vless_links(text):
    links = []
    for m in re.finditer(r"vless://[^\s\r\n<>\"']+", text):
        link = m.group(0).strip()
        if link not in links:
            links.append(link)
    return links

def parse(link):
    try:
        u = urllib.parse.urlparse(link)
        return {
            "link": link,
            "uuid": urllib.parse.unquote(u.username or ""),
            "host": u.hostname or "",
            "port": str(u.port or 443),
            "frag": urllib.parse.unquote(u.fragment or "").strip(),
        }
    except Exception:
        return {"link": link, "uuid": "", "host": "", "port": "", "frag": ""}

def download(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Keenetic-Xray-Failover/1.0", "Accept": "text/plain,*/*"})
    with urllib.request.urlopen(req, timeout=25) as response:
        return response.read()

if source.startswith("vless://"):
    print(source)
    raise SystemExit(0)

u = urllib.parse.urlparse(source)
if u.scheme not in ("http", "https"):
    raise SystemExit(f"ОШИБКА: источник {label} не является vless:// или http(s)-подпиской")

payload = download(source)
links = []
for text in decode_variants(payload):
    for link in extract_vless_links(text):
        if link not in links:
            links.append(link)

if not links:
    raise SystemExit(f"ОШИБКА: в подписке {label} не найдено vless:// ссылок")

prev = parse(previous) if previous else None
best = links[0]
best_score = -1

for link in links:
    cur = parse(link)
    score = 0
    if previous and link == previous:
        score += 1000
    if prev:
        if cur["uuid"] and cur["uuid"] == prev["uuid"]:
            score += 200
        if cur["frag"] and cur["frag"] == prev["frag"]:
            score += 150
        if cur["host"] and cur["host"] == prev["host"] and cur["port"] == prev["port"]:
            score += 100
    if score > best_score:
        best_score = score
        best = link

print(best)
PY
}

update_one_profile() {
    PROFILE="$1"
    SOURCE_FILE="$2"
    STORE_FILE="$3"
    HOST="$4"
    PORT="$5"
    OUT_CONFIG="$6"
    LABEL="$(profile_display_name "$PROFILE")"

    if [ -s "$SOURCE_FILE" ]; then
        SOURCE_VALUE="$(cat "$SOURCE_FILE")"
    elif [ -s "$STORE_FILE" ]; then
        SOURCE_VALUE="$(cat "$STORE_FILE")"
        printf "%s\n" "$SOURCE_VALUE" > "$SOURCE_FILE"
        chmod 600 "$SOURCE_FILE"
    else
        echo "$LABEL профиль не задан."
        return 2
    fi

    PREVIOUS_VALUE="$(cat "$STORE_FILE" 2>/dev/null || true)"

    echo "Обновляем $LABEL профиль..."
    RESOLVED_VALUE="$(resolve_subscription_update "$SOURCE_VALUE" "$PREVIOUS_VALUE" "$LABEL")"

    PROFILE_NAME="$PROFILE" \
    VLESS_URL="$RESOLVED_VALUE" \
    LISTEN_HOST="$HOST" \
    LISTEN_PORT="$PORT" \
    OUTPUT_CONFIG="$OUT_CONFIG" \
    "$GENERATOR"

    test_xray_config "$OUT_CONFIG"

    printf "%s\n" "$RESOLVED_VALUE" > "$STORE_FILE"
    chmod 600 "$STORE_FILE"
    printf "%s\n" "$SOURCE_VALUE" > "$SOURCE_FILE"
    chmod 600 "$SOURCE_FILE"

    echo "$LABEL профиль обновлён."
    return 0
}

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден."; exit 1; }
[ -x "$GENERATOR" ] || { echo "ОШИБКА: генератор не найден: $GENERATOR"; exit 1; }
[ -s "$ROUTER_IP_STORE" ] || { echo "ОШИБКА: LAN-IP не найден: $ROUTER_IP_STORE"; exit 1; }

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-sub-update-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-sub-update-backup.json"
TMP_ACTIVE_CONFIG="$TMP_DIR/xray-sub-update-active.json"
OLD_CONFIG="$TMP_DIR/xray-config-before-subscription-update.json"

echo "======================================"
echo " Обновление подписок"
echo "======================================"

acquire_lock
mkdir -p "$XRAY_DIR" "$TMP_DIR"

update_one_profile "primary" "$PRIMARY_SOURCE" "$PRIMARY_STORE" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
PRIMARY_STATUS="$?"

BACKUP_STATUS="2"
if [ -s "$BACKUP_SOURCE" ] || [ -s "$BACKUP_STORE" ]; then
    if update_one_profile "backup" "$BACKUP_SOURCE" "$BACKUP_STORE" "127.0.0.1" "19081" "$TMP_BACKUP_CONFIG"; then
        BACKUP_STATUS="0"
    else
        BACKUP_STATUS="$?"
        echo "ПРЕДУПРЕЖДЕНИЕ: Резервный профиль не обновлён."
    fi
fi

ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
if [ "$ACTIVE" = "backup" ] && [ -s "$BACKUP_STORE" ]; then
    ACTIVE_URL="$(cat "$BACKUP_STORE")"
    ACTIVE_PROFILE="backup"
else
    ACTIVE_URL="$(cat "$PRIMARY_STORE")"
    ACTIVE_PROFILE="primary"
fi

PROFILE_NAME="$ACTIVE_PROFILE" \
VLESS_URL="$ACTIVE_URL" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_ACTIVE_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_ACTIVE_CONFIG"

[ -s "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true
[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
cp "$TMP_ACTIVE_CONFIG" "$XRAY_CONFIG"

if ! "$INIT_SCRIPT" restart; then
    echo "ОШИБКА: Xray не перезапустился. Откатываем config."
    [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
    "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start || true

rm -f "$TMP_PRIMARY_CONFIG" "$TMP_BACKUP_CONFIG" "$TMP_ACTIVE_CONFIG" 2>/dev/null || true

echo
echo "Готово. Подписки обновлены."
echo "Активный профиль: $(profile_display_name "$ACTIVE_PROFILE")"
SUBUPDATE

    chmod +x "$SUBSCRIPTION_UPDATE_CMD"
}

create_subscription_auto_update_command() {
    echo "[10/10] Создаём команду автообновления подписок..."

    cat > "$SUBSCRIPTION_AUTO_CMD" <<'AUTOSUB'
#!/bin/sh
set -e

CRON_FILE="/opt/var/spool/cron/crontabs/root"
CRON_DIR="$(dirname "$CRON_FILE")"
UPDATE_CMD="/opt/bin/vless-subscription-update"
LOG_FILE="/opt/var/log/xray-vless-subscription-update.log"
TAG="xray-vless-subscription-auto-update"

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

ensure_cron_dirs() {
    mkdir -p "$CRON_DIR" /opt/var/log
    [ -f "$CRON_FILE" ] || touch "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

restart_crond() {
    if [ -x /opt/etc/init.d/S10cron ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || true
    elif [ -x /opt/etc/init.d/S10crond ]; then
        /opt/etc/init.d/S10crond restart >/dev/null 2>&1 || true
    elif command -v crond >/dev/null 2>&1; then
        killall crond >/dev/null 2>&1 || true
        crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
    else
        echo "crond не найден. Пробуем установить cron/cronie..."
        if command -v opkg >/dev/null 2>&1; then
            opkg update >/dev/null 2>&1 || true
            opkg install cron >/dev/null 2>&1 \
                || opkg install cronie >/dev/null 2>&1 \
                || opkg install busybox-cron >/dev/null 2>&1 \
                || true
        fi

        if command -v crond >/dev/null 2>&1; then
            crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        else
            echo "ПРЕДУПРЕЖДЕНИЕ: crond всё ещё не найден. Автообновление не запустится до установки cron."
        fi
    fi
}

remove_job() {
    ensure_cron_dirs
    grep -v "$TAG" "$CRON_FILE" > "$CRON_FILE.tmp" 2>/dev/null || true
    mv "$CRON_FILE.tmp" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

show_status() {
    ensure_cron_dirs
    echo "Cron-файл: $CRON_FILE"
    echo
    echo "Текущее задание автообновления:"
    grep "$TAG" "$CRON_FILE" 2>/dev/null || echo "не настроено"
    echo
    echo "Лог автообновления:"
    echo "$LOG_FILE"
    [ -f "$LOG_FILE" ] && tail -n 20 "$LOG_FILE" || true
}

enable_every_hours() {
    HOURS="$1"

    case "$HOURS" in
        ''|*[!0-9]*)
            echo "ОШИБКА: интервал должен быть числом часов."
            exit 1
            ;;
    esac

    if [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt 24 ]; then
        echo "ОШИБКА: интервал должен быть от 1 до 24 часов."
        exit 1
    fi

    [ -x "$UPDATE_CMD" ] || {
        echo "ОШИБКА: команда обновления подписок не найдена: $UPDATE_CMD"
        exit 1
    }

    ensure_cron_dirs
    remove_job

    if [ "$HOURS" = "1" ]; then
        SCHEDULE="7 * * * *"
    else
        SCHEDULE="7 */$HOURS * * *"
    fi

    echo "$SCHEDULE $UPDATE_CMD >> $LOG_FILE 2>&1 # $TAG" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    restart_crond

    echo "Автообновление подписок включено."
    echo "Интервал: каждые $HOURS ч."
    echo "Задание:"
    grep "$TAG" "$CRON_FILE" 2>/dev/null || true
}

disable_auto() {
    remove_job
    restart_crond
    echo "Автообновление подписок отключено."
}

case "${1:-menu}" in
    enable)
        enable_every_hours "${2:-1}"
        ;;
    disable)
        disable_auto
        ;;
    status)
        show_status
        ;;
    menu|*)
        while true; do
            echo
            echo "======================================"
            echo " Автообновление подписок"
            echo "======================================"
            echo "1 Включить / изменить интервал"
            echo "2 Отключить"
            echo "3 Показать статус"
            echo "0 Выход"
            echo
            read_tty "Выберите пункт: "
            case "$REPLY" in
                1)
                    read_tty "Интервал автообновления в часах, например 1, 2, 6, 12, 24: "
                    enable_every_hours "$REPLY"
                    ;;
                2)
                    disable_auto
                    ;;
                3)
                    show_status
                    ;;
                0)
                    exit 0
                    ;;
                *)
                    echo "Неверный пункт."
                    ;;
            esac
        done
        ;;
esac
AUTOSUB

    chmod +x "$SUBSCRIPTION_AUTO_CMD"
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
    sh -n "$RESOLVER"
    sh -n "$FAILOVER_DAEMON"
    sh -n "$XRAY_CORE_UPDATE_CMD"
    sh -n "$FAILOVER_MENU_CMD"
    sh -n "$FAILOVER_UPDATE_CMD"
    sh -n "$SUBSCRIPTION_UPDATE_CMD"
    sh -n "$SUBSCRIPTION_AUTO_CMD"
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

    RESOLVED_VALUE="$SOURCE_VALUE"
    if [ -x "${RESOLVER:-/opt/bin/xray-vless-resolve-input}" ]; then
        if ! RESOLVED_VALUE="$(${RESOLVER:-/opt/bin/xray-vless-resolve-input} interactive "$SOURCE_VALUE" "$LABEL")"; then
            return 1
        fi
    fi

    PROFILE_NAME="$PROFILE"     VLESS_URL="$RESOLVED_VALUE"     LISTEN_HOST="$HOST"     LISTEN_PORT="$PORT"     OUTPUT_CONFIG="$OUT_CONFIG"     "$GENERATOR"

    PROFILE_RESOLVED_RESULT="$RESOLVED_VALUE"
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
            PROFILE_SOURCE_RESULT="$CANDIDATE"
            PROFILE_INPUT_RESULT="${PROFILE_RESOLVED_RESULT:-$CANDIDATE}"
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
            PROFILE_SOURCE_RESULT=""
            PROFILE_INPUT_RESULT=""
            return 0
        fi

        if validate_profile_input "$PROFILE" "$CANDIDATE" "$HOST" "$PORT" "$OUT_CONFIG"; then
            PROFILE_SOURCE_RESULT="$CANDIDATE"
            PROFILE_INPUT_RESULT="${PROFILE_RESOLVED_RESULT:-$CANDIDATE}"
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

if [ ! -s "$FAILOVER_CONF" ]; then
    cat > "$FAILOVER_CONF" <<CONF
CHECK_INTERVAL=10
FAILOVER_FAILURES_REQUIRED=2
RECOVERY_SUCCESSES_REQUIRED=2
CHECK_URL=https://www.gstatic.com/generate_204
CHECK_URLS="https://www.gstatic.com/generate_204 https://www.google.com/generate_204 https://cp.cloudflare.com/generate_204"
LOG_MAX_SIZE=1048576
CONF
    chmod 600 "$FAILOVER_CONF"
fi

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
create_resolver

echo "[3/10] Готовим VLESS-ссылки или ссылки подписок..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"

if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    echo "Используем сохранённую ссылку Основного профиля."
    if [ -s "$PRIMARY_SOURCE" ]; then
        PRIMARY_INPUT="$(cat "$PRIMARY_SOURCE")"
    else
        PRIMARY_INPUT="$(cat "$PRIMARY_STORE")"
    fi
    PRIMARY_SOURCE_VALUE="$PRIMARY_INPUT"

    if validate_profile_input "primary" "$PRIMARY_INPUT" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"; then
        PRIMARY_VLESS="$PROFILE_INPUT_RESULT"
    else
        echo "Сохранённая ссылка Основного профиля неверная или подписка недоступна. Нужно ввести заново."
        ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
        PRIMARY_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
        PRIMARY_VLESS="$PROFILE_INPUT_RESULT"
    fi

    if [ -s "$BACKUP_STORE" ] || [ -s "$BACKUP_SOURCE" ]; then
        echo "Используем сохранённую ссылку Резервного профиля."
        if [ -s "$BACKUP_SOURCE" ]; then
            BACKUP_INPUT="$(cat "$BACKUP_SOURCE")"
        else
            BACKUP_INPUT="$(cat "$BACKUP_STORE")"
        fi
        BACKUP_SOURCE_VALUE="$BACKUP_INPUT"

        if validate_profile_input "backup" "$BACKUP_INPUT" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"; then
            BACKUP_VLESS="$PROFILE_INPUT_RESULT"
        else
            echo "Сохранённая ссылка Резервного профиля неверная или подписка недоступна."
            ask_optional_profile_input "backup" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"
            BACKUP_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
            BACKUP_VLESS="$PROFILE_INPUT_RESULT"
        fi
    else
        echo "VLESS-ссылка Резервного профиля не задана."
        BACKUP_SOURCE_VALUE=""
        BACKUP_VLESS=""
    fi
else
    ask_required_profile_input "primary" "$ROUTER_LAN_IP" "$SOCKS_PORT" "$TMP_PRIMARY_CONFIG"
    PRIMARY_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
    PRIMARY_VLESS="$PROFILE_INPUT_RESULT"

    ask_optional_profile_input "backup" "127.0.0.1" "$TEMP_BACKUP_PORT" "$TMP_BACKUP_CONFIG"
    BACKUP_SOURCE_VALUE="$PROFILE_SOURCE_RESULT"
    BACKUP_VLESS="$PROFILE_INPUT_RESULT"
fi

create_xray_init
create_failover_daemon
create_status_command
create_xray_core_update_command
create_menu_command
create_failover_update_command
create_subscription_update_command
create_subscription_auto_update_command
create_failover_installer_update_command
create_failover_init

check_generated_scripts

echo "Проверяем config Основного профиля во временном файле..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
[ -s "$TMP_PRIMARY_CONFIG" ] || { echo "ОШИБКА: временный config Основного профиля не найден: $TMP_PRIMARY_CONFIG"; exit 1; }
test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем config Резервного профиля во временном файле..."
    TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"
    [ -s "$TMP_BACKUP_CONFIG" ] || { echo "ОШИБКА: временный config Резервного профиля не найден: $TMP_BACKUP_CONFIG"; exit 1; }
    test_xray_config "$TMP_BACKUP_CONFIG"
fi

printf "%s\n" "$PRIMARY_VLESS" > "$PRIMARY_STORE"
chmod 600 "$PRIMARY_STORE"
printf "%s\n" "${PRIMARY_SOURCE_VALUE:-$PRIMARY_VLESS}" > "$PRIMARY_SOURCE"
chmod 600 "$PRIMARY_SOURCE"

if [ -n "$BACKUP_VLESS" ]; then
    printf "%s\n" "$BACKUP_VLESS" > "$BACKUP_STORE"
    chmod 600 "$BACKUP_STORE"
    printf "%s\n" "${BACKUP_SOURCE_VALUE:-$BACKUP_VLESS}" > "$BACKUP_SOURCE"
    chmod 600 "$BACKUP_SOURCE"
    echo "VLESS-ссылка Резервного профиля сохранена."
else
    rm -f "$BACKUP_STORE" "$BACKUP_SOURCE"
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
echo "Proxy0 настроен без глобального приоритета: используется только для правил/доменной маршрутизации."
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
