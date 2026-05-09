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

start_marker = 'cat > "$FAILOVER_UPDATE_CMD" <<\'VUPDATE\'\n'
end_marker = '\nVUPDATE\n\n    chmod +x "$FAILOVER_UPDATE_CMD"'
start = text.index(start_marker)
end = text.index(end_marker, start)

prefix = text[:start + len(start_marker)]
body = text[start + len(start_marker):end]
suffix = text[end:]

if 'Xray post-update check OK' in body:
    print('Already patched')
    raise SystemExit(0)

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

echo "Xray post-update check OK: SOCKS5 $ROUTER_LAN_IP:$SOCKS_PORT"
'''

if anchor not in body:
    print('Target restart anchor not found')
    raise SystemExit(2)

body = body.replace(anchor, insert, 1)
path.write_text(prefix + body + suffix)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Inserted Xray post-update check in $TARGET"
