#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition public entrypoint.
# Keep this filename as the current installer URL, but avoid embedded gzip/base64 payloads.
# Some Keenetic/Entware environments report gzip crc/magic errors with self-extracting wrappers.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
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
    if grep -q 'minimal-go-mux-aware-switch-v3' "$common" 2>/dev/null; then
        echo "Minimal Go mux-aware switch patch already installed"
        return 0
    fi

    cp "$common" "$common.before-mux-aware-switch.$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)" 2>/dev/null || true

    cat >> "$common" <<'SAFE_SWITCH'

# minimal-go-mux-aware-switch-v3
# Override switch_slot from the pinned backend: rollback config if the post-start
# SOCKS health check fails, give slow transports such as XHTTP a few retries,
# and merge persistent Mux state into generated config before Xray restart.
apply_persistent_mux_state() {
  cfg="$1"
  state="/opt/etc/xray/mux-state.json"
  [ -s "$cfg" ] || return 0
  [ -s "$state" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$cfg" "$state" <<'PY' || return 0
import json, os, sys
cfg_path, state_path = sys.argv[1], sys.argv[2]
try:
    with open(cfg_path, 'r', encoding='utf-8') as f:
        cfg = json.load(f)
    with open(state_path, 'r', encoding='utf-8') as f:
        st = json.load(f)
    outbounds = cfg.get('outbounds') or []
    target = None
    tag = (st.get('outbound_tag') or '').strip()
    if tag:
        for ob in outbounds:
            if isinstance(ob, dict) and ob.get('tag') == tag:
                target = ob
                break
    if target is None:
        for ob in outbounds:
            if isinstance(ob, dict) and str(ob.get('protocol','')).lower() == 'vless':
                target = ob
                break
    if target is None:
        for ob in outbounds:
            if isinstance(ob, dict) and str(ob.get('protocol','')).lower() not in ('freedom','blackhole'):
                target = ob
                break
    if target is None:
        sys.exit(0)
    conc = int(st.get('concurrency') or 8)
    xudp = int(st.get('xudpConcurrency') if st.get('xudpConcurrency') is not None else -1)
    proxy443 = st.get('xudpProxyUDP443') or 'skip'
    target['mux'] = {
        'enabled': True,
        'concurrency': conc,
        'xudpConcurrency': xudp,
        'xudpProxyUDP443': proxy443,
    }
    tmp = cfg_path + '.mux-state.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write('\n')
    os.replace(tmp, cfg_path)
except Exception:
    pass
PY
  fi
}

switch_slot() {
  slot="$1"
  source="$(source_for_slot "$slot")" || return 1
  tmp="$TMP_DIR/minimal-go-$slot.$$.json"
  old="$TMP_DIR/minimal-go-before-switch.$$.json"

  generate_config "$slot" "$source" "$SOCKS_LISTEN" "$SOCKS_PORT" "$tmp" || return 1
  apply_persistent_mux_state "$tmp"
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
    echo "Minimal Go mux-aware switch patch installed: persistent Mux is merged before Xray restart"
}

remove_recover_status_proxy0_wrapper() {
    recover="/opt/bin/vless-go-recover"
    real="/opt/bin/vless-go-recover.real"
    [ -f "$recover" ] || return 0
    if grep -q 'vless-go-recover-status-proxy0-v1' "$recover" 2>/dev/null && [ -s "$real" ]; then
        cp "$real" "$recover" 2>/dev/null || return 0
        chmod +x "$recover" 2>/dev/null || true
        echo "Minimal Go recovery status wrapper removed: status is fast again"
    fi
}

install_minimal_daemon_recovery_patch() {
    daemon="/opt/bin/xray-minimal-go-failover-daemon"
    [ -x "$daemon" ] || return 0
    if grep -q 'minimal-go-daemon-recover-primary-v2' "$daemon" 2>/dev/null; then
        echo "Minimal Go daemon recovery patch already installed"
        return 0
    fi
    cp "$daemon" "$daemon.before-recover-primary.$(date +%Y%m%d-%H%M%S 2>/dev/null || echo backup)" 2>/dev/null || true

    cat > "$daemon" <<'MINIMAL_DAEMON'
#!/bin/sh
# minimal-go-daemon-recover-primary-v2
. /opt/libexec/minimal-go-common.sh
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
FAILOVER_FAILURES_REQUIRED="${FAILOVER_FAILURES_REQUIRED:-2}"
RECOVERY_SUCCESSES_REQUIRED="${RECOVERY_SUCCESSES_REQUIRED:-2}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"
primary_fail=0
primary_recover=0
backup_fail=0

try_primary_recovery_now() {
  [ "$AUTO_RECOVER_PRIMARY" = "1" ] || return 1
  [ -s "$PRIMARY_STORE" ] || return 1
  echo "$(date '+%Y-%m-%d %H:%M:%S') probing primary for recovery"
  if test_temp_slot primary "$TEMP_PRIMARY_PORT" && switch_slot primary; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') recovered backup -> primary"
    primary_recover=0
    backup_fail=0
    primary_fail=0
    return 0
  fi
  echo "$(date '+%Y-%m-%d %H:%M:%S') primary recovery unavailable"
  return 1
}

while true; do
  active="$(cat "$ACTIVE_STORE" 2>/dev/null || echo primary)"
  if [ "$active" = primary ]; then
    if health_check 127.0.0.1 "$SOCKS_PORT"; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') health OK on primary"
      primary_fail=0
    else
      primary_fail=$((primary_fail+1))
      echo "$(date '+%Y-%m-%d %H:%M:%S') health FAIL on primary: $primary_fail/$FAILOVER_FAILURES_REQUIRED"
      if [ "$primary_fail" -ge "$FAILOVER_FAILURES_REQUIRED" ]; then
        if [ -s "$BACKUP_STORE" ] && test_temp_slot backup "$TEMP_BACKUP_PORT" && switch_slot backup; then
          echo "$(date '+%Y-%m-%d %H:%M:%S') switched primary -> backup"
          primary_fail=0
          primary_recover=0
          backup_fail=0
        else
          echo "$(date '+%Y-%m-%d %H:%M:%S') backup unavailable or not configured"
        fi
      fi
    fi
  else
    if health_check 127.0.0.1 "$SOCKS_PORT"; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') health OK on backup"
      backup_fail=0
      if [ "$AUTO_RECOVER_PRIMARY" = "1" ] && [ -s "$PRIMARY_STORE" ] && test_temp_slot primary "$TEMP_PRIMARY_PORT"; then
        primary_recover=$((primary_recover+1))
        echo "$(date '+%Y-%m-%d %H:%M:%S') primary recovery OK: $primary_recover/$RECOVERY_SUCCESSES_REQUIRED"
        if [ "$primary_recover" -ge "$RECOVERY_SUCCESSES_REQUIRED" ] && switch_slot primary; then
          echo "$(date '+%Y-%m-%d %H:%M:%S') recovered backup -> primary"
          primary_recover=0
          backup_fail=0
          primary_fail=0
        fi
      else
        primary_recover=0
      fi
    else
      backup_fail=$((backup_fail+1))
      primary_recover=0
      echo "$(date '+%Y-%m-%d %H:%M:%S') health FAIL on backup: $backup_fail; probing primary"
      try_primary_recovery_now || true
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
MINIMAL_DAEMON
    chmod +x "$daemon"
    echo "Minimal Go daemon recovery patch installed: failed backup can recover to primary"
}

restart_minimal_daemon_if_present() {
    init="/opt/etc/init.d/S25xray-minimal-go-failover"
    [ -x "$init" ] || return 0
    if "$init" restart >/dev/null 2>&1 || "$init" start >/dev/null 2>&1; then
        echo "Minimal Go failover daemon restarted to apply script patches"
    else
        echo "WARN: failed to restart Minimal Go failover daemon: $init" >&2
    fi
}

is_private_ipv4() {
    case "$1" in
        10.*|192.168.*|172.16.*|172.17.*|172.18.*|172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|172.29.*|172.30.*|172.31.*) return 0 ;;
        *) return 1 ;;
    esac
}

find_router_lan_ip() {
    # Prefer Keenetic LAN/Home interfaces. Do not use default-route source; on 4G it can be CGNAT WAN.
    if command -v ndmc >/dev/null 2>&1; then
        for iface in Home Bridge0 br0; do
            ip="$(ndmc -c "show interface $iface" 2>/dev/null | awk '/^[[:space:]]*address:/ {print $2; exit}')"
            if is_private_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    fi

    if command -v ip >/dev/null 2>&1; then
        for iface in Home Bridge0 br0; do
            ip="$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')"
            if is_private_ipv4 "$ip"; then
                printf '%s\n' "$ip"
                return 0
            fi
        done
    fi

    if [ -s /opt/etc/xray/router-lan-ip ]; then
        ip="$(sed -n '1p' /opt/etc/xray/router-lan-ip 2>/dev/null | tr -d '\r')"
        if is_private_ipv4 "$ip"; then
            printf '%s\n' "$ip"
            return 0
        fi
    fi

    return 1
}

install_minimal_go_proxy0_lan_upstream_fix() {
    command -v ndmc >/dev/null 2>&1 || return 0
    lan_ip="$(find_router_lan_ip 2>/dev/null || true)"
    [ -n "$lan_ip" ] || { echo "WARN: could not detect LAN/Home IP for Proxy0 upstream" >&2; return 0; }

    mkdir -p /opt/etc/xray 2>/dev/null || true
    printf '%s\n' "$lan_ip" > /opt/etc/xray/router-lan-ip 2>/dev/null || true

    if ndmc -c "interface Proxy0 proxy upstream $lan_ip 10808" \
        && ndmc -c "interface Proxy0 down" \
        && sleep 2 \
        && ndmc -c "interface Proxy0 up" \
        && ndmc -c "system configuration save"
    then
        echo "Proxy0 upstream fixed to LAN/Home IP: $lan_ip:10808"
    else
        echo "WARN: failed to set Proxy0 upstream to $lan_ip:10808" >&2
    fi
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
    remove_recover_status_proxy0_wrapper || true
    install_minimal_daemon_recovery_patch || true
    install_minimal_go_proxy0_lan_upstream_fix || true
    restart_minimal_daemon_if_present || true
fi

exit "$RC"
