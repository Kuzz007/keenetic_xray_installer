#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/full/xray_vless_failover.sh"
[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

old = '''echo

echo "Перезапускаем Xray..."
"$INIT_SCRIPT" restart

echo

echo "Перезапускаем failover-сервис..."
'''

new = '''echo

echo "Перезапускаем Xray и проверяем SOCKS5..."
"$INIT_SCRIPT" restart
sleep 3

if ! "$INIT_SCRIPT" status; then
    echo "ОШИБКА: Xray не запустился после обновления ссылок."
    exit 1
fi

if ! netstat -lnt 2>/dev/null | grep -q "$ROUTER_LAN_IP:$SOCKS_PORT"; then
    echo "ОШИБКА: SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT не слушает после перезапуска Xray."
    echo "Проверьте вручную:"
    echo "  /opt/etc/init.d/S24xray restart"
    echo "  /opt/etc/init.d/S24xray status"
    exit 1
fi

echo "Xray запущен, SOCKS5 слушает $ROUTER_LAN_IP:$SOCKS_PORT."

echo

echo "Перезапускаем failover-сервис..."
'''

text = text.replace(old, new)

if text == original:
    print('No vless-failover-update Xray restart block changed.')
    print('Show the relevant lines with:')
    print('  grep -n -A28 -B10 "Перезапускаем Xray" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Update command Xray restart/status/SOCKS check fixed in: $TARGET"
