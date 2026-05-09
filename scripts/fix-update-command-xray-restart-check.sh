#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/full/xray_vless_failover.sh"
[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

new_restart = '''echo

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

heredoc_re = re.compile(r'(cat > "\$FAILOVER_UPDATE_CMD" <<\'VUPDATE\'\n)(.*?)(\nVUPDATE\n\n    chmod \+x "\$FAILOVER_UPDATE_CMD")', re.S)
match = heredoc_re.search(text)
if not match:
    print('No FAILOVER_UPDATE_CMD heredoc found.')
    raise SystemExit(2)

prefix, body, suffix = match.groups()

if 'Перезапускаем Xray и проверяем SOCKS5' in body:
    print('Update command already contains Xray restart/status/SOCKS check.')
    raise SystemExit(0)

restart_re = re.compile(
    r'echo\s*\n\s*echo "Перезапускаем Xray\.\.\."\s*\n\s*"\$INIT_SCRIPT" restart\s*\n\s*echo\s*\n\s*echo "Перезапускаем failover-сервис\.\.\."',
    re.S,
)

new_body, count = restart_re.subn(new_restart.rstrip(), body, count=1)
if count != 1:
    print('No Xray restart block found inside FAILOVER_UPDATE_CMD heredoc.')
    print('Show the relevant lines with:')
    print('  grep -n -A35 -B10 "Перезапускаем Xray" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

text = text[:match.start()] + prefix + new_body + suffix + text[match.end():]

if text == original:
    print('No changes made.')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Update command Xray restart/status/SOCKS check fixed in: $TARGET"
