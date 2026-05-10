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
    prompt="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

json_get() {
    FILE="$1"
    EXPR="$2"
    if command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$FILE" -e "$EXPR" 2>/dev/null || true
    else
        return 1
    fi
}

extract_release_field() {
    FILE="$1"
    FIELD="$2"
    VALUE="$(json_get "$FILE" "@.$FIELD" 2>/dev/null || true)"
    if [ -n "$VALUE" ]; then
        printf '%s\n' "$VALUE"
        return 0
    fi
    grep -m 1 '"'"$FIELD"'"[[:space:]]*:' "$FILE" | sed 's/.*: *//; s/^"//; s/",*$//; s/"$//'
}

sanitize_release_field() {
    VALUE="$1"
    case "$VALUE" in
        ''|*'{'*|*'}'*|*':'*|*','*) return 1 ;;
        *) printf '%s\n' "$VALUE" ;;
    esac
}

list_asset_names() {
    FILE="$1"
    grep '"name"[[:space:]]*:' "$FILE" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//; s/".*//' | grep '^Xray-.*\.zip$' || true
}

extract_asset_url() {
    FILE="$1"
    PATTERN="$2"
    if command -v jsonfilter >/dev/null 2>&1; then
        URL="$(jsonfilter -i "$FILE" -e "@.assets[@.name='$PATTERN'].browser_download_url" 2>/dev/null || true)"
        if [ -n "$URL" ]; then
            printf '%s\n' "$URL" | sed -n '1p'
            return 0
        fi
    fi

    awk -v pat="$PATTERN" '
        /"name"[[:space:]]*:/ {
            line=$0
            gsub(/.*"name"[[:space:]]*:[[:space:]]*"/, "", line)
            gsub(/".*/, "", line)
            name=line
        }
        /"browser_download_url"[[:space:]]*:/ {
            url=$0
            gsub(/.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", url)
            gsub(/".*/, "", url)
            if (name == pat) {
                print url
                exit
            }
        }
    ' "$FILE"
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

fetch_release_json() {
    CHANNEL_VALUE="$1"
    OUT="$2"
    case "$CHANNEL_VALUE" in
        stable|latest)
            URL="https://api.github.com/repos/$XRAY_REPO/releases/latest"
            curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vless-go-xray-core-update' -o "$OUT" "$URL"
            ;;
        prerelease|pre-release|pre)
            URL="https://api.github.com/repos/$XRAY_REPO/releases"
            ALL="$OUT.all"
            curl -fsSL -H 'Accept: application/vnd.github+json' -H 'User-Agent: vless-go-xray-core-update' -o "$ALL" "$URL"
            if command -v jsonfilter >/dev/null 2>&1; then
                ID="$(jsonfilter -i "$ALL" -e '@[@.prerelease=true][0].id' 2>/dev/null || true)"
                if [ -n "$ID" ]; then
                    awk -v id="$ID" '
                        BEGIN { found=0 }
                        /"id"[[:space:]]*:[[:space:]]*/ && $0 ~ id { found=1 }
                        found { print }
                        found && /^  \}/ { exit }
                    ' "$ALL" > "$OUT"
                fi
            fi
            if [ ! -s "$OUT" ]; then
                awk '
                    BEGIN { inobj=0; buf=""; pre=0 }
                    /^  \{/ { inobj=1; buf=$0 "\n"; pre=0; next }
                    inobj {
                        buf = buf $0 "\n"
                        if ($0 ~ /"prerelease"[[:space:]]*:[[:space:]]*true/) pre=1
                        if ($0 ~ /^  \}/) {
                            if (pre) { printf "%s", buf; exit }
                            inobj=0; buf=""; pre=0
                        }
                    }
                ' "$ALL" > "$OUT"
            fi
            if [ ! -s "$OUT" ]; then
                echo "No Xray-core pre-release is currently available from GitHub Releases."
                echo "Use Stable/latest instead."
                exit 0
            fi
            ;;
        *)
            echo "ERROR: unsupported channel: $CHANNEL_VALUE" >&2
            exit 1
            ;;
    esac
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
        --yes|-y) ASSUME_YES="1"; shift ;;
        --no-restart) NO_RESTART="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
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
fetch_release_json "$CHANNEL" "$RELEASE_JSON"

TAG_RAW="$(extract_release_field "$RELEASE_JSON" tag_name)"
NAME_RAW="$(extract_release_field "$RELEASE_JSON" name)"
TAG="$(sanitize_release_field "$TAG_RAW" 2>/dev/null || true)"
NAME="$(sanitize_release_field "$NAME_RAW" 2>/dev/null || true)"
case "$CHANNEL" in
    stable|latest)
        URL="https://github.com/$XRAY_REPO/releases/latest/download/$ASSET_NAME"
        [ -n "$TAG" ] || TAG="latest"
        ;;
    *)
        URL="$(extract_asset_url "$RELEASE_JSON" "$ASSET_NAME")"
        [ -n "$TAG" ] || TAG="$CHANNEL"
        ;;
esac

if [ -z "$URL" ]; then
    echo "ERROR: asset not found: $ASSET_NAME" >&2
    echo "Available Xray zip assets from release metadata:" >&2
    list_asset_names "$RELEASE_JSON" >&2
    exit 1
fi

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
    echo "Available Xray zip assets from release metadata:" >&2
    list_asset_names "$RELEASE_JSON" >&2
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
