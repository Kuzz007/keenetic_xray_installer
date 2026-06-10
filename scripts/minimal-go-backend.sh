#!/bin/sh
set -e

# Named Minimal Go backend entrypoint.
# This is the stable backend target for xray_vless_failover_minimal_go.sh.
# It delegates to the last known-good full Minimal Go backend until the large
# backend is re-vendored directly in main.

PINNED_MINIMAL_GO_REF="${PINNED_MINIMAL_GO_REF:-26b5e7b56932260cd8c7831d1985adcbd9059baa}"
REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
UPSTREAM_URL="${MINIMAL_GO_UPSTREAM_URL:-https://raw.githubusercontent.com/${REPO}/${PINNED_MINIMAL_GO_REF}/xray_vless_failover_minimal_old_go.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/minimal-go-backend.$$"

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

fetch_backend() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$UPSTREAM_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --header='Cache-Control: no-cache' -O "$OUT" "$UPSTREAM_URL" || \
            wget --no-check-certificate --header='Cache-Control: no-cache' -O "$OUT" "$UPSTREAM_URL"
        return $?
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

echo "Downloading Minimal Go backend..."
fetch_backend || { echo "ERROR: failed to download Minimal Go backend: $UPSTREAM_URL" >&2; exit 1; }

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal Go backend does not look like a shell script: $UPSTREAM_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal Go backend failed shell syntax check: $UPSTREAM_URL" >&2
    exit 1
fi

chmod +x "$OUT"
exec sh "$OUT" "$@"
