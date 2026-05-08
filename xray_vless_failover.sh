#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"

GENERATOR="/opt/bin/xray-vless-generate-config"
RESOLVER="/opt/bin/xray-vless-resolve-input"
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
FAILOVER_CONF="$XRAY_DIR/failover.conf"

LOCK_DIR="/opt/var/run/xray-failover.lock"
BACKUP_DIR="/opt/backup/xray-failover"

SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"
GLOBAL_PRIORITY="16375"

CHECK_INTERVAL="10"
FAILOVER_FAILURES_REQUIRED="2"
RECOVERY_SUCCESSES_REQUIRED="2"
CHECK_URL="https://www.gstatic.com/generate_204"
LOG_MAX_SIZE="1048576"

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

create_default_settings() {
    mkdir -p "$XRAY_DIR"

    if [ ! -s "$FAILOVER_CONF" ]; then
        cat > "$FAILOVER_CONF" <<CONF
CHECK_INTERVAL=10
FAILOVER_FAILURES_REQUIRED=2
RECOVERY_SUCCESSES_REQUIRED=2
CHECK_URL=https://www.gstatic.com/generate_204
LOG_MAX_SIZE=1048576
CONF
        chmod 600 "$FAILOVER_CONF"
    fi
}

load_settings() {
    if [ -s "$FAILOVER_CONF" ]; then
        . "$FAILOVER_CONF"
    fi
}

acquire_lock() {
    LOCK_OWNER="${1:-installer}"
    mkdir -p /opt/var/run

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$LOCK_OWNER" > "$LOCK_DIR/owner"
        echo "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    echo "ОШИБКА: уже выполняется другая операция failover."
    if [ -f "$LOCK_DIR/owner" ]; then
        echo "Владелец блокировки: $(cat "$LOCK_DIR/owner" 2>/dev/null)"
    fi
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
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

    command -v unzip >/dev/null 2>&1 || opkg install unzip >/dev/null 2>&1 || true
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
    echo "Создаём обработчик VLESS/подписок..."

    cat > "$RESOLVER" <<'RESOLVER'
#!/bin/sh
set -e

INPUT_VALUE="${1:-}"
PROFILE_LABEL="${2:-Профиль}"
MODE="${3:-interactive}"

INPUT_VALUE="$INPUT_VALUE" PROFILE_LABEL="$PROFILE_LABEL" MODE="$MODE" python3 <<'PY'
import base64
import os
import re
import sys
import urllib.parse
import urllib.request

value = os.environ.get("INPUT_VALUE", "").strip()
label = os.environ.get("PROFILE_LABEL", "Профиль")
mode = os.environ.get("MODE", "interactive")

VLESS_RE = re.compile(r"vless://[^\s'\"<>]+")

def eprint(*args):
    print(*args, file=sys.stderr)

def clean_link(link: str) -> str:
    return link.strip().strip("\r\n\t ")

def validate_vless(link: str) -> str:
    parsed = urllib.parse.urlparse(link)
    if parsed.scheme != "vless":
        raise ValueError("ожидалась ссылка vless://")
    if not parsed.username:
        raise ValueError("в VLESS-ссылке отсутствует UUID")
    if not parsed.hostname:
        raise ValueError("в VLESS-ссылке отсутствует сервер")
    return link

def find_links(text: str):
    return [clean_link(x) for x in VLESS_RE.findall(text or "")]

def try_decode_base64(text: str):
    raw = re.sub(r"\s+", "", text or "")
    if not raw:
        return ""
    padding = "=" * ((4 - len(raw) % 4) % 4)
    candidates = [raw + padding]
    out = []
    for candidate in candidates:
        for decoder in (base64.b64decode, base64.urlsafe_b64decode):
            try:
                decoded = decoder(candidate.encode("utf-8"))
                out.append(decoded.decode("utf-8", "ignore"))
            except Exception:
                pass
    return "\n".join(out)

def fetch_subscription(url: str):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "xray-vless-failover/1.0",
            "Accept": "text/plain,*/*"
        },
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        data = response.read()
    return data.decode("utf-8", "ignore")

def link_name(link: str, idx: int):
    parsed = urllib.parse.urlparse(link)
    name = urllib.parse.unquote(parsed.fragment or "").strip()
    if not name:
        host = parsed.hostname or "unknown"
        name = f"{host}:{parsed.port or 443}"
    return f"{idx}. {name}"

def choose_link(links):
    if not links:
        raise ValueError("в подписке не найдена ни одна VLESS-ссылка")

    unique = []
    seen = set()
    for link in links:
        if link not in seen:
            unique.append(link)
            seen.add(link)

    if len(unique) == 1 or mode != "interactive":
        if len(unique) > 1:
            eprint(f"{label}: найдено {len(unique)} VLESS-профилей, выбран первый.")
        return validate_vless(unique[0])

    eprint("")
    eprint(f"{label}: найдено VLESS-профилей: {len(unique)}")
    for i, link in enumerate(unique, 1):
        eprint(link_name(link, i))
    eprint("")

    while True:
        try:
            with open("/dev/tty", "r+") as tty:
                tty.write("Выберите номер профиля: ")
                tty.flush()
                answer = tty.readline().strip()
        except Exception:
            answer = input("Выберите номер профиля: ").strip()

        if answer.isdigit():
            number = int(answer)
            if 1 <= number <= len(unique):
                return validate_vless(unique[number - 1])

        eprint("Неверный номер. Повторите выбор.")

def resolve(value: str):
    if not value:
        raise ValueError("пустая ссылка")

    if value.startswith("vless://"):
        return validate_vless(value)

    parsed = urllib.parse.urlparse(value)
    if parsed.scheme in ("http", "https"):
        eprint(f"{label}: скачиваем подписку...")
        text = fetch_subscription(value)
        links = find_links(text)

        if not links:
            decoded = try_decode_base64(text)
            links = find_links(decoded)

        return choose_link(links)

    raise ValueError("поддерживаются только vless://, http:// или https://")

try:
    print(resolve(value))
except Exception as exc:
    eprint(f"ОШИБКА: {exc}")
    sys.exit(1)
PY
RESOLVER

    chmod +x "$RESOLVER"
}

create_generator() {
    echo "[4/10] Создаём генератор config..."

    cat > "$GENERATOR" <<'GEN'
#!/bin/sh
set -e

python3 <<'PY'
import base64
import os
import re
import json
import sys
import urllib.parse
import urllib.request

profile_name = os.environ.get("PROFILE_NAME", "vless-out")
raw_url = os.environ["VLESS_URL"].strip()
listen_host = os.environ["LISTEN_HOST"]
listen_port = int(os.environ["LISTEN_PORT"])
output_config = os.environ["OUTPUT_CONFIG"]

VLESS_RE = re.compile(r"vless://[^\s'\"<>]+")

def clean_link(link: str) -> str:
    return link.strip().strip("\r\n\t ")

def find_links(text: str):
    return [clean_link(x) for x in VLESS_RE.findall(text or "")]

def try_decode_base64(text: str):
    raw = re.sub(r"\s+", "", text or "")
    if not raw:
        return ""
    padding = "=" * ((4 - len(raw) % 4) % 4)
    out = []
    for decoder in (base64.b64decode, base64.urlsafe_b64decode):
        try:
            decoded = decoder((raw + padding).encode("utf-8"))
            out.append(decoded.decode("utf-8", "ignore"))
        except Exception:
            pass
    return "\n".join(out)

def fetch_subscription(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "xray-vless-failover/1.0"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read().decode("utf-8", "ignore")

def resolve_to_vless(value: str):
    value = value.strip()
    if value.startswith("vless://"):
        return value

    parsed = urllib.parse.urlparse(value)
    if parsed.scheme in ("http", "https"):
        text = fetch_subscription(value)
        links = find_links(text)
        if not links:
            links = find_links(try_decode_base64(text))
        if not links:
            raise SystemExit("ERROR: subscription does not contain vless:// links")
        return links[0]

    raise SystemExit("ERROR: only vless://, http:// and https:// links are supported")

url = resolve_to_vless(raw_url)
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

print("Создан config:", output_config)
print("Профиль:", profile_name)
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
FAILOVER_CONF="$XRAY_DIR/failover.conf"

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
LOCK_DIR="/opt/var/run/xray-failover.lock"

TMP_TEST_PIDS=""

profile_display_name() {
    case "$1" in
        primary) echo "Основной" ;;
        backup) echo "Резервный" ;;
        *) echo "$1" ;;
    esac
}

load_settings() {
    if [ -s "$FAILOVER_CONF" ]; then
        . "$FAILOVER_CONF"
    fi
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "daemon" > "$LOCK_DIR/owner"
        echo "$$" > "$LOCK_DIR/pid"
        return 0
    fi

    echo "Операция пропущена: занята блокировка failover."
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

cleanup_children() {
    for p in $TMP_TEST_PIDS; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    release_lock
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

    load_settings

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

    TMP_SWITCH_CONFIG="$TMP_DIR/xray-switch-$TARGET.json"
    OLD_CONFIG="$TMP_DIR/xray-config-before-switch.json"
    TARGET_LABEL="$(profile_display_name "$TARGET")"

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
    load_settings

    ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    ACTIVE_LABEL="$(profile_display_name "$ACTIVE")"

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
                    if acquire_lock; then
                        if switch_to_profile "backup"; then
                            PRIMARY_FAIL_COUNT="0"
                            PRIMARY_RECOVERY_COUNT="0"
                            BACKUP_FAIL_COUNT="0"
                        else
                            echo "Переключение на Резервный профиль не удалось."
                        fi
                        release_lock
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
                if acquire_lock; then
                    if switch_to_profile "primary"; then
                        PRIMARY_FAIL_COUNT="0"
                        PRIMARY_RECOVERY_COUNT="0"
                        BACKUP_FAIL_COUNT="0"
                    else
                        echo "Переключение на Основной профиль не удалось."
                    fi
                    release_lock
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
        if acquire_lock; then
            switch_to_profile "primary" || echo "Переключение на Основной профиль не удалось."
            release_lock
        fi
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
CONF="$FAILOVER_CONF"

mkdir -p /opt/var/run /opt/var/log

LOG_MAX_SIZE=1048576
[ -s "\$CONF" ] && . "\$CONF"

rotate_log() {
    [ -f "\$LOGFILE" ] || return 0
    SIZE="\$(wc -c < "\$LOGFILE" 2>/dev/null || echo 0)"
    if [ "\$SIZE" -gt "\$LOG_MAX_SIZE" ]; then
        mv "\$LOGFILE" "\$LOGFILE.1" 2>/dev/null || true
        : > "\$LOGFILE"
    fi
}

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

    rotate_log

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
    rotate-log) rotate_log ;;
    *) echo "Использование: \$0 {start|stop|restart|status|rotate-log}"; exit 1 ;;
esac
INIT

    chmod +x "$FAILOVER_INIT"
}

create_status_command() {
    echo "Создаём команду статуса..."

    cat > "$FAILOVER_STATUS" <<'STATUS'
#!/bin/sh

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
FAILOVER_CONF="$XRAY_DIR/failover.conf"
SOCKS_PORT="10808"
CHECK_URL="https://www.gstatic.com/generate_204"

[ -s "$FAILOVER_CONF" ] && . "$FAILOVER_CONF"

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || echo 192.168.1.1)"

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then command -v xray
    elif [ -x /opt/bin/xray ]; then echo "/opt/bin/xray"
    else echo ""
    fi
}

XRAY_BIN="$(get_xray_bin)"

echo "======================================"
echo " Диагностика Xray VLESS Failover"
echo "======================================"
echo

echo "Активный профиль:"
ACTIVE="$(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
case "$ACTIVE" in
    primary) echo "Основной" ;;
    backup) echo "Резервный" ;;
    *) echo "$ACTIVE" ;;
esac

echo
echo "Настройки failover:"
echo "CHECK_INTERVAL=${CHECK_INTERVAL:-10}"
echo "FAILOVER_FAILURES_REQUIRED=${FAILOVER_FAILURES_REQUIRED:-2}"
echo "RECOVERY_SUCCESSES_REQUIRED=${RECOVERY_SUCCESSES_REQUIRED:-2}"
echo "CHECK_URL=${CHECK_URL:-https://www.gstatic.com/generate_204}"
echo "LOG_MAX_SIZE=${LOG_MAX_SIZE:-1048576}"

echo
echo "Компоненты:"
command -v curl >/dev/null 2>&1 && echo "[OK] curl" || echo "[FAIL] curl не найден"
command -v python3 >/dev/null 2>&1 && echo "[OK] python3" || echo "[FAIL] python3 не найден"
command -v unzip >/dev/null 2>&1 && echo "[OK] unzip" || echo "[WARN] unzip не найден"
[ -n "$XRAY_BIN" ] && echo "[OK] xray: $XRAY_BIN" || echo "[FAIL] xray не найден"

echo
echo "Версия Xray:"
if [ -n "$XRAY_BIN" ]; then
    "$XRAY_BIN" version 2>/dev/null | head -n 2 || true
fi

echo
echo "Статус Xray:"
/opt/etc/init.d/S24xray status 2>/dev/null || true

echo
echo "Статус failover:"
/opt/etc/init.d/S25xray-failover status 2>/dev/null || true

echo
echo "Проверка config.json:"
if [ -n "$XRAY_BIN" ] && [ -s "$XRAY_CONFIG" ]; then
    if "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || "$XRAY_BIN" test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        echo "[OK] config.json валиден"
    else
        echo "[FAIL] config.json не прошёл проверку"
    fi
else
    echo "[FAIL] Xray или config.json не найден"
fi

echo
echo "SOCKS5 port:"
netstat -lntp 2>/dev/null | grep 10808 || netstat -lnt 2>/dev/null | grep 10808 || echo "[WARN] порт 10808 не найден"

echo
echo "Проверка TCP/HTTP через SOCKS5:"
curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" \
    --connect-timeout 5 \
    --max-time 10 \
    -o /dev/null \
    -w 'http_code=%{http_code} time_total=%{time_total}\n' \
    "${CHECK_URL:-https://www.gstatic.com/generate_204}" 2>&1 || true

echo
echo "Проверка внешнего IP через SOCKS5:"
curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" \
    --connect-timeout 5 \
    --max-time 10 \
    https://api.ipify.org 2>&1 || true
echo

echo
echo "Proxy0:"
ndmc -c "show running-config" 2>/dev/null | grep -A12 -i "interface Proxy0" || echo "[WARN] Proxy0 не найден или ndmc недоступен"

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

XRAY_CONFIG="/opt/etc/xray/config.json"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
XRAY_INIT="/opt/etc/init.d/S24xray"
LOCK_DIR="/opt/var/run/xray-failover.lock"
WORK_DIR="/opt/tmp/xray-core-update"
BACKUP_ROOT="/opt/backup/xray-core"

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

acquire_lock() {
    mkdir -p /opt/var/run
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "xray-core-update" > "$LOCK_DIR/owner"
        echo "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    echo "ОШИБКА: другая операция failover уже выполняется."
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

trap 'release_lock' EXIT INT TERM

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then command -v xray
    elif [ -x /opt/bin/xray ]; then echo "/opt/bin/xray"
    else echo "/opt/bin/xray"
    fi
}

test_xray_config_with_bin() {
    BIN="$1"
    CONFIG="$2"

    if "$BIN" run -test -config "$CONFIG" >/dev/null 2>&1; then
        return 0
    fi

    "$BIN" test -config "$CONFIG"
}

detect_asset_name() {
    ARCH="$(uname -m 2>/dev/null || echo unknown)"

    case "$ARCH" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i686) echo "Xray-linux-32.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
        armv5*|arm) echo "Xray-linux-arm32-v5.zip" ;;
        mips64el|mips64le) echo "Xray-linux-mips64le.zip" ;;
        mips64) echo "Xray-linux-mips64.zip" ;;
        mipsel|mipsle) echo "Xray-linux-mips32le.zip" ;;
        mips) echo "Xray-linux-mips32.zip" ;;
        *) echo "" ;;
    esac
}

find_release_asset() {
    CHANNEL="$1"
    ASSET_NAME="$2"

    CHANNEL="$CHANNEL" ASSET_NAME="$ASSET_NAME" python3 <<'PY'
import json
import os
import sys
import urllib.request

channel = os.environ["CHANNEL"]
asset_name = os.environ["ASSET_NAME"]

headers = {
    "User-Agent": "xray-core-update/1.0",
    "Accept": "application/vnd.github+json"
}

def fetch(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))

if channel == "stable":
    releases = [fetch("https://api.github.com/repos/XTLS/Xray-core/releases/latest")]
else:
    releases = fetch("https://api.github.com/repos/XTLS/Xray-core/releases")
    releases = [r for r in releases if r.get("prerelease")]

if not releases:
    raise SystemExit("ERROR: release not found")

release = releases[0]
for asset in release.get("assets", []):
    if asset.get("name") == asset_name:
        print(release.get("tag_name", "unknown"))
        print(asset.get("browser_download_url"))
        sys.exit(0)

print("ERROR: asset not found: " + asset_name, file=sys.stderr)
sys.exit(1)
PY
}

acquire_lock

echo "======================================"
echo " Обновление ядра Xray"
echo "======================================"

TARGET_XRAY="$(get_xray_bin)"
ASSET_NAME="$(detect_asset_name)"

if [ -z "$ASSET_NAME" ]; then
    echo "ОШИБКА: неподдерживаемая архитектура: $(uname -m)"
    exit 1
fi

echo "Текущий бинарник: $TARGET_XRAY"
echo "Архитектура: $(uname -m)"
echo "Asset GitHub: $ASSET_NAME"
echo

read_tty "Сделать бэкап текущего Xray и config? [Y/n]: "
case "$REPLY" in
    n|N|no|NO|нет|Нет) DO_BACKUP="0" ;;
    *) DO_BACKUP="1" ;;
esac

echo
echo "Выберите канал:"
echo "1 Stable"
echo "2 Pre-release"
read_tty "Ваш выбор [1]: "

case "$REPLY" in
    2) CHANNEL="prerelease" ;;
    *) CHANNEL="stable" ;;
esac

mkdir -p "$WORK_DIR"
rm -rf "$WORK_DIR"/*
mkdir -p "$WORK_DIR"

if ! command -v unzip >/dev/null 2>&1; then
    opkg update
    opkg install unzip
fi

echo "Получаем ссылку на релиз Xray-core..."
RELEASE_INFO="$(find_release_asset "$CHANNEL" "$ASSET_NAME")"
TAG="$(printf "%s\n" "$RELEASE_INFO" | sed -n '1p')"
DOWNLOAD_URL="$(printf "%s\n" "$RELEASE_INFO" | sed -n '2p')"

[ -n "$DOWNLOAD_URL" ] || { echo "ОШИБКА: не удалось получить download URL."; exit 1; }

echo "Релиз: $TAG"
echo "Скачиваем: $DOWNLOAD_URL"

curl -fL -o "$WORK_DIR/xray.zip" "$DOWNLOAD_URL"
unzip -o "$WORK_DIR/xray.zip" -d "$WORK_DIR/unpack" >/dev/null

NEW_XRAY="$WORK_DIR/unpack/xray"
[ -x "$NEW_XRAY" ] || chmod +x "$NEW_XRAY" 2>/dev/null || true
[ -x "$NEW_XRAY" ] || { echo "ОШИБКА: xray не найден в архиве."; exit 1; }

echo "Проверяем новый бинарник:"
"$NEW_XRAY" version | head -n 2

if [ -s "$XRAY_CONFIG" ]; then
    echo "Проверяем текущий config новым ядром..."
    test_xray_config_with_bin "$NEW_XRAY" "$XRAY_CONFIG"
fi

BACKUP_DIR=""
if [ "$DO_BACKUP" = "1" ]; then
    TS="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || date +%s)"
    BACKUP_DIR="$BACKUP_ROOT/$TS"
    mkdir -p "$BACKUP_DIR"
    [ -f "$TARGET_XRAY" ] && cp "$TARGET_XRAY" "$BACKUP_DIR/xray"
    [ -f "$XRAY_CONFIG" ] && cp "$XRAY_CONFIG" "$BACKUP_DIR/config.json"
    echo "Бэкап сохранён: $BACKUP_DIR"
fi

OLD_XRAY="$WORK_DIR/xray.old"
[ -f "$TARGET_XRAY" ] && cp "$TARGET_XRAY" "$OLD_XRAY" || true

[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
[ -x "$XRAY_INIT" ] && "$XRAY_INIT" stop >/dev/null 2>&1 || true

cp "$NEW_XRAY" "$TARGET_XRAY"
chmod +x "$TARGET_XRAY"

if [ -s "$XRAY_CONFIG" ]; then
    if ! test_xray_config_with_bin "$TARGET_XRAY" "$XRAY_CONFIG"; then
        echo "ОШИБКА: новый Xray не принимает текущий config. Откатываем бинарник."
        [ -s "$OLD_XRAY" ] && cp "$OLD_XRAY" "$TARGET_XRAY"
        chmod +x "$TARGET_XRAY"
        [ -x "$XRAY_INIT" ] && "$XRAY_INIT" start >/dev/null 2>&1 || true
        [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
        exit 1
    fi
fi

[ -x "$XRAY_INIT" ] && "$XRAY_INIT" start
[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start

echo
echo "Готово. Ядро Xray обновлено до: $TAG"
"$TARGET_XRAY" version | head -n 2
COREUPDATE

    chmod +x "$XRAY_CORE_UPDATE_CMD"
}

create_menu_command() {
    echo "Создаём меню failover..."

    cat > "$FAILOVER_MENU_CMD" <<'MENU'
#!/bin/sh

FAILOVER_UPDATE="/opt/bin/vless-failover-update"
FAILOVER_STATUS="/opt/bin/vless-failover-status"
XRAY_CORE_UPDATE="/opt/bin/xray-core-update"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
XRAY_INIT="/opt/etc/init.d/S24xray"
FAILOVER_CONF="/opt/etc/xray/failover.conf"
LOGFILE="/opt/var/log/xray-vless-failover.log"

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

show_settings() {
    echo
    echo "Текущие настройки:"
    if [ -s "$FAILOVER_CONF" ]; then
        cat "$FAILOVER_CONF"
    else
        echo "Файл настроек не найден: $FAILOVER_CONF"
    fi
}

edit_settings() {
    CHECK_INTERVAL="10"
    FAILOVER_FAILURES_REQUIRED="2"
    RECOVERY_SUCCESSES_REQUIRED="2"
    CHECK_URL="https://www.gstatic.com/generate_204"
    LOG_MAX_SIZE="1048576"

    [ -s "$FAILOVER_CONF" ] && . "$FAILOVER_CONF"

    show_settings
    echo

    read_tty "Интервал проверки в секундах [$CHECK_INTERVAL]: "
    [ -n "$REPLY" ] && CHECK_INTERVAL="$REPLY"

    read_tty "Ошибок до перехода на Резервный [$FAILOVER_FAILURES_REQUIRED]: "
    [ -n "$REPLY" ] && FAILOVER_FAILURES_REQUIRED="$REPLY"

    read_tty "Успешных проверок до возврата на Основной [$RECOVERY_SUCCESSES_REQUIRED]: "
    [ -n "$REPLY" ] && RECOVERY_SUCCESSES_REQUIRED="$REPLY"

    read_tty "URL проверки [$CHECK_URL]: "
    [ -n "$REPLY" ] && CHECK_URL="$REPLY"

    read_tty "Размер лога для ротации в байтах [$LOG_MAX_SIZE]: "
    [ -n "$REPLY" ] && LOG_MAX_SIZE="$REPLY"

    mkdir -p "$(dirname "$FAILOVER_CONF")"
    cat > "$FAILOVER_CONF" <<CONF
CHECK_INTERVAL=$CHECK_INTERVAL
FAILOVER_FAILURES_REQUIRED=$FAILOVER_FAILURES_REQUIRED
RECOVERY_SUCCESSES_REQUIRED=$RECOVERY_SUCCESSES_REQUIRED
CHECK_URL=$CHECK_URL
LOG_MAX_SIZE=$LOG_MAX_SIZE
CONF
    chmod 600 "$FAILOVER_CONF"

    echo "Настройки сохранены."
    read_tty "Перезапустить failover-daemon сейчас? [Y/n]: "
    case "$REPLY" in
        n|N|no|NO|нет|Нет) ;;
        *) [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" restart ;;
    esac
}

uninstall_failover() {
    echo
    echo "Будут удалены команды и сервисы failover."
    echo "Xray binary удаляться не будет."
    read_tty "Для подтверждения введите ДА: "

    [ "$REPLY" = "ДА" ] || {
        echo "Отменено."
        return 0
    }

    read_tty "Сохранить /opt/etc/xray с config и ссылками? [Y/n]: "
    case "$REPLY" in
        n|N|no|NO|нет|Нет) KEEP_CONFIG="0" ;;
        *) KEEP_CONFIG="1" ;;
    esac

    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true

    rm -f /opt/bin/xray-vless-failover-daemon
    rm -f /opt/bin/xray-vless-generate-config
    rm -f /opt/bin/xray-vless-resolve-input
    rm -f /opt/bin/vless-failover-update
    rm -f /opt/bin/xray-failover-update
    rm -f /opt/bin/xray-core-update
    rm -f /opt/bin/xray-failover-installer-update
    rm -f /opt/bin/failover-installer-update
    rm -f /opt/etc/init.d/S25xray-failover
    rm -f /opt/var/run/xray-vless-failover.pid
    rm -rf /opt/var/run/xray-failover.lock

    if [ "$KEEP_CONFIG" = "0" ]; then
        rm -rf /opt/etc/xray
    fi

    echo "Failover удалён."
    echo "Команда меню /opt/bin/failover будет удалена последней."
    rm -f /opt/bin/failover
    exit 0
}

while true; do
    echo
    echo "======================================"
    echo " Xray VLESS Failover"
    echo "======================================"
    echo "1 Обновление VLESS"
    echo "2 Лог в реальном времени"
    echo "3 Диагностика"
    echo "4 Обновление ядра Xray"
    echo "5 Настройки failover"
    echo "6 Самопроверка установки"
    echo "7 Удаление / деинсталляция"
    echo "0 Выход"
    echo

    read_tty "Выберите пункт: "

    case "$REPLY" in
        1)
            "$FAILOVER_UPDATE"
            ;;
        2)
            tail -f "$LOGFILE"
            ;;
        3)
            "$FAILOVER_STATUS"
            ;;
        4)
            "$XRAY_CORE_UPDATE"
            ;;
        5)
            edit_settings
            ;;
        6)
            "$FAILOVER_STATUS"
            ;;
        7)
            uninstall_failover
            ;;
        0)
            exit 0
            ;;
        *)
            echo "Неверный пункт меню."
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
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
GENERATOR="/opt/bin/xray-vless-generate-config"
RESOLVER="/opt/bin/xray-vless-resolve-input"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
SOCKS_PORT="10808"
TMP_DIR="/opt/tmp"
LOCK_DIR="/opt/var/run/xray-failover.lock"

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

acquire_lock() {
    mkdir -p /opt/var/run
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "vless-failover-update" > "$LOCK_DIR/owner"
        echo "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    echo "ОШИБКА: другая операция failover уже выполняется."
    return 1
}

release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

trap 'release_lock' EXIT INT TERM

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

prompt_profile_link() {
    LABEL="$1"
    OPTIONAL="$2"
    PROMPT="$3"

    while true; do
        read_tty "$PROMPT"
        VALUE="$REPLY"

        if [ -z "$VALUE" ] && [ "$OPTIONAL" = "1" ]; then
            echo ""
            return 0
        fi

        if [ -z "$VALUE" ]; then
            echo "Ссылка пустая. Введите vless:// или http(s) ссылку подписки."
            continue
        fi

        if RESOLVED="$("$RESOLVER" "$VALUE" "$LABEL" interactive)"; then
            echo "$RESOLVED"
            return 0
        fi

        echo "Неверная ссылка или подписка. Повторите ввод."
    done
}

XRAY_BIN="$(get_xray_bin)"

[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден."; exit 1; }
[ -x "$GENERATOR" ] || { echo "ОШИБКА: генератор не найден: $GENERATOR"; exit 1; }
[ -x "$RESOLVER" ] || { echo "ОШИБКА: обработчик подписок не найден: $RESOLVER"; exit 1; }
[ -s "$ROUTER_IP_STORE" ] || { echo "ОШИБКА: LAN-IP не найден: $ROUTER_IP_STORE"; exit 1; }

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-update-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-update-backup.json"
OLD_CONFIG="$TMP_DIR/xray-config-before-vless-update.json"

echo "======================================"
echo " Обновление VLESS-ссылок failover"
echo "======================================"
echo "LAN-IP роутера: $ROUTER_LAN_IP"

PRIMARY_VLESS="$(prompt_profile_link "Основной профиль" "0" "Новая VLESS-ссылка или подписка Основного профиля: ")"
BACKUP_VLESS="$(prompt_profile_link "Резервный профиль" "1" "Новая VLESS-ссылка или подписка Резервного профиля, опционально: ")"

mkdir -p "$XRAY_DIR" "$TMP_DIR"

echo "Проверяем новый config Основного профиля во временном файле..."
PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем новый config Резервного профиля во временном файле..."
    PROFILE_NAME="backup" \
    VLESS_URL="$BACKUP_VLESS" \
    LISTEN_HOST="127.0.0.1" \
    LISTEN_PORT="19081" \
    OUTPUT_CONFIG="$TMP_BACKUP_CONFIG" \
    "$GENERATOR"

    test_xray_config "$TMP_BACKUP_CONFIG"
fi

acquire_lock

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

    sh -n "$RESOLVER"
    sh -n "$GENERATOR"
    sh -n "$FAILOVER_DAEMON"
    sh -n "$FAILOVER_STATUS"
    sh -n "$XRAY_CORE_UPDATE_CMD"
    sh -n "$FAILOVER_MENU_CMD"
    sh -n "$FAILOVER_UPDATE_CMD"
    sh -n "$FAILOVER_INSTALLER_UPDATE_CMD"
    sh -n "$INIT_SCRIPT"
    sh -n "$FAILOVER_INIT"
}

prompt_profile_link_main() {
    LABEL="$1"
    OPTIONAL="$2"
    PROMPT="$3"
    CONFIG_HOST="$4"
    CONFIG_PORT="$5"
    CONFIG_PROFILE="$6"
    CONFIG_OUT="$7"

    while true; do
        read_tty "$PROMPT"
        VALUE="$REPLY"

        if [ -z "$VALUE" ] && [ "$OPTIONAL" = "1" ]; then
            echo ""
            return 0
        fi

        if [ -z "$VALUE" ]; then
            echo "Ссылка пустая. Введите vless:// или http(s) ссылку подписки."
            continue
        fi

        if ! RESOLVED="$("$RESOLVER" "$VALUE" "$LABEL" interactive)"; then
            echo "Неверная ссылка или подписка. Повторите ввод."
            continue
        fi

        if PROFILE_NAME="$CONFIG_PROFILE" \
            VLESS_URL="$RESOLVED" \
            LISTEN_HOST="$CONFIG_HOST" \
            LISTEN_PORT="$CONFIG_PORT" \
            OUTPUT_CONFIG="$CONFIG_OUT" \
            "$GENERATOR" >/dev/null 2>&1 && test_xray_config "$CONFIG_OUT" >/dev/null 2>&1
        then
            echo "$RESOLVED"
            return 0
        fi

        echo "Ссылка распознана, но Xray config не прошёл проверку. Повторите ввод."
    done
}

echo
echo "======================================"
echo " Установщик Xray VLESS Failover"
echo " Entware / Keenetic edition"
echo "======================================"

ensure_packages

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден после установки."; exit 1; }

mkdir -p "$XRAY_DIR" "$TMP_DIR" /opt/var/run /opt/var/log /opt/etc/init.d /opt/bin "$BACKUP_DIR"

create_default_settings
load_settings

echo "Интервал проверки: $CHECK_INTERVAL секунд"
echo "Попыток перед Резервным профилем: $FAILOVER_FAILURES_REQUIRED"
echo "Успешных проверок перед возвратом: $RECOVERY_SUCCESSES_REQUIRED"
echo

if [ -x "$FAILOVER_INIT" ]; then
    echo "Останавливаем старый failover-daemon перед установкой..."
    "$FAILOVER_INIT" stop >/dev/null 2>&1 || true
fi

create_resolver
create_generator
create_xray_init

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

TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"

echo "[3/10] Готовим VLESS-ссылки..."
if [ "$REUSE_FAILOVER" = "1" ] && [ -s "$PRIMARY_STORE" ]; then
    PRIMARY_VLESS="$(cat "$PRIMARY_STORE")"
    if [ -s "$BACKUP_STORE" ]; then
        BACKUP_VLESS="$(cat "$BACKUP_STORE")"
    else
        BACKUP_VLESS=""
    fi
else
    PRIMARY_VLESS="$(prompt_profile_link_main "Основной профиль" "0" "VLESS-ссылка или подписка Основного профиля: " "$ROUTER_LAN_IP" "$SOCKS_PORT" "primary" "$TMP_PRIMARY_CONFIG")"
    BACKUP_VLESS="$(prompt_profile_link_main "Резервный профиль" "1" "VLESS-ссылка или подписка Резервного профиля, опционально: " "127.0.0.1" "$TEMP_BACKUP_PORT" "backup" "$TMP_BACKUP_CONFIG")"
fi

create_failover_daemon
create_status_command
create_xray_core_update_command
create_menu_command
create_failover_update_command
create_failover_installer_update_command
create_failover_init

check_generated_scripts

echo "Проверяем config Основного профиля во временном файле..."
PROFILE_NAME="primary" \
VLESS_URL="$PRIMARY_VLESS" \
LISTEN_HOST="$ROUTER_LAN_IP" \
LISTEN_PORT="$SOCKS_PORT" \
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"

if [ -n "$BACKUP_VLESS" ]; then
    echo "Проверяем config Резервного профиля во временном файле..."
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
echo "Автопроверка после установки:"
"$FAILOVER_STATUS" || true

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
echo "vless-failover-status"
echo "vless-failover-update"
echo "xray-failover-update"
echo "xray-core-update"
echo "failover-installer-update"
echo "xray-failover-installer-update"
echo "$FAILOVER_INIT status|restart|stop|start"
