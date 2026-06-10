#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition public entrypoint.
# Keep this filename as the current installer URL, but avoid embedded gzip/base64 payloads.
# Some Keenetic/Entware environments report gzip crc/magic errors with self-extracting wrappers.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
# Compatibility guardrail reference only: xray_vless_failover_minimal.sh
PLAIN_URL="${MINIMAL_GO_PLAIN_URL:-${REPO_BASE}/scripts/minimal-go-backend.sh}"
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

install_minimal_common_safety_patch() {
    common="/opt/libexec/minimal-go-common.sh"
    [ -f "$common" ] || return 0
    grep -q 'minimal-go-safe-switch-v2' "$common" 2>/dev/null && return 0

    cp "$common" "$common.before-safe-switch.$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)" 2>/dev/null || true

    cat >> "$common" <<'SAFE_SWITCH'

# minimal-go-safe-switch-v2
# Override switch_slot from the pinned backend: rollback config if the post-start
# SOCKS health check fails, and give slow transports such as XHTTP a few retries.
switch_slot() {
  slot="$1"
  source="$(source_for_slot "$slot")" || return 1
  tmp="$TMP_DIR/minimal-go-$slot.$$.json"
  old="$TMP_DIR/minimal-go-before-switch.$$.json"

  generate_config "$slot" "$source" "$SOCKS_LISTEN" "$SOCKS_PORT" "$tmp" || return 1
  test_config "$tmp" || return 1
  cp "$XRAY_CONFIG" "$old" 2>/dev/null || true
  cp "$tmp" "$XRAY_CONFIG"
  chmod 600 "$XRAY_CONFIG" 2>/dev/null || true

  rollback_config() {
    rc="$1"
    reason="$2"
    echo "ERROR: switch target=$slot failed: $reason" >&2
    if [ -s "$old" ]; then
      echo "Rolling back previous Xray config..." >&2
      cp "$old" "$XRAY_CONFIG"
      chmod 600 "$XRAY_CONFIG" 2>/dev/null || true
      "$XRAY_INIT" restart >/dev/null 2>&1 || "$XRAY_INIT" start >/dev/null 2>&1 || true
      wait_socks >/dev/null 2>&1 || true
    fi
    rm -f "$tmp" "$old" 2>/dev/null || true
    return "$rc"
  }

  if ! "$XRAY_INIT" restart && ! "$XRAY_INIT" start; then
    rollback_config 1 "xray restart failed"
    return 1
  fi

  if ! wait_socks; then
    rollback_config 1 "SOCKS did not listen on port $SOCKS_PORT"
    return 1
  fi

  ok=0
  i=1
  while [ "$i" -le 4 ]; do
    if health_check "127.0.0.1" "$SOCKS_PORT"; then
      ok=1
      break
    fi
    echo "WARN: health check failed after switch target=$slot attempt=$i/4" >&2
    sleep 3
    i=$((i+1))
  done

  if [ "$ok" != "1" ]; then
    rollback_config 1 "SOCKS health check failed"
    return 1
  fi

  echo "$slot" > "$ACTIVE_STORE"
  write_history "switch target=$slot"
  rm -f "$tmp" "$old" 2>/dev/null || true
  return 0
}
SAFE_SWITCH

    chmod 644 "$common" 2>/dev/null || true
    echo "Minimal Go safe switch patch installed: rollback on failed health check"
}

install_recover_status_proxy0_wrapper() {
    recover="/opt/bin/vless-go-recover"
    real="/opt/bin/vless-go-recover.real"
    [ -x "$recover" ] || return 0
    grep -q 'vless-go-recover-status-proxy0-v1' "$recover" 2>/dev/null && return 0

    cp "$recover" "$real" 2>/dev/null || return 0
    chmod +x "$real" 2>/dev/null || true

    cat > "$recover" <<'RECOVER_PROXY0_WRAPPER'
#!/bin/sh
# vless-go-recover-status-proxy0-v1
REAL="/opt/bin/vless-go-recover.real"
[ -x "$REAL" ] || { echo "ERROR: missing $REAL" >&2; exit 1; }

is_minimal=0
is_status=0
prev=""
for arg in "$@"; do
  [ "$arg" = "status" ] && is_status=1
  [ "$arg" = "--mode=minimal" ] && is_minimal=1
  if [ "$prev" = "--mode" ] && [ "$arg" = "minimal" ]; then
    is_minimal=1
  fi
  prev="$arg"
done

if [ "$is_status" = "1" ] && [ "$is_minimal" = "1" ]; then
  "$REAL" --mode minimal proxy0 >/dev/null 2>&1 || true
fi

exec "$REAL" "$@"
RECOVER_PROXY0_WRAPPER
    chmod +x "$recover"
    echo "Minimal Go recovery status wrapper installed: Doctor refreshes Proxy0 before status"
}

echo "Downloading Minimal Go backend..."
fetch_plain || { echo "ERROR: failed to download Minimal Go backend: $PLAIN_URL" >&2; exit 1; }

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal Go backend does not look like a shell script: $PLAIN_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal Go backend failed shell syntax check: $PLAIN_URL" >&2
    exit 1
fi

chmod +x "$OUT"
set +e
sh "$OUT" "$@"
RC="$?"
set -e

if [ "$RC" -eq 0 ]; then
    install_minimal_failover_compat || true
    install_minimal_common_safety_patch || true
    install_recover_status_proxy0_wrapper || true
fi

exit "$RC"
