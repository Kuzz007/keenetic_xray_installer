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

# The installer already generates temporary JSON configs before this stage.
# The validation step must test those JSON configs with xray, not call the
# VLESS/subscription generator again. Calling the generator with a JSON path
# produces: ERROR: expected vless:// link or http(s) subscription link.

replacements = [
    (
        r'(echo "Проверяем config Основного профиля во временном файле\.\.\."\n)'
        r'\s*if ! generate_profile_config [^\n]*; then',
        r'\1if ! test_xray_config "$TMP_PRIMARY_CONFIG" >/dev/null; then',
    ),
    (
        r'(echo "Проверяем config Резервного профиля во временном файле\.\.\."\n)'
        r'\s*if ! generate_profile_config [^\n]*; then',
        r'\1if ! test_xray_config "$TMP_BACKUP_CONFIG" >/dev/null; then',
    ),
]

for pattern, replacement in replacements:
    text = re.sub(pattern, replacement, text, flags=re.MULTILINE)

# Fallback for older/newer variable names used in the monolithic installer.
# Match a small block after the exact Russian marker and replace only the if line.
def replace_after_marker(text: str, marker: str, config_expr: str) -> str:
    idx = text.find(marker)
    if idx == -1:
        return text

    next_marker = text.find('\necho "Проверяем config ', idx + len(marker))
    if next_marker == -1:
        next_marker = text.find('\nconfigure_proxy0', idx + len(marker))
    if next_marker == -1:
        next_marker = text.find('\n#', idx + len(marker))
    if next_marker == -1:
        next_marker = len(text)

    block = text[idx:next_marker]
    new_block = re.sub(
        r'if ! generate_profile_config [^\n]*; then',
        f'if ! test_xray_config "{config_expr}" >/dev/null; then',
        block,
        count=1,
    )
    return text[:idx] + new_block + text[next_marker:]

text = replace_after_marker(
    text,
    'echo "Проверяем config Основного профиля во временном файле..."',
    '$TMP_PRIMARY_CONFIG',
)
text = replace_after_marker(
    text,
    'echo "Проверяем config Резервного профиля во временном файле..."',
    '$TMP_BACKUP_CONFIG',
)

if text == original:
    print('No install config validation pattern changed.')
    print('Show the relevant lines with:')
    print('  grep -n -A12 -B6 "Проверяем config" src/full/xray_vless_failover.sh')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"

echo "Install config validation fixed in: $TARGET"
