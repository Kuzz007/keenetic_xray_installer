#!/bin/sh
set -e

# Compatibility shim for xray_vless_failover_auto_latest.sh.
# The auto installer historically resolves this *_safe.sh path. Keep it working
# by forwarding to the canonical Minimal Go installer.

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
TARGET_URL="${MINIMAL_GO_CANONICAL_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
[ -d "$TMP_DIR" ] || mkdir -p "$TMP_DIR"
TMP="$TMP_DIR/xray_vless_failover_minimal_go.sh.$$"
cleanup() { rm -f "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl not found; install curl first or run the canonical installer directly." >&2
    exit 1
fi

if ! curl -fsSL -o "$TMP" "$TARGET_URL"; then
    echo "ERROR: failed to download canonical Minimal Go installer: $TARGET_URL" >&2
    exit 1
fi

chmod +x "$TMP"
sh -n "$TMP"
exec sh "$TMP" "$@"
