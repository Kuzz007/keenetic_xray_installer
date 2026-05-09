#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/minimal/xray_vless_failover_minimal.sh"
[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

switch_func = r'''create_switch_command() {
    echo "Создаём команду ручного переключения профиля..."
    cat > "$FAILOVER_SWITCH_CMD" <<'SWITCH'
#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
INIT_SCRIPT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-failover"
GENERATOR="/opt/bin/xray-vless-generate-config-minimal"
PRIMARY_STORE="$XRAY_DIR/vless-primary.url"
BACKUP_STORE="$XRAY_DIR/vless-backup.url"
ACTIVE_STORE="$XRAY_DIR/active-profile"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"
SOCKS_PORT="10808"
PROXY_IFACE="Proxy0"
TMP_DIR="/opt/tmp"
CHECK_URL="https://www.gstatic.com/generate_204"

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

test_socks_endpoint() {
    RESULT="$(curl -k -sS --socks5-hostname "$ROUTER_LAN_IP:$SOCKS_PORT" --connect-timeout 5 --max-time 10 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}' "$CHECK_URL" 2>&1)" && STATUS="0" || STATUS="$?"
    echo "$RESULT"
    HTTP_CODE="$(printf "%s\n" "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"
    [ "$STATUS" = "0" ] && [ "$HTTP_CODE" = "204" ]
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

write_history() {
    EVENT="$1"
    mkdir -p "$(dirname "$HISTORY_LOG")"
    NOW="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    echo "$NOW $EVENT" >> "$HISTORY_LOG"
}

rollback_config() {
    OLD_CONFIG="$1"
    if [ -s "$OLD_CONFIG" ]; then
        echo "Откатываем предыдущий Xray config..."
        cp "$OLD_CONFIG" "$XRAY_CONFIG"
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    fi
}

usage() {
    echo "Использование: $0 primary|backup"
    exit 1
}

TARGET="${1:-}"
case "$TARGET" in
    primary|backup) ;;
    *) usage ;;
esac

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ОШИБКА: xray не найден."; exit 1; }
[ -x "$GENERATOR" ] || { echo "ОШИБКА: генератор не найден: $GENERATOR"; exit 1; }
[ -s "$ROUTER_IP_STORE" ] || { echo "ОШИБКА: LAN-IP не найден: $ROUTER_IP_STORE"; exit 1; }

ROUTER_LAN_IP="$(cat "$ROUTER_IP_STORE")"
mkdir -p "$TMP_DIR"

if [ "$TARGET" = "primary" ]; then
    STORE="$PRIMARY_STORE"
else
    STORE="$BACKUP_STORE"
fi

[ -s "$STORE" ] || { echo "ОШИБКА: ссылка профиля не найдена: $STORE"; exit 1; }
URL="$(cat "$STORE")"
TARGET_LABEL="$(profile_display_name "$TARGET")"
TMP_CONFIG="$TMP_DIR/xray-manual-switch-$TARGET.json"
OLD_CONFIG="$TMP_DIR/xray-config-before-manual-switch.json"

echo "======================================"
echo "РУЧНОЕ ПЕРЕКЛЮЧЕНИЕ ПРОФИЛЯ -> $TARGET_LABEL"
echo "======================================"

[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" stop >/dev/null 2>&1 || true

echo "[1/5] Генерируем config..."
PROFILE_NAME="$TARGET" VLESS_URL="$URL" LISTEN_HOST="$ROUTER_LAN_IP" LISTEN_PORT="$SOCKS_PORT" OUTPUT_CONFIG="$TMP_CONFIG" "$GENERATOR"

echo "[2/5] Проверяем config..."
test_xray_config "$TMP_CONFIG"

cp "$XRAY_CONFIG" "$OLD_CONFIG" 2>/dev/null || true

echo "[3/5] Применяем config и перезапускаем Xray..."
cp "$TMP_CONFIG" "$XRAY_CONFIG"
if ! "$INIT_SCRIPT" restart; then
    echo "ОШИБКА: Xray не запустился после ручного переключения."
    rollback_config "$OLD_CONFIG"
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

echo "[4/5] Проверяем SOCKS5..."
if ! wait_for_socks_port || ! test_socks_endpoint; then
    echo "ОШИБКА: SOCKS5 не прошёл проверку после ручного переключения."
    rollback_config "$OLD_CONFIG"
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

echo "[5/5] Перезапускаем Proxy0 и failover..."
restart_proxy0
printf "%s\n" "$TARGET" > "$ACTIVE_STORE"
write_history "manual-switch target=$TARGET"
[ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start || true

echo "Активный профиль теперь: $TARGET_LABEL"
SWITCH
    chmod +x "$FAILOVER_SWITCH_CMD"
}
'''

switch_re = re.compile(r'create_switch_command\(\) \{.*?\n\}\n\ncreate_failover_update_command\(\) \{', re.S)
text, count_switch = switch_re.subn(switch_func + '\ncreate_failover_update_command() {', text, count=1)
if count_switch != 1:
    print('ERROR: create_switch_command block not replaced')
    raise SystemExit(2)

update_heredoc_re = re.compile(r'(cat > "\$FAILOVER_UPDATE_CMD" <<\'VUPDATE\'\n)(.*?)(\nVUPDATE\n\s*chmod \+x "\$FAILOVER_UPDATE_CMD")', re.S)
match = update_heredoc_re.search(text)
if not match:
    print('ERROR: FAILOVER_UPDATE_CMD heredoc not found')
    raise SystemExit(2)

prefix, body, suffix = match.groups()
if 'Minimal post-update check OK' not in body:
    anchor = '''if ! "$INIT_SCRIPT" restart; then
    echo "ОШИБКА: Xray не перезапустился. Откатываем старый config."
    [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
    "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi
'''
    insert = anchor + '''
sleep 3

if ! "$INIT_SCRIPT" status; then
    echo "ОШИБКА: Xray не запустился после обновления ссылок. Откатываем старый config."
    [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
    "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

if ! netstat -lnt 2>/dev/null | grep -q "$ROUTER_LAN_IP:$SOCKS_PORT" && ! netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT"; then
    echo "ОШИБКА: SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT не слушает после обновления ссылок. Откатываем старый config."
    [ -s "$OLD_CONFIG" ] && cp "$OLD_CONFIG" "$XRAY_CONFIG"
    "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
    [ -x "$FAILOVER_INIT" ] && "$FAILOVER_INIT" start >/dev/null 2>&1 || true
    exit 1
fi

echo "Minimal post-update check OK: SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT"
'''
    if anchor not in body:
        print('ERROR: minimal update restart anchor not found')
        raise SystemExit(2)
    body = body.replace(anchor, insert, 1)
    text = text[:match.start()] + prefix + body + suffix + text[match.end():]
else:
    print('Update command already has post-check')

if text == original:
    print('No changes made')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Minimal switch and update checks patched in: $TARGET"
