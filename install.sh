#!/bin/sh
set -e

# Keenetic Xray Go v2 public installer entrypoint.
#
# Current stage: safe compatibility wrapper around the existing Auto Latest
# selector. This gives users one simple public command now, while the real
# direct-install v2 flow can be added here later without breaking the old
# xray_vless_failover_auto_latest.sh entrypoint.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
AUTO_LATEST_URL="${AUTO_LATEST_URL:-${REPO_BASE}/xray_vless_failover_auto_latest.sh}"

if [ -d /opt ]; then
    TMP_DIR="${TMPDIR:-/opt/tmp}"
else
    TMP_DIR="${TMPDIR:-/tmp}"
fi

TMP_FILE="${TMP_DIR}/xray_vless_failover_auto_latest.$$"

cleanup() {
    rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

fetch_url() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$output" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
        return $?
    fi

    echo "ERROR: curl or wget is required to download installer." >&2
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

mkdir -p "$TMP_DIR"

echo "Keenetic Xray Go installer"
echo "Entrypoint: install.sh"
echo "Downloading Auto Latest selector: $AUTO_LATEST_URL"

fetch_url "$AUTO_LATEST_URL" "$TMP_FILE" || {
    echo "ERROR: failed to download Auto Latest selector." >&2
    exit 1
}

looks_like_shell_script "$TMP_FILE" || {
    echo "ERROR: downloaded installer does not look like a shell script." >&2
    head -n 3 "$TMP_FILE" >&2 || true
    exit 1
}

sh -n "$TMP_FILE" || {
    echo "ERROR: downloaded installer failed shell syntax check." >&2
    exit 1
}

chmod +x "$TMP_FILE"
set +e
sh "$TMP_FILE" "$@"
RC="$?"
set -e
exit "$RC"
