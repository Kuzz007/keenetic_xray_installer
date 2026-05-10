#!/bin/sh
set -e

XRAY_REPO="XTLS/Xray-core"
XRAY_CONFIG="/opt/etc/xray/config.json"
XRAY_INIT="/opt/etc/init.d/S24xray"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
TMP_DIR="/opt/tmp/vless-go-xray-core-update.$$"
BACKUP_DIR="/opt/etc/xray/backups"
CHANNEL=""
ASSUME_YES="0"
NO_RESTART="0"

usage() {
    echo "Usage: vless-go-xray-core-update [--channel stable|latest|prerelease] [--yes] [--no-restart]"
    echo ""
    echo "Options:"
    echo "  --channel VALUE   Release channel: stable/latest or prerelease."
    echo "  --yes             Non-interactive confirmation."
    echo "  --no-restart      Download, verify, and replace binary but do not start services."
}

read_tty() {
    PROMPT="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$PROMPT" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$PROMPT" >&2
        IFS= read -r REPLY
    fi
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
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

normalize_arch_asset() {
    ARCH="$(uname -m 2>/dev/null || echo unknown)"
    case "$ARCH" in
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7*) echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l|armv6*) echo "Xray-linux-arm32-v6.zip" ;;
        mipsel|mipsle) echo "Xray-linux-mips32le.zip" ;;
        mips) echo "Xray-linux-mips32.zip" ;;
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        i386|i686) echo "Xray-linux-32.zip" ;;
        *) echo "ERROR: unsupported architecture: $ARCH" >&2; exit 1 ;;
    esac
}

json_field_first() {
    FILE="$1"
    FIELD="$2"
    grep -m 1 '"'"$FIELD"'"[[:space:]]*:' "$FILE" | sed 's/.*"'"$FIELD"'"[[:space:]]*:[[:space:]]*"//; s/".*//'
}

find_first_prerelease_tag() {
    FILE="$1"
    awk '
        /"tag_name"[[:space:]]*:/ {
            line=$0
            sub(/.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*/, "", line)
            tag=line
        }
        /"prerelease"[[:space:]]*:[[:space:]]*true/ {
            if (tag != "") {
                print tag
                exit
            }
        }
    ' "$FILE"
}

stop_services() {
    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" stop || true
    fi
    if [ -x "$XRAY_INIT" ]; then
        "$XRAY_INIT" stop || true
    fi
}

start_services() {
    if [ -x "$XRAY_INIT" ]; then
        "$XRAY_INIT" start || return 1
    fi
    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" start || true
    fi
}

rollback() {
    echo "ROLLBACK: restoring previous Xray binary..." >&2
    if [ -n "${BACKUP_BIN:-}" ] && [ -s "$BACKUP_BIN" ] && [ -n "${XRAY_BIN:-}" ]; then
        cp "$BACKUP_BIN" "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
    fi
    start_services || true
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --channel)
            [ "$#" -ge 2 ] || { echo "ERROR: --channel requires value" >&2; exit 1; }
            CHANNEL="$2"
            shift 2
            ;;
        --yes|-y)
            ASSUME_YES="1"
            shift
            ;;
        --no-restart)
            NO_RESTART="1"
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

need_cmd curl
need_cmd unzip

if [ -z "$CHANNEL" ]; then
    echo "Choose Xray-core update channel:"
    echo "1. Stable/latest"
    echo "2. Pre-release"
    echo "0. Cancel"
    read_tty "Choose: "
    case "$REPLY" in
        1) CHANNEL="latest" ;;
        2) CHANNEL="prerelease" ;;
        0|'') echo "Canceled."; exit 0 ;;
        *) echo "ERROR: unknown choice: $REPLY" >&2; exit 1 ;;
    esac
fi

mkdir -p "$TMP_DIR" "$BACKUP_DIR"
trap 'rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT INT TERM

XRAY_BIN="$(get_xray_bin)"
[ -n "$XRAY_BIN" ] || { echo "ERROR: xray binary not found" >&2; exit 1; }

ASSET_NAME="$(normalize_arch_asset)"
RELEASE_JSON="$TMP_DIR/release.json"
ZIP_FILE="$TMP_DIR/xray.zip"
UNPACK_DIR="$TMP_DIR/unpack"
mkdir -p "$UNPACK_DIR"

echo "Current Xray binary: $XRAY_BIN"
"$XRAY_BIN" version 2>/dev/null | sed -n '1,2p' || true

echo "Fetching Xray-core release metadata: channel=$CHANNEL"
case "$CHANNEL" in
    stable|latest)
        curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vless-go-xray-core-update' \
            -o "$RELEASE_JSON" "https://api.github.com/repos/$XRAY_REPO/releases/latest"
        TAG="$(json_field_first "$RELEASE_JSON" tag_name)"
        NAME="$(json_field_first "$RELEASE_JSON" name)"
        [ -n "$TAG" ] || TAG="latest"
        URL="https://github.com/$XRAY_REPO/releases/latest/download/$ASSET_NAME"
        ;;
    prerelease|pre-release|pre)
        curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vless-go-xray-core-update' \
            -o "$RELEASE_JSON" "https://api.github.com/repos/$XRAY_REPO/releases"
        TAG="$(find_first_prerelease_tag "$RELEASE_JSON")"
        if [ -z "$TAG" ]; then
            echo "No Xray-core pre-release was found in GitHub Releases API response."
            echo "Use Stable/latest instead, or check: https://github.com/XTLS/Xray-core/releases"
            exit 0
        fi
        NAME="$TAG"
        URL="https://github.com/$XRAY_REPO/releases/download/$TAG/$ASSET_NAME"
        ;;
    *)
        echo "ERROR: unsupported channel: $CHANNEL" >&2
        exit 1
        ;;
esac

echo "Selected release: $TAG ${NAME:-}"
echo "Selected asset: $ASSET_NAME"
echo "Download URL: $URL"

if [ "$ASSUME_YES" != "1" ]; then
    read_tty "Proceed with Xray-core update? [y/N]: "
    case "$REPLY" in
        y|Y|yes|YES) ;;
        *) echo "Canceled."; exit 0 ;;
    esac
fi

echo "Downloading asset..."
if ! curl -fL -o "$ZIP_FILE" "$URL"; then
    echo "ERROR: failed to download asset: $ASSET_NAME" >&2
    echo "Release URL: https://github.com/$XRAY_REPO/releases/tag/$TAG" >&2
    exit 1
fi

echo "Unpacking asset..."
unzip -o "$ZIP_FILE" -d "$UNPACK_DIR" >/dev/null
NEW_XRAY="$(find "$UNPACK_DIR" -type f -name xray | sed -n '1p')"
[ -n "$NEW_XRAY" ] && [ -s "$NEW_XRAY" ] || { echo "ERROR: xray binary not found inside archive" >&2; exit 1; }
chmod +x "$NEW_XRAY"

echo "New Xray version:"
"$NEW_XRAY" version | sed -n '1,2p'

echo "Testing new Xray with current config before replacing..."
if [ -s "$XRAY_CONFIG" ]; then
    "$NEW_XRAY" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1 || "$NEW_XRAY" test -config "$XRAY_CONFIG"
else
    echo "WARNING: config not found: $XRAY_CONFIG" >&2
fi

STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_BIN="$BACKUP_DIR/xray.$STAMP.bak"
echo "Backing up current binary to: $BACKUP_BIN"
cp "$XRAY_BIN" "$BACKUP_BIN"
chmod 600 "$BACKUP_BIN" 2>/dev/null || true

if [ "$NO_RESTART" != "1" ]; then
    echo "Stopping services..."
    stop_services
fi

set +e
cp "$NEW_XRAY" "$XRAY_BIN"
chmod +x "$XRAY_BIN"
REPLACE_RC="$?"
set -e
if [ "$REPLACE_RC" != "0" ]; then
    rollback
    exit 1
fi

echo "Installed Xray version:"
"$XRAY_BIN" version | sed -n '1,2p'

if [ -s "$XRAY_CONFIG" ]; then
    echo "Validating installed Xray config..."
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        if ! "$XRAY_BIN" test -config "$XRAY_CONFIG"; then
            rollback
            exit 1
        fi
    fi
fi

if [ "$NO_RESTART" = "1" ]; then
    echo "Services were not restarted because --no-restart was used."
    echo "Xray-core update completed."
    exit 0
fi

echo "Starting services..."
if ! start_services; then
    rollback
    exit 1
fi

if [ -x "$XRAY_INIT" ]; then
    if ! "$XRAY_INIT" status >/dev/null 2>&1; then
        rollback
        exit 1
    fi
fi

echo "Xray-core update completed successfully."
echo "Backup binary: $BACKUP_BIN"
