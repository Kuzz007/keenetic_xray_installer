#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition public entrypoint.
# Keep this filename as the current installer URL, but avoid embedded gzip/base64 payloads.
# Some Keenetic/Entware environments report gzip crc/magic errors with self-extracting wrappers.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
# Legacy plain target name kept for compatibility guardrails: xray_vless_failover_minimal.sh
MINIMAL_GO_BACKEND_SUFFIX="${MINIMAL_GO_BACKEND_SUFFIX:-old_go}"
PLAIN_NAME="${MINIMAL_GO_PLAIN_NAME:-xray_vless_failover_minimal_${MINIMAL_GO_BACKEND_SUFFIX}.sh}"
PLAIN_URL="${MINIMAL_GO_PLAIN_URL:-${REPO_BASE}/${PLAIN_NAME}}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/xray_vless_failover_minimal_go.plain.$$"

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

fetch_plain() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$PLAIN_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL" || \
            wget --no-check-certificate --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL"
        return $?
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

install_minimal_failover_compat() {
    [ -x /opt/bin/minimal-go-status ] || return 0
    [ -x /opt/bin/minimal-go-switch ] || return 0
    [ -x /opt/bin/minimal-go-update ] || return 0
    mkdir -p /opt/bin

    if [ -e /opt/bin/failover ] && [ ! -e /opt/bin/failover.before-minimal-compat ]; then
        cp /opt/bin/failover /opt/bin/failover.before-minimal-compat 2>/dev/null || true
    fi

    cat > /opt/bin/failover <<'FAILOVER_COMPAT'
#!/bin/sh

case "${1:-}" in
  status|source_status)
    if [ -x /opt/bin/minimal-go-status ]; then
      exec /opt/bin/minimal-go-status
    fi
    if [ -x /opt/bin/vless-failover-status ]; then
      exec /opt/bin/vless-failover-status
    fi
    echo "status command not found"
    exit 1
    ;;

  switch)
    slot="${2:-}"
    case "$slot" in
      primary|backup)
        if [ -x /opt/bin/minimal-go-switch ]; then
          exec /opt/bin/minimal-go-switch "$slot"
        fi
        if [ -x /opt/bin/xray-failover-switch ]; then
          exec /opt/bin/xray-failover-switch "$slot"
        fi
        echo "switch command not found"
        exit 1
        ;;
      *)
        echo "Usage: failover switch primary|backup"
        exit 2
        ;;
    esac
    ;;

  set-primary)
    shift
    [ "$#" -ge 1 ] || { echo "Usage: failover set-primary SOURCE"; exit 2; }
    if [ -x /opt/bin/minimal-go-update ]; then
      exec /opt/bin/minimal-go-update primary "$1"
    fi
    echo "minimal-go-update not found"
    exit 1
    ;;

  set-backup)
    shift
    [ "$#" -ge 1 ] || { echo "Usage: failover set-backup SOURCE"; exit 2; }
    if [ -x /opt/bin/minimal-go-update ]; then
      exec /opt/bin/minimal-go-update backup "$1"
    fi
    echo "minimal-go-update not found"
    exit 1
    ;;

  ""|menu)
    if [ -x /opt/bin/minimal-go-menu ]; then
      exec /opt/bin/minimal-go-menu
    fi
    echo "minimal-go-menu not found"
    exit 1
    ;;

  *)
    echo "Usage: failover [status|switch primary|switch backup|set-primary SOURCE|set-backup SOURCE|menu]"
    exit 2
    ;;
esac
FAILOVER_COMPAT
    chmod +x /opt/bin/failover
    echo "Minimal Go failover compatibility wrapper installed: /opt/bin/failover"
}

echo "Downloading Minimal Go plain installer..."
fetch_plain || { echo "ERROR: failed to download Minimal Go installer: $PLAIN_URL" >&2; exit 1; }

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal Go installer does not look like a shell script: $PLAIN_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal Go installer failed shell syntax check: $PLAIN_URL" >&2
    exit 1
fi

chmod +x "$OUT"
set +e
sh "$OUT" "$@"
RC="$?"
set -e

if [ "$RC" -eq 0 ]; then
    install_minimal_failover_compat || true
fi

exit "$RC"
