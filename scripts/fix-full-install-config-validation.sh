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

primary_old = '''echo "Проверяем config Основного профиля во временном файле..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
PROFILE_NAME="primary" \\
VLESS_URL="$PRIMARY_VLESS" \\
LISTEN_HOST="$ROUTER_LAN_IP" \\
LISTEN_PORT="$SOCKS_PORT" \\
OUTPUT_CONFIG="$TMP_PRIMARY_CONFIG" \\
"$GENERATOR"

test_xray_config "$TMP_PRIMARY_CONFIG"
'''

primary_new = '''echo "Проверяем config Основного профиля во временном файле..."
TMP_PRIMARY_CONFIG="$TMP_DIR/xray-install-primary.json"
[ -s "$TMP_PRIMARY_CONFIG" ] || { echo "ОШИБКА: временный config Основного профиля не найден: $TMP_PRIMARY_CONFIG"; exit 1; }
test_xray_config "$TMP_PRIMARY_CONFIG"
'''

backup_old = '''    echo "Проверяем config Резервного профиля во временном файле..."
    TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"
    PROFILE_NAME="backup" \\
    VLESS_URL="$BACKUP_VLESS" \\
    LISTEN_HOST="127.0.0.1" \\
    LISTEN_PORT="$TEMP_BACKUP_PORT" \\
    OUTPUT_CONFIG="$TMP_BACKUP_CONFIG" \\
    "$GENERATOR"

    test_xray_config "$TMP_BACKUP_CONFIG"
'''

backup_new = '''    echo "Проверяем config Резервного профиля во временном файле..."
    TMP_BACKUP_CONFIG="$TMP_DIR/xray-install-backup.json"
    [ -s "$TMP_BACKUP_CONFIG" ] || { echo "ОШИБКА: временный config Резервного профиля не найден: $TMP_BACKUP_CONFIG"; exit 1; }
    test_xray_config "$TMP_BACKUP_CONFIG"
'''

text = text.replace(primary_old, primary_new)
text = text.replace(backup_old, backup_new)

if text == original:
    print('No direct generator validation block changed.')
    print('Show the relevant lines with:')
    print('  grep -n -A16 -B6 "Проверяем config" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"

echo "Install config validation fixed in: $TARGET"
