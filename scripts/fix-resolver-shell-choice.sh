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

resolver = r'''#!/bin/sh
set -e

MODE="${1:-interactive}"
SOURCE_VALUE="${2:-}"
PROFILE_LABEL="${3:-профиль}"
TMP_LINKS="/opt/tmp/xray-resolver-links.$$"

cleanup() {
    rm -f "$TMP_LINKS" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ -z "$SOURCE_VALUE" ]; then
    echo "ОШИБКА: пустая ссылка." >&2
    exit 1
fi

mkdir -p /opt/tmp 2>/dev/null || true

set +e
python3 - "$MODE" "$SOURCE_VALUE" "$PROFILE_LABEL" "$TMP_LINKS" <<'PYRESOLVER'
import base64
import re
import sys
import urllib.parse
import urllib.request

mode, value, profile_label, links_path = sys.argv[1], sys.argv[2].strip(), sys.argv[3], sys.argv[4]

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
    print("ОШИБКА: нужен формат vless:// или http(s) ссылка подписки", file=sys.stderr)
    raise SystemExit(1)

try:
    payload = download_subscription(value)
except Exception as exc:
    print(f"ОШИБКА: не удалось скачать подписку: {exc}", file=sys.stderr)
    raise SystemExit(1)

links = []
for text in decode_variants(payload):
    for link in extract_vless_links(text):
        if link not in links:
            links.append(link)

if not links:
    print("ОШИБКА: в подписке не найдено vless:// ссылок", file=sys.stderr)
    raise SystemExit(1)

if len(links) == 1 or mode != "interactive":
    print(links[0])
    raise SystemExit(0)

with open(links_path, "w", encoding="utf-8") as f:
    for link in links:
        f.write(link + "\n")

print(f"В подписке для профиля {profile_label} найдено VLESS-профилей: {len(links)}", file=sys.stderr)
for i, link in enumerate(links, 1):
    print(label_for(link, i), file=sys.stderr)

raise SystemExit(20)
PYRESOLVER
STATUS="$?"
set -e

if [ "$STATUS" -eq 0 ]; then
    exit 0
fi

if [ "$STATUS" -ne 20 ]; then
    exit "$STATUS"
fi

COUNT="$(wc -l < "$TMP_LINKS" | tr -d ' ')"

while true; do
    if [ -r /dev/tty ]; then
        printf "Выберите номер профиля: " >/dev/tty
        IFS= read -r CHOICE </dev/tty || CHOICE=""
    else
        printf "Выберите номер профиля: " >&2
        IFS= read -r CHOICE || CHOICE=""
    fi

    case "$CHOICE" in
        '' )
            echo "ОШИБКА: номер профиля не введён." >&2
            exit 1
            ;;
        *[!0-9]* )
            echo "Введите корректный номер профиля." >&2
            ;;
        * )
            if [ "$CHOICE" -ge 1 ] 2>/dev/null && [ "$CHOICE" -le "$COUNT" ] 2>/dev/null; then
                sed -n "${CHOICE}p" "$TMP_LINKS"
                exit 0
            fi
            echo "Введите номер от 1 до $COUNT." >&2
            ;;
    esac
done
'''

pattern = r"cat > \"\$RESOLVER\" <<'RESOLVE'\n.*?\nRESOLVE\n\n    chmod \+x \"\$RESOLVER\""
replacement = "cat > \"$RESOLVER\" <<'RESOLVE'\n" + resolver + "RESOLVE\n\n    chmod +x \"$RESOLVER\""
text = re.sub(pattern, replacement, text, count=1, flags=re.S)

if text == original:
    print('No resolver heredoc changed.')
    print('Show create_resolver block manually.')
    raise SystemExit(2)

path.write_text(text)
print(f'Patched: {path}')
PY

sh -n "$TARGET"
echo "Resolver shell choice fixed in: $TARGET"
