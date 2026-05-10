#!/bin/sh
set -e

XRAY_REPO="XTLS/Xray-core"
XRAY_CONFIG="/opt/etc/xray/config.json"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
TMP_DIR="/opt/tmp/vless-go-xray-core-update.$$"
BACKUP_DIR="/opt/etc/xray/backups"
RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases"
LATEST_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
CHANNEL=""
TAG_OVERRIDE=""
ASSUME_YES="0"
NO_RESTART="0"
BACKUP_ENABLED=""

usage() {
    echo "Usage: vless-go-xray-core-update [--channel stable|latest|prerelease] [--tag vX.Y.Z] [--yes] [--no-restart] [--backup|--no-backup]"
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

opkg_install_if_missing() {
    cmd="$1"
    pkg="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    echo "$cmd not found. Trying to install $pkg via opkg..."
    command -v opkg >/dev/null 2>&1 || { echo "ERROR: $cmd not found and opkg unavailable." >&2; exit 1; }
    opkg update
    opkg install "$pkg"
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: failed to install $pkg." >&2; exit 1; }
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo "/opt/sbin/xray"
    elif [ -x /opt/bin/xray ]; then
        echo "/opt/bin/xray"
    else
        echo ""
    fi
}

detect_asset_name() {
    ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$ARCH" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i486|i586|i686) echo "Xray-linux-32.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*|armv8l) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
        armv5*|arm) echo "Xray-linux-arm32-v5.zip" ;;
        mips64el|mips64le) echo "Xray-linux-mips64le.zip" ;;
        mips64) echo "Xray-linux-mips64.zip" ;;
        mipsel|mipsle) echo "Xray-linux-mips32le.zip" ;;
        mips) echo "Xray-linux-mips32.zip" ;;
        riscv64) echo "Xray-linux-riscv64.zip" ;;
        *) echo "" ;;
    esac
}

select_release_json() {
    mode="$1"
    out_json="$2"
    all_json="$TMP_DIR/releases.json"

    if [ -n "$TAG_OVERRIDE" ]; then
        curl -fsSL -H "User-Agent: vless-go-xray-core-update" -o "$out_json" "https://api.github.com/repos/$XRAY_REPO/releases/tags/$TAG_OVERRIDE"
        return 0
    fi

    if [ "$mode" = "stable" ] || [ "$mode" = "latest" ]; then
        curl -fsSL -H "User-Agent: vless-go-xray-core-update" -o "$out_json" "$LATEST_API"
        return 0
    fi

    curl -fsSL -H "User-Agent: vless-go-xray-core-update" -o "$all_json" "$RELEASES_API?per_page=100"
    python3 - "$all_json" "$out_json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'r', encoding='utf-8') as f:
    releases = json.load(f)
for release in releases:
    if release.get('prerelease') and not release.get('draft'):
        with open(dst, 'w', encoding='utf-8') as out:
            json.dump(release, out)
        print(release.get('tag_name', ''), file=sys.stderr)
        break
else:
    raise SystemExit('No Xray-core pre-release found in GitHub releases')
PY
}

json_field() {
    json_file="$1"
    field="$2"
    python3 - "$json_file" "$field" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get(sys.argv[2], '') or '')
PY
}

asset_url() {
    json_file="$1"
    asset_name="$2"
    python3 - "$json_file" "$asset_name" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    data = json.load(f)
needle = sys.argv[2]
for asset in data.get('assets', []):
    if asset.get('name') == needle:
        print(asset.get('browser_download_url', '') or '')
        break
PY
}

stop_services() {
    [ -x "$WATCHDOG_INIT" ] && "$WATCHDOG_INIT" stop || true
    [ -x "$XRAY_INIT" ] && "$XRAY_INIT" stop || true
}

start_services() {
    [ -x "$XRAY_INIT" ] && "$XRAY_INIT" start || return 1
    [ -x "$WATCHDOG_INIT" ] && "$WATCHDOG_INIT" start || true
}

rollback() {
    if [ -n "${BACKUP_BIN:-}" ] && [ -s "$BACKUP_BIN" ]; then
        echo "ROLLBACK: restoring previous Xray binary..." >&2
        cp "$BACKUP_BIN" "$XRAY_BIN" && chmod +x "$XRAY_BIN"
    else
        echo "ROLLBACK: no backup binary available; manual recovery may be required." >&2
    fi
    start_services || true
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="$2"; shift 2 ;;
        --tag) TAG_OVERRIDE="$2"; CHANNEL="tag"; shift 2 ;;
        --yes|-y) ASSUME_YES="1"; shift ;;
        --no-restart) NO_RESTART="1"; shift ;;
        --backup) BACKUP_ENABLED="1"; shift ;;
        --no-backup) BACKUP_ENABLED="0"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

need_cmd curl
opkg_install_if_missing python3 python3
opkg_install_if_missing unzip unzip

if [ -z "$CHANNEL" ]; then
    echo "Choose Xray-core update channel:"
    echo "1. Stable/latest"
    echo "2. Pre-release"
    echo "3. Specific tag"
    echo "0. Cancel"
    read_tty "Choose: "
    case "$REPLY" in
        1) CHANNEL="latest" ;;
        2) CHANNEL="prerelease" ;;
        3) read_tty "Enter tag, for example v26.5.9: "; TAG_OVERRIDE="$REPLY"; CHANNEL="tag" ;;
        0|'') echo "Canceled."; exit 0 ;;
        *) echo "ERROR: unknown choice: $REPLY" >&2; exit 1 ;;
    esac
fi

if [ -z "$BACKUP_ENABLED" ]; then
    if [ "$ASSUME_YES" = "1" ]; then
        BACKUP_ENABLED="1"
    else
        echo ""
        echo "Create backup of current Xray binary before update?"
        echo "Backup enables automatic rollback if the new binary fails."
        read_tty "Create backup? [Y/n]: "
        case "$REPLY" in
            n|N|no|NO) BACKUP_ENABLED="0" ;;
            *) BACKUP_ENABLED="1" ;;
        esac
    fi
fi

if [ "$BACKUP_ENABLED" = "0" ]; then
    echo "WARNING: Xray binary backup is disabled. Automatic binary rollback will not be available."
    if [ "$ASSUME_YES" != "1" ]; then
        read_tty "Continue without backup? [y/N]: "
        case "$REPLY" in y|Y|yes|YES) ;; *) echo "Canceled."; exit 0 ;; esac
    fi
fi

mkdir -p "$TMP_DIR" "$BACKUP_DIR"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT INT TERM

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ERROR: xray binary not found" >&2; exit 1; }
ASSET_NAME="$(detect_asset_name)"
[ -n "$ASSET_NAME" ] || { echo "ERROR: unsupported architecture: $(uname -m 2>/dev/null || echo unknown)" >&2; exit 1; }

RELEASE_JSON="$TMP_DIR/release.json"
ZIP_FILE="$TMP_DIR/$ASSET_NAME"
UNPACK_DIR="$TMP_DIR/unpack"
mkdir -p "$UNPACK_DIR"

echo "Current Xray binary: $XRAY_BIN"
"$XRAY_BIN" version 2>/dev/null | sed -n '1,2p' || true

echo "Fetching Xray-core release metadata: channel=$CHANNEL"
select_release_json "$CHANNEL" "$RELEASE_JSON"
TAG="$(json_field "$RELEASE_JSON" tag_name)"
NAME="$(json_field "$RELEASE_JSON" name)"
URL="$(asset_url "$RELEASE_JSON" "$ASSET_NAME")"

[ -n "$URL" ] || { echo "ERROR: asset not found: $ASSET_NAME in release $TAG" >&2; exit 1; }

echo "Selected release: ${NAME:-$TAG}"
echo "Selected tag: $TAG"
echo "Selected asset: $ASSET_NAME"
echo "Download URL: $URL"
echo "Backup current binary: $BACKUP_ENABLED"

if [ "$ASSUME_YES" != "1" ]; then
    read_tty "Proceed with Xray-core update? [y/N]: "
    case "$REPLY" in y|Y|yes|YES) ;; *) echo "Canceled."; exit 0 ;; esac
fi

echo "Downloading asset..."
curl -fL -H "User-Agent: vless-go-xray-core-update" -o "$ZIP_FILE" "$URL"

echo "Unpacking asset..."
unzip -oq "$ZIP_FILE" -d "$UNPACK_DIR"
NEW_XRAY="$(find "$UNPACK_DIR" -type f -name xray | sed -n '1p')"
[ -s "$NEW_XRAY" ] || { echo "ERROR: xray binary not found inside archive" >&2; exit 1; }
chmod +x "$NEW_XRAY"

echo "New Xray version:"
"$NEW_XRAY" version | sed -n '1,2p'

echo "Testing new Xray with current config before replacing..."
if [ -s "$XRAY_CONFIG" ]; then
    "$NEW_XRAY" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || "$NEW_XRAY" test -config "$XRAY_CONFIG"
fi

BACKUP_BIN=""
if [ "$BACKUP_ENABLED" = "1" ]; then
    BACKUP_BIN="$BACKUP_DIR/xray.$(date '+%Y%m%d-%H%M%S').bak"
    echo "Backing up current binary to: $BACKUP_BIN"
    cp "$XRAY_BIN" "$BACKUP_BIN"
    chmod 600 "$BACKUP_BIN" 2>/dev/null || true
else
    echo "Skipping Xray binary backup by user request."
fi

if [ "$NO_RESTART" != "1" ]; then
    echo "Stopping services..."
    stop_services
fi

if ! cp "$NEW_XRAY" "$XRAY_BIN" || ! chmod +x "$XRAY_BIN"; then
    rollback
    exit 1
fi

echo "Installed Xray version:"
"$XRAY_BIN" version | sed -n '1,2p'

if [ -s "$XRAY_CONFIG" ]; then
    echo "Validating installed Xray config..."
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        "$XRAY_BIN" test -config "$XRAY_CONFIG" || { rollback; exit 1; }
    fi
fi

if [ "$NO_RESTART" = "1" ]; then
    echo "Services were not restarted because --no-restart was used."
    echo "Xray-core update completed."
    [ -n "$BACKUP_BIN" ] && echo "Backup binary: $BACKUP_BIN"
    exit 0
fi

echo "Starting services..."
start_services || { rollback; exit 1; }
[ -x "$XRAY_INIT" ] && "$XRAY_INIT" status >/dev/null 2>&1 || { rollback; exit 1; }

echo "Xray-core update completed successfully."
[ -n "$BACKUP_BIN" ] && echo "Backup binary: $BACKUP_BIN"
