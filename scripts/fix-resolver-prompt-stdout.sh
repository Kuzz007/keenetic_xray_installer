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

old = '''while True:
    try:
        choice = input("Выберите номер профиля: ").strip()
    except EOFError:
        print(links[0])
        raise SystemExit(0)
    if choice.isdigit() and 1 <= int(choice) <= len(links):
        print(links[int(choice)-1])
        raise SystemExit(0)
    print("Введите корректный номер профиля.", file=sys.stderr)
'''

new = '''while True:
    print("Выберите номер профиля: ", end="", file=sys.stderr, flush=True)
    try:
        choice = sys.stdin.readline()
    except Exception:
        choice = ""
    if not choice:
        print(links[0])
        raise SystemExit(0)
    choice = choice.strip()
    if choice.isdigit() and 1 <= int(choice) <= len(links):
        print(links[int(choice)-1])
        raise SystemExit(0)
    print("Введите корректный номер профиля.", file=sys.stderr)
'''

text = text.replace(old, new)

if text == original:
    print('No resolver prompt block changed.')
    print('Show the relevant lines with:')
    print('  grep -n -A12 -B8 "Выберите номер профиля" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Resolver prompt stdout fixed in: $TARGET"
