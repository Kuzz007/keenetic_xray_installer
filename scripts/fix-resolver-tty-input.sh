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

new = '''tty = None
try:
    tty = open("/dev/tty", "r+", encoding="utf-8", errors="ignore")
except Exception:
    tty = None

while True:
    prompt_stream = tty if tty is not None else sys.stderr
    print("Выберите номер профиля: ", end="", file=prompt_stream, flush=True)
    try:
        choice = tty.readline() if tty is not None else sys.stdin.readline()
    except Exception:
        choice = ""
    if not choice:
        print(links[0])
        raise SystemExit(0)
    choice = choice.strip()
    if choice.isdigit() and 1 <= int(choice) <= len(links):
        print(links[int(choice)-1])
        raise SystemExit(0)
    print("Введите корректный номер профиля.", file=prompt_stream, flush=True)
'''

text = text.replace(old, new)

if text == original:
    print('No resolver stdin block changed.')
    print('Show the relevant lines with:')
    print('  grep -n -A22 -B8 "Выберите номер профиля" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Resolver tty input fixed in: $TARGET"
