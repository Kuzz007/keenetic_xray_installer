#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition
# Direct vless:// only, no python3, no Entware feed, target low-storage /opt installs.

XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INIT="/opt/etc/init.d/S24xray"
FAILOVER_INIT="/opt/etc/init.d/S25xray-minimal-go-failover"
GO_RESOLVER="/opt/bin/xray-failover-go"
DAEMON="/opt/bin/xray-minimal-go-failover-daemon"
STATUS_CMD="/opt/bin/minimal-go-status"
SWITCH_CMD="/opt/bin/minimal-go-switch"
UPDATE_CMD="/opt/bin/minimal-go-update"
RECOVER_CMD="/opt/bin/vless-go-recover"

PRIMARY_STORE="$XRAY_DIR/minimal-go-primary.url"
BACKUP_STORE="$XRAY_DIR/minimal-go-backup.url"
ACTIVE_STORE="$XRAY_DIR/minimal-go-active"
ROUTER_IP_STORE="$XRAY_DIR/minimal-go-router-lan-ip"
HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"

SOCKS_PORT="${SOCKS_PORT:-10808}"
SOCKS_LISTEN="${SOCKS_LISTEN:-0.0.0.0}"
CHECK_URLS="${CHECK_URLS:-http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204}"
CHECK_INTERVAL="${CHECK_INTERVAL:-15}"
CHECK_RETRIES="${CHECK_RETRIES:-2}"
FAILOVER_FAILURES_REQUIRED="${FAILOVER_FAILURES_REQUIRED:-2}"
RECOVERY_SUCCESSES_REQUIRED="${RECOVERY_SUCCESSES_REQUIRED:-2}"
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"
ENABLE_HOURLY_RECOVERY="${ENABLE_HOURLY_RECOVERY:-1}"
HOURLY_RECOVERY_SCHEDULE="${HOURLY_RECOVERY_SCHEDULE:-7 * * * *}"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
TMP_DIR="/opt/tmp"
GO_TAG="${GO_TAG:-latest}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}"
RECOVER_URL="${RECOVER_URL:-${RAW_BASE}/scripts/vless-go-recover.sh}"
ASSUME_YES="${ASSUME_YES:-0}"
FORCE_GO_RESOLVER_UPDATE="${FORCE_GO_RESOLVER_UPDATE:-0}"
NO_CRON="${NO_CRON:-0}"
NO_RESTART="${NO_RESTART:-0}"
REPAIR_ONLY="${REPAIR_ONLY:-0}"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_minimal_go.sh [--yes] [--repair-only] [--force-go-resolver] [--no-cron] [--no-restart]

Minimal Go edition:
  - direct vless:// links only
  - primary/backup failover
  - quiet hourly recovery for Proxy0/Xray/daemon
  - no python3
  - no Entware feed package
  - downloads only xray-failover-go from GitHub Release when missing

Options:
  --yes                  Do not ask interactive confirmation
  --repair-only          Refresh helpers/runtime files without source/config rewrite
  --force-go-resolver    Re-download /opt/bin/xray-failover-go even if it already exists
  --no-cron              Do not install/start cron and do not enable hourly recovery
  --no-restart           Do not restart/start Minimal Go failover daemon at the end
                         Note: normal install still restarts Xray via minimal-go-switch.

Environment:
  GO_TAG=latest
  REPO_BRANCH=main
  ASSUME_YES=1
  REPAIR_ONLY=1
  FORCE_GO_RESOLVER_UPDATE=1
  NO_CRON=1
  NO_RESTART=1
  SOCKS_PORT=10808
  SOCKS_LISTEN=0.0.0.0
  CHECK_URLS='http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204'
  CHECK_INTERVAL=15
  ENABLE_HOURLY_RECOVERY=1
  HOURLY_RECOVERY_SCHEDULE='7 * * * *'
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES="1"; shift ;;
        --repair-only|--update-only|--safe-update) REPAIR_ONLY="1"; ASSUME_YES="1"; shift ;;
        --force-go-resolver|--force-resolver) FORCE_GO_RESOLVER_UPDATE="1"; shift ;;
        --no-cron) NO_CRON="1"; shift ;;
        --no-restart) NO_RESTART="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

read_tty() { prompt="$1"; if [ -r /dev/tty ]; then printf "%s" "$prompt" >/dev/tty; IFS= read -r REPLY </dev/tty; else printf "%s" "$prompt" >&2; IFS= read -r REPLY; fi; }
ask_value() { prompt="$1"; var="$2"; while true; do read_tty "$prompt"; [ -n "$REPLY" ] && break; echo "Value is required."; done; eval "$var=\$REPLY"; }
confirm() { [ "$ASSUME_YES" = "1" ] && return 0; read_tty "$1 [Y/n]: "; case "$REPLY" in n|N|no|NO|нет|Нет) echo "Cancelled."; exit 0 ;; esac; }

is_vless() { case "$1" in vless://*) return 0 ;; *) return 1 ;; esac; }

opkg_bin() { if command -v opkg >/dev/null 2>&1; then command -v opkg; elif [ -x /opt/bin/opkg ]; then echo /opt/bin/opkg; else echo ""; fi; }
get_xray_bin() { if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; else echo ""; fi; }
elf_magic() { file="$1"; if command -v hexdump >/dev/null 2>&1; then hexdump -n 4 -e '4/1 "%02x"' "$file" 2>/dev/null; elif command -v od >/dev/null 2>&1; then dd if="$file" bs=1 count=4 2>/dev/null | od -t x1 | awk 'NR==1 { for (i=2; i<=NF; i++) printf "%s", $i }'; else echo ""; fi; }

detect_entware_arch() { OPKG_BIN="$(opkg_bin)"; [ -n "$OPKG_BIN" ] || return 0; "$OPKG_BIN" print-architecture 2>/dev/null | awk '$2 != "all" && ($3+0) >= max { arch=$2; max=$3+0 } END { if (arch != "") print arch }'; }
asset_name_for_arch() { case "$1" in aarch64-3.10|aarch64*|arm64) echo xray-failover-go-linux-arm64 ;; mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*|mipsel-3.4|mipsel-3.4_kn|mipselsf-k3.4|mipselsf-k3.4_kn) echo xray-failover-go-linux-mipsle ;; *) echo "" ;; esac; }

ensure_cron() {
    [ "$NO_CRON" = "1" ] && { echo "No cron: skip cron setup."; return 0; }
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        opkg install cron >/dev/null 2>&1 || opkg install cronie >/dev/null 2>&1 || opkg install busybox-cron >/dev/null 2>&1 || echo "WARN: cron package not installed; hourly recovery may require manual cron setup."
    fi
    if ! ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1; then
        if [ -x /opt/etc/init.d/S10cron ]; then /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true; elif [ -x /opt/etc/init.d/S10crond ]; then /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true; elif command -v crond >/dev/null 2>&1; then crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true; elif command -v cron >/dev/null 2>&1; then cron >/dev/null 2>&1 || true; fi
    fi
}

install_packages() {
    command -v opkg >/dev/null 2>&1 || { echo "ERROR: opkg not found. Entware is required." >&2; exit 1; }
    mkdir -p "$TMP_DIR" "$XRAY_DIR" /opt/bin /opt/libexec /opt/var/log
    opkg update
    command -v curl >/dev/null 2>&1 || opkg install curl ca-bundle
    opkg install ca-bundle >/dev/null 2>&1 || true
    if [ -z "$(get_xray_bin)" ]; then
        echo "Installing xray-core/xray..."
        opkg install xray-core || opkg install xray || { echo "ERROR: failed to install xray." >&2; exit 1; }
    fi
    ensure_cron
}

install_go_resolver() {
    if [ -x "$GO_RESOLVER" ] && [ "$FORCE_GO_RESOLVER_UPDATE" != "1" ]; then
        echo "Go resolver already installed: $GO_RESOLVER"
        return 0
    fi
    ARCH="$(detect_entware_arch)"; [ -n "$ARCH" ] || ARCH="$(uname -m 2>/dev/null || echo unknown)"
    ASSET="$(asset_name_for_arch "$ARCH")"
    [ -n "$ASSET" ] || { echo "ERROR: unsupported architecture for Go resolver: $ARCH" >&2; exit 1; }
    URL="https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_TAG}/${ASSET}"
    tmp="$TMP_DIR/xray-failover-go.$$"
    echo "Downloading Go resolver: $URL"
    curl -fL -o "$tmp" "$URL"
    magic="$(elf_magic "$tmp")"
    if [ "$magic" != "7f454c46" ]; then
        rm -f "$tmp" 2>/dev/null || true
        echo "ERROR: downloaded Go resolver is not an ELF binary: $URL" >&2
        echo "ELF magic: ${magic:-unavailable}" >&2
        exit 1
    fi
    mv "$tmp" "$GO_RESOLVER"
    chmod +x "$GO_RESOLVER"
}

install_recover_helper() {
    echo "Installing quiet recovery helper..."
    tmp="$TMP_DIR/vless-go-recover.$$"
    if [ -f scripts/vless-go-recover.sh ]; then
        cp scripts/vless-go-recover.sh "$tmp"
    else
        curl -fL -o "$tmp" "$RECOVER_URL"
    fi
    mv "$tmp" "$RECOVER_CMD"
    chmod +x "$RECOVER_CMD"
}

detect_lan_ip() {
    if command -v ndmc >/dev/null 2>&1; then
        { ndmc -c "show interface Home" 2>/dev/null; ndmc -c "show interface Bridge0" 2>/dev/null; } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '$1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ || $1 ~ /^10\./ { print; exit }'
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show scope link 2>/dev/null | awk '/ src / { for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }'
    fi
}

create_xray_init() {
    cat > "$XRAY_INIT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
INIT
    chmod +x "$XRAY_INIT"
}

configure_proxy0() {
    command -v ndmc >/dev/null 2>&1 || { echo "WARN: ndmc not found; skip Proxy0."; return 0; }
    ROUTER_IP="$(cat "$ROUTER_IP_STORE" 2>/dev/null || true)"
    [ -n "$ROUTER_IP" ] || ROUTER_IP="127.0.0.1"
    ndmc -c "interface $PROXY_IFACE" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE proxy protocol socks5" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE proxy socks5-udp" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE proxy upstream $ROUTER_IP $SOCKS_PORT" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE description Xray-Minimal-Go" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE no ip global" >/dev/null 2>&1 || true
    ndmc -c "interface $PROXY_IFACE up" >/dev/null 2>&1 || true
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
    echo "$PROXY_IFACE -> SOCKS5 $ROUTER_IP:$SOCKS_PORT"
}

write_common_helpers() {
    cat > /opt/libexec/minimal-go-common.sh <<'COMMON'
XRAY_DIR="/opt/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
XRAY_INIT="/opt/etc/init.d/S24xray"
GO_RESOLVER="/opt/bin/xray-failover-go"
PRIMARY_STORE="$XRAY_DIR/minimal-go-primary.url"
BACKUP_STORE="$XRAY_DIR/minimal-go-backup.url"
ACTIVE_STORE="$XRAY_DIR/minimal-go-active"
ROUTER_IP_STORE="$XRAY_DIR/minimal-go-router-lan-ip"
HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"
SOCKS_PORT="10808"
SOCKS_LISTEN="0.0.0.0"
CHECK_URLS="http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204"
TMP_DIR="/opt/tmp"
TEMP_HOST="127.0.0.1"
TEMP_PRIMARY_PORT="19080"
TEMP_BACKUP_PORT="19081"

get_xray_bin() { if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; else echo ""; fi; }
write_history() { mkdir -p "$(dirname "$HISTORY_LOG")"; echo "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date) $*" >> "$HISTORY_LOG"; }
source_for_slot() { case "$1" in primary) cat "$PRIMARY_STORE" ;; backup) cat "$BACKUP_STORE" ;; *) return 1 ;; esac; }
generate_config() { slot="$1"; source="$2"; listen="$3"; port="$4"; output="$5"; "$GO_RESOLVER" -input "$source" -output "$output" -listen "$listen" -port "$port" -profile "vless-out" -first; }
test_config() { bin="$(get_xray_bin)"; [ -n "$bin" ] || return 1; "$bin" run -test -config "$1" >/dev/null 2>&1 || "$bin" test -config "$1" >/dev/null 2>&1; }
health_check() { host="$1"; port="$2"; for url in $CHECK_URLS; do curl -fsS --socks5-hostname "$host:$port" --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1 && return 0; done; return 1; }
wait_socks() { i=0; while [ "$i" -lt 10 ]; do netstat -lnt 2>/dev/null | grep -q ":$SOCKS_PORT" && return 0; sleep 1; i=$((i+1)); done; return 1; }
switch_slot() { slot="$1"; source="$(source_for_slot "$slot")" || return 1; tmp="$TMP_DIR/minimal-go-$slot.$$.json"; old="$TMP_DIR/minimal-go-before-switch.$$.json"; generate_config "$slot" "$source" "$SOCKS_LISTEN" "$SOCKS_PORT" "$tmp" || return 1; test_config "$tmp" || return 1; cp "$XRAY_CONFIG" "$old" 2>/dev/null || true; cp "$tmp" "$XRAY_CONFIG"; chmod 600 "$XRAY_CONFIG" 2>/dev/null || true; "$XRAY_INIT" restart || "$XRAY_INIT" start || { [ -s "$old" ] && cp "$old" "$XRAY_CONFIG"; return 1; }; wait_socks || return 1; health_check "127.0.0.1" "$SOCKS_PORT" || return 1; echo "$slot" > "$ACTIVE_STORE"; write_history "switch target=$slot"; rm -f "$tmp" "$old"; }
test_temp_slot() { slot="$1"; port="$2"; source="$(source_for_slot "$slot")" || return 1; tmp="$TMP_DIR/minimal-go-test-$slot.$$.json"; log="$TMP_DIR/minimal-go-test-$slot.$$.log"; bin="$(get_xray_bin)"; generate_config "$slot" "$source" "$TEMP_HOST" "$port" "$tmp" || return 1; test_config "$tmp" || return 1; "$bin" run -config "$tmp" >"$log" 2>&1 & pid="$!"; sleep 3; kill -0 "$pid" 2>/dev/null || { cat "$log" 2>/dev/null; return 1; }; health_check "$TEMP_HOST" "$port"; rc="$?"; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$tmp" "$log"; return "$rc"; }
COMMON
    sed -i \
      -e "s|^SOCKS_PORT=.*|SOCKS_PORT=\"$SOCKS_PORT\"|" \
      -e "s|^SOCKS_LISTEN=.*|SOCKS_LISTEN=\"$SOCKS_LISTEN\"|" \
      -e "s|^CHECK_URLS=.*|CHECK_URLS=\"$CHECK_URLS\"|" \
      /opt/libexec/minimal-go-common.sh
    chmod 644 /opt/libexec/minimal-go-common.sh
}

write_runtime_commands() {
    cat > "$SWITCH_CMD" <<'SWITCH'
#!/bin/sh
set -e
. /opt/libexec/minimal-go-common.sh
case "${1:-}" in primary|backup) switch_slot "$1" ;; *) echo "Usage: minimal-go-switch primary|backup" >&2; exit 1 ;; esac
SWITCH
    chmod +x "$SWITCH_CMD"

    cat > "$STATUS_CMD" <<'STATUS'
#!/bin/sh
. /opt/libexec/minimal-go-common.sh
echo "Minimal Go status:"
echo "  active: $(cat "$ACTIVE_STORE" 2>/dev/null || echo unknown)"
echo "  primary: $([ -s "$PRIMARY_STORE" ] && echo configured || echo missing)"
echo "  backup: $([ -s "$BACKUP_STORE" ] && echo configured || echo missing)"
echo "  SOCKS: 127.0.0.1:$SOCKS_PORT"
echo "  Xray: $([ -x "$XRAY_INIT" ] && "$XRAY_INIT" status 2>/dev/null | sed -n '1p' || echo init_missing)"
echo "  health: $(health_check 127.0.0.1 "$SOCKS_PORT" && echo OK || echo FAIL)"
echo "  history: $HISTORY_LOG"
[ -x /opt/bin/vless-go-recover ] && /opt/bin/vless-go-recover --mode minimal status || true
STATUS
    chmod +x "$STATUS_CMD"

    cat > "$UPDATE_CMD" <<'UPDATE'
#!/bin/sh
set -e
. /opt/libexec/minimal-go-common.sh
case "${1:-}" in primary|backup) slot="$1"; shift ;; *) echo "Usage: minimal-go-update primary|backup 'vless://...'" >&2; exit 1 ;; esac
[ "$#" -ge 1 ] || { echo "ERROR: vless:// URL required" >&2; exit 1; }
case "$1" in vless://*) ;; *) echo "ERROR: Minimal Go supports only direct vless:// links" >&2; exit 1 ;; esac
case "$slot" in primary) printf '%s\n' "$1" > "$PRIMARY_STORE" ;; backup) printf '%s\n' "$1" > "$BACKUP_STORE" ;; esac
chmod 600 "$PRIMARY_STORE" "$BACKUP_STORE" 2>/dev/null || true
echo "Updated $slot source."
UPDATE
    chmod +x "$UPDATE_CMD"

    cat > "$DAEMON" <<DAEMON
#!/bin/sh
. /opt/libexec/minimal-go-common.sh
CHECK_INTERVAL="$CHECK_INTERVAL"
FAILOVER_FAILURES_REQUIRED="$FAILOVER_FAILURES_REQUIRED"
RECOVERY_SUCCESSES_REQUIRED="$RECOVERY_SUCCESSES_REQUIRED"
AUTO_RECOVER_PRIMARY="$AUTO_RECOVER_PRIMARY"
primary_fail=0
primary_recover=0
backup_fail=0
while true; do
  active="\$(cat "\$ACTIVE_STORE" 2>/dev/null || echo primary)"
  if [ "\$active" = primary ]; then
    if health_check 127.0.0.1 "\$SOCKS_PORT"; then
      echo "\$(date '+%Y-%m-%d %H:%M:%S') health OK on primary"
      primary_fail=0
    else
      primary_fail=\$((primary_fail+1)); echo "\$(date '+%Y-%m-%d %H:%M:%S') health FAIL on primary: \$primary_fail/\$FAILOVER_FAILURES_REQUIRED"
      if [ "\$primary_fail" -ge "\$FAILOVER_FAILURES_REQUIRED" ]; then
        if [ -s "\$BACKUP_STORE" ] && test_temp_slot backup "\$TEMP_BACKUP_PORT" && switch_slot backup; then
          echo "\$(date '+%Y-%m-%d %H:%M:%S') switched primary -> backup"; primary_fail=0; primary_recover=0; backup_fail=0
        else
          echo "\$(date '+%Y-%m-%d %H:%M:%S') backup unavailable or not configured"
        fi
      fi
    fi
  else
    if health_check 127.0.0.1 "\$SOCKS_PORT"; then
      echo "\$(date '+%Y-%m-%d %H:%M:%S') health OK on backup"; backup_fail=0
      if [ "\$AUTO_RECOVER_PRIMARY" = 1 ] && [ -s "\$PRIMARY_STORE" ] && test_temp_slot primary "\$TEMP_PRIMARY_PORT"; then
        primary_recover=\$((primary_recover+1)); echo "\$(date '+%Y-%m-%d %H:%M:%S') primary recovery OK: \$primary_recover/\$RECOVERY_SUCCESSES_REQUIRED"
        if [ "\$primary_recover" -ge "\$RECOVERY_SUCCESSES_REQUIRED" ] && switch_slot primary; then
          echo "\$(date '+%Y-%m-%d %H:%M:%S') recovered backup -> primary"; primary_recover=0; backup_fail=0; primary_fail=0
        fi
      else
        primary_recover=0
      fi
    else
      backup_fail=\$((backup_fail+1)); primary_recover=0; echo "\$(date '+%Y-%m-%d %H:%M:%S') health FAIL on backup: \$backup_fail"
    fi
  fi
  sleep "\$CHECK_INTERVAL"
done
DAEMON
    chmod +x "$DAEMON"

    cat > "$FAILOVER_INIT" <<'INIT'
#!/opt/bin/sh

ENABLED=yes
DESC="Xray Minimal Go Failover"
DAEMON="/opt/bin/xray-minimal-go-failover-daemon"
PIDFILE="/opt/var/run/xray-minimal-go-failover.pid"
LOG="/opt/var/log/xray-minimal-go-failover.log"

PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

is_running() {
  [ -f "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start() {
  printf " Starting %s... " "$DESC"

  if is_running; then
    echo "already running."
    return 0
  fi

  mkdir -p /opt/var/run /opt/var/log

  "$DAEMON" >>"$LOG" 2>&1 &
  echo "$!" > "$PIDFILE"

  sleep 1

  if is_running; then
    echo "done."
    return 0
  fi

  echo "failed."
  rm -f "$PIDFILE"
  return 1
}

stop() {
  printf " Stopping %s... " "$DESC"

  if is_running; then
    pid="$(cat "$PIDFILE")"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
    echo "done."
    return 0
  fi

  rm -f "$PIDFILE"
  echo "not running."
  return 0
}

status() {
  printf " Checking %s... " "$DESC"

  if is_running; then
    echo "alive."
    return 0
  fi

  echo "dead."
  return 1
}

restart() {
  stop
  start
}

case "$1" in
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
INIT
    chmod +x "$FAILOVER_INIT"
}

enable_hourly_recovery_default() {
    [ "$NO_CRON" = "1" ] && { echo "No cron: skip hourly recovery setup."; return 0; }
    [ "$ENABLE_HOURLY_RECOVERY" = "1" ] || return 0
    [ -x "$RECOVER_CMD" ] || return 0
    "$RECOVER_CMD" --mode minimal enable-hourly "$HOURLY_RECOVERY_SCHEDULE" >/dev/null 2>&1 || echo "WARN: failed to enable hourly recovery. Run: vless-go-recover --mode minimal enable-hourly"
}

repair_only() {
    echo "Repair-only mode: helpers/runtime refresh; no source rewrite, no Xray config rewrite."
    install_packages
    install_go_resolver
    install_recover_helper
    create_xray_init
    write_common_helpers
    write_runtime_commands
    enable_hourly_recovery_default
    echo "Repair-only complete."
}

if [ "$REPAIR_ONLY" = "1" ]; then
    repair_only
    exit 0
fi

install_packages
install_go_resolver
install_recover_helper

if [ ! -s "$PRIMARY_STORE" ]; then
    ask_value "Primary vless:// URL: " PRIMARY_URL
    is_vless "$PRIMARY_URL" || { echo "ERROR: primary must be direct vless://" >&2; exit 1; }
    printf '%s\n' "$PRIMARY_URL" > "$PRIMARY_STORE"
fi

if [ ! -s "$BACKUP_STORE" ]; then
    read_tty "Backup vless:// URL (optional, Enter to skip): "
    if [ -n "$REPLY" ]; then
        is_vless "$REPLY" || { echo "ERROR: backup must be direct vless://" >&2; exit 1; }
        printf '%s\n' "$REPLY" > "$BACKUP_STORE"
    fi
fi
chmod 600 "$PRIMARY_STORE" "$BACKUP_STORE" 2>/dev/null || true
[ -s "$ACTIVE_STORE" ] || echo primary > "$ACTIVE_STORE"

ROUTER_IP="$(detect_lan_ip | awk 'NF { print; exit }')"
[ -n "$ROUTER_IP" ] || ROUTER_IP="127.0.0.1"
printf '%s\n' "$ROUTER_IP" > "$ROUTER_IP_STORE"

create_xray_init
write_common_helpers
write_runtime_commands

confirm "Generate primary config and start Xray/Minimal Go failover"
"$SWITCH_CMD" primary
configure_proxy0
if [ "$NO_RESTART" = "1" ]; then
    echo "No restart: skip Minimal Go failover daemon restart."
else
    "$FAILOVER_INIT" restart || "$FAILOVER_INIT" start || true
fi
enable_hourly_recovery_default

echo ""
echo "Minimal Go installed."
echo "Commands:"
echo "  minimal-go-status"
echo "  minimal-go-switch primary|backup"
echo "  minimal-go-update primary|backup 'vless://...'"
echo "  vless-go-recover --mode minimal status"
echo "  vless-go-recover --mode minimal enable-hourly"
echo "  /opt/etc/init.d/S25xray-minimal-go-failover restart"
"$STATUS_CMD" || true
