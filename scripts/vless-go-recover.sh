#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
XRAY_INIT="/opt/etc/init.d/S24xray"
FULL_ACTIVE_STORE="$XRAY_DIR/vless-go.active"
FULL_PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
FULL_BACKUP_STORE="$XRAY_DIR/vless-go.backup"
FULL_FAILOVER_CMD="/opt/bin/vless-go-failover"
FULL_WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
FULL_HISTORY_CMD="/opt/bin/vless-go-history"
MINIMAL_COMMON="/opt/libexec/minimal-go-common.sh"
MINIMAL_ACTIVE_STORE="$XRAY_DIR/minimal-go-active"
MINIMAL_PRIMARY_STORE="$XRAY_DIR/minimal-go-primary.url"
MINIMAL_BACKUP_STORE="$XRAY_DIR/minimal-go-backup.url"
MINIMAL_SWITCH_CMD="/opt/bin/minimal-go-switch"
MINIMAL_FAILOVER_INIT="/opt/etc/init.d/S25xray-minimal-go-failover"
MINIMAL_HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"
ROUTER_IP_STORE="$XRAY_DIR/router-lan-ip"
SOCKS_HOST_SET="${SOCKS_HOST+x}"
SOCKS_PORT_SET="${SOCKS_PORT+x}"
CHECK_URLS_SET="${CHECK_URLS+x}"
PROXY_UPSTREAM_HOST_SET="${PROXY_UPSTREAM_HOST+x}"
SOCKS_HOST_ENV="${SOCKS_HOST:-}"
SOCKS_PORT_ENV="${SOCKS_PORT:-}"
CHECK_URLS_ENV="${CHECK_URLS:-}"
PROXY_UPSTREAM_HOST_ENV="${PROXY_UPSTREAM_HOST:-}"
SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${SOCKS_PORT:-10808}"
CHECK_URLS="${CHECK_URLS:-http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-5}"
MAX_TIME="${MAX_TIME:-10}"
PROXY_IFACE="${PROXY_IFACE:-Proxy0}"
PROXY_UPSTREAM_HOST="${PROXY_UPSTREAM_HOST:-}"
RECOVERY_AUTO_INSTALL_DEPS="${RECOVERY_AUTO_INSTALL_DEPS:-1}"
FULL_RECOVERY_LOG="/opt/var/log/vless-go-recover.log"
MINIMAL_RECOVERY_LOG="/opt/var/log/xray-minimal-go-failover.log"
LOG_FILE_OVERRIDE="${LOG_FILE:-}"
CRON_FILE="/opt/var/spool/cron/crontabs/root"
MARKER="vless-go-hourly-recover"
SYSTEM_MARKER="vless-go-system-recover"
DEFAULT_SCHEDULE="7 * * * *"
SYSTEM_DEFAULT_SCHEDULE="*/5 * * * *"
SYSTEM_STATE_FILE="/opt/var/run/vless-go-recover.system-state"
SYSTEM_LOAD_MULTIPLIER="${SYSTEM_LOAD_MULTIPLIER:-2}"
SYSTEM_CONSECUTIVE="${SYSTEM_CONSECUTIVE:-3}"
SYSTEM_GRACE_AFTER_BOOT="${SYSTEM_GRACE_AFTER_BOOT:-600}"
SYSTEM_REBOOT_COOLDOWN="${SYSTEM_REBOOT_COOLDOWN:-1800}"
SYSTEM_REBOOT_ENABLED="${SYSTEM_REBOOT_ENABLED:-0}"
RECOVER_MODE="${RECOVER_MODE:-auto}"
QUIET="0"
DEPS_CHECKED="0"

usage() {
    cat <<EOF
Usage: vless-go-recover [--quiet] [--mode auto|full|minimal] COMMAND

Commands:
  check            Silent health check only. Prints nothing when OK.
  run              Recovery ladder: deps -> check -> Proxy0 ensure/refresh -> Xray restart -> daemon restart -> failover/fallback.
  system-check     System overload recovery: high load counter -> restart Xray/daemon -> optional reboot.
  proxy0           Recreate/refresh Proxy0 and bring it up.
  xray             Restart Xray init service.
  watchdog         Restart Full watchdog or Minimal failover daemon.
  enable-hourly    Install hourly network recovery. Default: '$DEFAULT_SCHEDULE'.
  disable-hourly   Remove hourly network recovery.
  enable-system    Install system overload recovery. Default: '$SYSTEM_DEFAULT_SCHEDULE'.
  disable-system   Remove system overload recovery.
  status           Show recovery status.

Recovery dependencies:
  RECOVERY_AUTO_INSTALL_DEPS=$RECOVERY_AUTO_INSTALL_DEPS      1 = install missing Entware deps, 0 = diagnose only.

System overload environment:
  SYSTEM_LOAD_MULTIPLIER=$SYSTEM_LOAD_MULTIPLIER      Load threshold: load1 >= CPU cores * multiplier.
  SYSTEM_CONSECUTIVE=$SYSTEM_CONSECUTIVE              Consecutive overloaded checks required before action.
  SYSTEM_GRACE_AFTER_BOOT=$SYSTEM_GRACE_AFTER_BOOT    Seconds after boot before overload actions are allowed.
  SYSTEM_REBOOT_COOLDOWN=$SYSTEM_REBOOT_COOLDOWN      Minimum seconds between automatic reboots.
  SYSTEM_REBOOT_ENABLED=$SYSTEM_REBOOT_ENABLED        0 = log/restart only, 1 = allow reboot as final step.

Notes:
  - Supports Full Go and Minimal Go. Mode is auto-detected by default.
  - Minimal mode reads /opt/libexec/minimal-go-common.sh when present.
  - Environment variables SOCKS_HOST, SOCKS_PORT, PROXY_UPSTREAM_HOST and CHECK_URLS override runtime defaults.
  - Recovery checks Entware dependencies and can install missing curl/ca-certificates/cron packages.
  - ndmc is a Keenetic system command; recovery diagnoses it but does not install it from Entware.
  - Healthy hourly checks are silent.
  - Recovery actions are logged to the mode-specific recovery log.
  - Router reboot is disabled by default for system overload recovery.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quiet|-q) QUIET="1"; shift ;;
        --mode) [ "$#" -ge 2 ] || { echo "ERROR: --mode requires value" >&2; exit 2; }; RECOVER_MODE="$2"; shift 2 ;;
        --mode=*) RECOVER_MODE="${1#--mode=}"; shift ;;
        *) break ;;
    esac
done

case "$RECOVER_MODE" in auto|full|minimal) ;; *) echo "ERROR: invalid mode: $RECOVER_MODE" >&2; exit 2 ;; esac

detect_mode() {
    case "$RECOVER_MODE" in
        full|minimal) echo "$RECOVER_MODE"; return 0 ;;
    esac
    if [ -s "$FULL_ACTIVE_STORE" ] || [ -x "$FULL_FAILOVER_CMD" ]; then
        echo full
    elif [ -s "$MINIMAL_ACTIVE_STORE" ] || [ -x "$MINIMAL_SWITCH_CMD" ]; then
        echo minimal
    else
        echo unknown
    fi
}

load_minimal_runtime_config() {
    [ "$(detect_mode)" = minimal ] || return 0
    [ -f "$MINIMAL_COMMON" ] || return 0

    # shellcheck disable=SC1090
    . "$MINIMAL_COMMON"

    [ -n "$SOCKS_HOST_SET" ] && SOCKS_HOST="$SOCKS_HOST_ENV"
    [ -n "$SOCKS_PORT_SET" ] && SOCKS_PORT="$SOCKS_PORT_ENV"
    [ -n "$CHECK_URLS_SET" ] && CHECK_URLS="$CHECK_URLS_ENV"
    [ -n "$PROXY_UPSTREAM_HOST_SET" ] && PROXY_UPSTREAM_HOST="$PROXY_UPSTREAM_HOST_ENV"

    SOCKS_HOST="${SOCKS_HOST:-127.0.0.1}"
    SOCKS_PORT="${SOCKS_PORT:-10808}"
    CHECK_URLS="${CHECK_URLS:-http://connectivitycheck.gstatic.com/generate_204 http://cp.cloudflare.com/generate_204 http://www.gstatic.com/generate_204}"
}

load_minimal_runtime_config

recovery_log_file() {
    if [ -n "$LOG_FILE_OVERRIDE" ]; then
        echo "$LOG_FILE_OVERRIDE"
        return 0
    fi
    case "$(detect_mode)" in
        minimal) echo "$MINIMAL_RECOVERY_LOG" ;;
        *) echo "$FULL_RECOVERY_LOG" ;;
    esac
}

log() {
    LOG_FILE="$(recovery_log_file)"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    LINE="$(date '+%Y-%m-%d %H:%M:%S') $*"
    printf '%s\n' "$LINE" >> "$LOG_FILE"
    [ "$QUIET" = "1" ] || printf '%s\n' "$LINE"
}

mode_name() { MODE="$(detect_mode)"; echo "$MODE"; }
active_store() { case "$(detect_mode)" in full) echo "$FULL_ACTIVE_STORE" ;; minimal) echo "$MINIMAL_ACTIVE_STORE" ;; *) echo "$FULL_ACTIVE_STORE" ;; esac; }
primary_store() { case "$(detect_mode)" in full) echo "$FULL_PRIMARY_STORE" ;; minimal) echo "$MINIMAL_PRIMARY_STORE" ;; *) echo "$FULL_PRIMARY_STORE" ;; esac; }
backup_store() { case "$(detect_mode)" in full) echo "$FULL_BACKUP_STORE" ;; minimal) echo "$MINIMAL_BACKUP_STORE" ;; *) echo "$FULL_BACKUP_STORE" ;; esac; }
daemon_init() { case "$(detect_mode)" in full) echo "$FULL_WATCHDOG_INIT" ;; minimal) echo "$MINIMAL_FAILOVER_INIT" ;; *) echo "$FULL_WATCHDOG_INIT" ;; esac; }

active_slot() {
    STORE="$(active_store)"
    [ -s "$STORE" ] && sed -n '1p' "$STORE" || echo "unknown"
}

cron_running() {
    ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1
}

opkg_cmd() {
    if command -v opkg >/dev/null 2>&1; then command -v opkg; return 0; fi
    [ -x /opt/bin/opkg ] && { echo /opt/bin/opkg; return 0; }
    return 1
}

opkg_pkg_installed() {
    pkg="$1"
    OPKG="$(opkg_cmd 2>/dev/null || true)"
    [ -n "$OPKG" ] || return 1
    "$OPKG" status "$pkg" 2>/dev/null | grep -q '^Status: .* installed'
}

install_entware_packages() {
    packages="$*"
    [ -n "$packages" ] || return 0
    OPKG="$(opkg_cmd 2>/dev/null || true)"
    [ -n "$OPKG" ] || { log "Dependency install skipped: opkg not found; missing: $packages"; return 1; }
    log "Dependency install: opkg update"
    "$OPKG" update >> "$(recovery_log_file)" 2>&1 || { log "Dependency install failed: opkg update"; return 1; }
    log "Dependency install: opkg install $packages"
    "$OPKG" install $packages >> "$(recovery_log_file)" 2>&1 || { log "Dependency install failed: opkg install $packages"; return 1; }
}

start_cron_if_possible() {
    if cron_running; then return 0; fi
    if [ -x /opt/etc/init.d/S10cron ]; then /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true; fi
    if [ -x /opt/etc/init.d/Scron ]; then /opt/etc/init.d/Scron start >/dev/null 2>&1 || true; fi
    if cron_running; then return 0; fi
    if command -v crond >/dev/null 2>&1; then crond >/dev/null 2>&1 || true; fi
    if [ -x /opt/sbin/crond ]; then /opt/sbin/crond >/dev/null 2>&1 || true; fi
    if [ -x /opt/bin/crond ]; then /opt/bin/crond >/dev/null 2>&1 || true; fi
    cron_running
}

ensure_cron_files() {
    LOG_FILE="$(recovery_log_file)"
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch "$CRON_FILE" "$LOG_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

ensure_cron_dependency() {
    ensure_cron_files
    if start_cron_if_possible; then return 0; fi
    if [ "$RECOVERY_AUTO_INSTALL_DEPS" = "1" ]; then
        if ! opkg_pkg_installed cron && ! opkg_pkg_installed cronie; then
            install_entware_packages cron || install_entware_packages cronie || true
        fi
        start_cron_if_possible || true
    fi
    if ! cron_running; then
        log "Dependency check warning: cron daemon is not running; scheduled recovery may not run"
        return 1
    fi
    return 0
}

ensure_dependencies() {
    [ "$DEPS_CHECKED" = "1" ] && return 0
    DEPS_CHECKED="1"

    missing_pkgs=""
    if ! command -v curl >/dev/null 2>&1; then missing_pkgs="$missing_pkgs curl"; fi
    if ! opkg_pkg_installed ca-certificates && [ ! -s /opt/etc/ssl/certs/ca-certificates.crt ] && [ ! -s /opt/etc/ssl/cert.pem ]; then
        missing_pkgs="$missing_pkgs ca-certificates"
    fi

    if [ -n "$missing_pkgs" ]; then
        if [ "$RECOVERY_AUTO_INSTALL_DEPS" = "1" ]; then
            install_entware_packages $missing_pkgs || true
        else
            log "Dependency check: missing Entware packages:$missing_pkgs; auto-install disabled"
        fi
    fi

    ensure_cron_files
    ensure_cron_dependency || true

    if ! command -v curl >/dev/null 2>&1; then log "Dependency check failed: curl is missing"; return 1; fi
    if ! command -v ndmc >/dev/null 2>&1; then log "Dependency check warning: ndmc is missing; Proxy0 recovery is unavailable"; fi
    return 0
}

dependencies_summary() {
    echo "  dependency curl: $(command -v curl >/dev/null 2>&1 && echo OK || echo missing)"
    echo "  dependency ndmc: $(command -v ndmc >/dev/null 2>&1 && echo OK || echo missing)"
    if opkg_cmd >/dev/null 2>&1; then echo "  dependency opkg: OK"; else echo "  dependency opkg: missing"; fi
    if opkg_pkg_installed ca-certificates || [ -s /opt/etc/ssl/certs/ca-certificates.crt ] || [ -s /opt/etc/ssl/cert.pem ]; then echo "  dependency ca-certificates: OK"; else echo "  dependency ca-certificates: missing"; fi
    if cron_running; then echo "  dependency cron daemon: running"; else echo "  dependency cron daemon: not running"; fi
    echo "  dependency cron file: $CRON_FILE"
    echo "  dependency auto-install: $RECOVERY_AUTO_INSTALL_DEPS"
}

history_log() {
    MODE="$(detect_mode)"
    if [ "$MODE" = full ] && [ -x "$FULL_HISTORY_CMD" ]; then
        "$FULL_HISTORY_CMD" log "$@" >/dev/null 2>&1 || true
        return 0
    fi
    if [ "$MODE" = minimal ]; then
        mkdir -p "$(dirname "$MINIMAL_HISTORY_LOG")" 2>/dev/null || true
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$MINIMAL_HISTORY_LOG" 2>/dev/null || true
    fi
}

health_check() {
    ensure_dependencies || return 1
    for URL in $CHECK_URLS; do
        if curl -fsS --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "$URL" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

detect_lan_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
        return 0
    fi
    if command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet addr:/ { sub("addr:","",$2); if ($2 !~ /^127\./) { print $2; exit } } /inet / { for(i=1;i<=NF;i++) if($i=="inet" && $(i+1) !~ /^127\./) {print $(i+1); exit} }'
        return 0
    fi
    return 1
}

proxy_upstream_host() {
    if [ -n "$PROXY_UPSTREAM_HOST" ]; then echo "$PROXY_UPSTREAM_HOST"; return 0; fi
    if [ -s "$ROUTER_IP_STORE" ]; then sed -n '1p' "$ROUTER_IP_STORE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; return 0; fi
    LAN_IP="$(detect_lan_ip 2>/dev/null | sed -n '1p' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
    if [ -n "$LAN_IP" ]; then echo "$LAN_IP"; return 0; fi
    case "$SOCKS_HOST" in 127.0.0.1|localhost) echo "127.0.0.1" ;; *) echo "$SOCKS_HOST" ;; esac
}

ndmc_run() {
    cmd="$1"
    LOG_FILE="$(recovery_log_file)"
    echo "+ ndmc -c $cmd" >> "$LOG_FILE"
    out="$(ndmc -c "$cmd" 2>&1)"
    rc="$?"
    [ -n "$out" ] && printf '%s\n' "$out" >> "$LOG_FILE"
    return "$rc"
}

proxy0_show_log() {
    LOG_FILE="$(recovery_log_file)"
    echo "--- ndmc show interface $PROXY_IFACE ---" >> "$LOG_FILE"
    ndmc -c "show interface $PROXY_IFACE" >> "$LOG_FILE" 2>&1 || true
    echo "--- ndmc show running-config interface $PROXY_IFACE ---" >> "$LOG_FILE"
    ndmc -c "show running-config interface $PROXY_IFACE" >> "$LOG_FILE" 2>&1 || true
}

ensure_proxy0_once() {
    UPSTREAM_HOST="$1"
    ndmc_run "interface $PROXY_IFACE" || return 1
    ndmc_run "interface $PROXY_IFACE proxy protocol socks5" || return 1
    ndmc_run "interface $PROXY_IFACE proxy socks5-udp" || true
    ndmc_run "interface $PROXY_IFACE proxy upstream $UPSTREAM_HOST $SOCKS_PORT" || return 1
    ndmc_run "interface $PROXY_IFACE description Xray-Minimal-Go" || true
    ndmc_run "interface $PROXY_IFACE no ip global" || true
    ndmc_run "interface $PROXY_IFACE up" || return 1
    ndmc_run "system configuration save" || true
    proxy0_show_log
    return 0
}

ensure_proxy0() {
    ensure_dependencies || true
    command -v ndmc >/dev/null 2>&1 || { log "Proxy0 ensure skipped: ndmc not found"; return 1; }
    UPSTREAM_HOST="$(proxy_upstream_host)"
    [ -n "$UPSTREAM_HOST" ] || UPSTREAM_HOST="127.0.0.1"
    log "Recovery step: ensure $PROXY_IFACE SOCKS5 upstream $UPSTREAM_HOST:$SOCKS_PORT"
    if ensure_proxy0_once "$UPSTREAM_HOST"; then
        history_log proxy0_ensure source=recover iface="$PROXY_IFACE" upstream="$UPSTREAM_HOST:$SOCKS_PORT" result=ok mode="$(detect_mode)"
        return 0
    fi
    log "Proxy0 ensure first attempt failed: iface=$PROXY_IFACE upstream=$UPSTREAM_HOST:$SOCKS_PORT; trying recreate"
    ndmc_run "interface $PROXY_IFACE down" || true
    ndmc_run "no interface $PROXY_IFACE" || true
    sleep 1
    if ensure_proxy0_once "$UPSTREAM_HOST"; then
        history_log proxy0_ensure source=recover iface="$PROXY_IFACE" upstream="$UPSTREAM_HOST:$SOCKS_PORT" result=ok_recreated mode="$(detect_mode)"
        return 0
    fi
    log "Proxy0 ensure failed: iface=$PROXY_IFACE upstream=$UPSTREAM_HOST:$SOCKS_PORT"
    history_log proxy0_ensure source=recover iface="$PROXY_IFACE" upstream="$UPSTREAM_HOST:$SOCKS_PORT" result=failed mode="$(detect_mode)"
    return 1
}

refresh_proxy0() {
    ensure_dependencies || true
    command -v ndmc >/dev/null 2>&1 || { log "Proxy0 refresh skipped: ndmc not found"; return 1; }
    log "Recovery step: refresh $PROXY_IFACE"
    ndmc_run "interface $PROXY_IFACE down" || true
    sleep 2
    ensure_proxy0
    ndmc_run "interface $PROXY_IFACE up" || true
    history_log proxy0_refresh source=recover iface="$PROXY_IFACE" result=ok mode="$(detect_mode)"
}

restart_xray() {
    [ -x "$XRAY_INIT" ] || { log "Xray restart skipped: init not found: $XRAY_INIT"; return 1; }
    log "Recovery step: restart Xray"
    "$XRAY_INIT" restart >/dev/null 2>&1 || "$XRAY_INIT" start >/dev/null 2>&1 || return 1
    sleep 5
    history_log xray_restart source=recover result=ok mode="$(detect_mode)"
}

restart_watchdog() {
    INIT="$(daemon_init)"
    [ -x "$INIT" ] || { log "Daemon restart skipped: init not found: $INIT"; return 1; }
    log "Recovery step: restart daemon ($INIT)"
    "$INIT" restart >/dev/null 2>&1 || "$INIT" start >/dev/null 2>&1 || return 1
    history_log daemon_restart source=recover result=ok mode="$(detect_mode)"
}

switch_to_slot() {
    target="$1"
    MODE="$(detect_mode)"
    case "$MODE" in
        full)
            [ -x "$FULL_FAILOVER_CMD" ] || { log "Recovery step: switch skipped, command not found: $FULL_FAILOVER_CMD"; return 1; }
            log "Recovery step: switch $(active_slot) -> $target (full)"
            VLESS_GO_HISTORY_SUPPRESS=1 "$FULL_FAILOVER_CMD" switch "$target" --first >/dev/null 2>&1 || return 1
            ;;
        minimal)
            [ -x "$MINIMAL_SWITCH_CMD" ] || { log "Recovery step: switch skipped, command not found: $MINIMAL_SWITCH_CMD"; return 1; }
            log "Recovery step: switch $(active_slot) -> $target (minimal)"
            "$MINIMAL_SWITCH_CMD" "$target" >/dev/null 2>&1 || return 1
            ;;
        *) log "Recovery step: switch skipped, mode is unknown"; return 1 ;;
    esac
    sleep 5
    history_log recover_switch to="$target" result=ok mode="$MODE"
    return 0
}

try_slot_recovery() {
    MODE="$(detect_mode)"
    SLOT="$(active_slot)"
    case "$SLOT" in
        primary)
            BACKUP="$(backup_store)"
            [ -s "$BACKUP" ] || { log "Recovery step: failover skipped, backup is not configured"; return 1; }
            if switch_to_slot backup; then return 0; fi
            log "Recovery step failed: switch primary -> backup"
            history_log failed_switch source=recover from=primary to=backup reason=recover_switch_failed mode="$MODE"
            return 1
            ;;
        backup)
            PRIMARY="$(primary_store)"
            [ -s "$PRIMARY" ] || { log "Recovery step: fallback skipped, primary is not configured"; return 1; }
            if switch_to_slot primary; then return 0; fi
            log "Recovery step failed: switch backup -> primary"
            history_log failed_switch source=recover from=backup to=primary reason=recover_switch_failed mode="$MODE"
            return 1
            ;;
        *) log "Recovery step: slot recovery skipped, active slot is $SLOT"; return 1 ;;
    esac
}

run_recovery() {
    ensure_dependencies || true
    if health_check; then return 0; fi
    MODE="$(detect_mode)"
    log "Recovery started: SOCKS health failed on $(active_slot), mode=$MODE"
    refresh_proxy0 || true
    if health_check; then log "Recovery OK after Proxy0 refresh"; history_log recover_ok step=proxy0 result=ok mode="$MODE"; return 0; fi
    restart_xray || true
    if health_check; then log "Recovery OK after Xray restart"; history_log recover_ok step=xray_restart result=ok mode="$MODE"; return 0; fi
    restart_watchdog || true
    if health_check; then log "Recovery OK after daemon restart"; history_log recover_ok step=daemon_restart result=ok mode="$MODE"; return 0; fi
    try_slot_recovery || true
    if health_check; then log "Recovery OK after slot recovery"; history_log recover_ok step=slot_recovery result=ok mode="$MODE"; return 0; fi
    log "Recovery failed: manual intervention may be required; router reboot is not automatic"
    history_log recover_failed result=failed active="$(active_slot)" mode="$MODE"
    return 1
}

now_epoch() { date +%s 2>/dev/null || echo 0; }
uptime_seconds() { awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0; }
cpu_cores() { cores="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"; case "$cores" in ''|0|*[!0-9]*) cores=1 ;; esac; echo "$cores"; }
load_one() { awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0; }
system_overloaded() { load="$(load_one)"; cores="$(cpu_cores)"; awk -v load="$load" -v cores="$cores" -v mult="$SYSTEM_LOAD_MULTIPLIER" 'BEGIN { exit !(load >= cores * mult) }'; }

system_state_read() { if [ -s "$SYSTEM_STATE_FILE" ]; then sed -n '1p' "$SYSTEM_STATE_FILE"; else echo "0 0"; fi; }
system_state_write() { mkdir -p "$(dirname "$SYSTEM_STATE_FILE")" 2>/dev/null || true; printf '%s %s\n' "$1" "$2" > "$SYSTEM_STATE_FILE"; }
system_state_reset_count() { last_reboot="$(system_state_read | awk '{print $2+0}')"; system_state_write 0 "$last_reboot"; }

log_top_processes() {
    log "System overload process snapshot follows"
    LOG_FILE="$(recovery_log_file)"
    { echo "--- ps snapshot ---"; ps 2>/dev/null | head -n 40 || true; echo "--- loadavg ---"; cat /proc/loadavg 2>/dev/null || true; echo "--- meminfo ---"; grep -E 'MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree' /proc/meminfo 2>/dev/null || true; echo "--- df /opt ---"; df -h /opt 2>/dev/null || true; } >> "$LOG_FILE" 2>/dev/null || true
}

run_system_check() {
    ensure_dependencies || true
    up="$(uptime_seconds)"
    if [ "$up" -lt "$SYSTEM_GRACE_AFTER_BOOT" ]; then system_state_reset_count; [ "$QUIET" = "1" ] || echo "System check skipped: boot grace ${up}/${SYSTEM_GRACE_AFTER_BOOT}s"; return 0; fi
    state="$(system_state_read)"
    count="$(echo "$state" | awk '{print $1+0}')"
    last_reboot="$(echo "$state" | awk '{print $2+0}')"
    if ! system_overloaded; then system_state_write 0 "$last_reboot"; [ "$QUIET" = "1" ] || echo "System check OK: load1=$(load_one), cores=$(cpu_cores), multiplier=$SYSTEM_LOAD_MULTIPLIER"; return 0; fi
    count=$((count + 1))
    system_state_write "$count" "$last_reboot"
    log "System overload detected: load1=$(load_one), cores=$(cpu_cores), multiplier=$SYSTEM_LOAD_MULTIPLIER, count=$count/$SYSTEM_CONSECUTIVE, mode=$(detect_mode)"
    if [ "$count" -lt "$SYSTEM_CONSECUTIVE" ]; then return 1; fi
    log_top_processes
    restart_xray || true
    restart_watchdog || true
    history_log system_overload count="$count" mode="$(detect_mode)"
    if [ "$SYSTEM_REBOOT_ENABLED" != "1" ]; then log "System overload reboot skipped: SYSTEM_REBOOT_ENABLED=$SYSTEM_REBOOT_ENABLED"; return 1; fi
    now="$(now_epoch)"
    since=$((now - last_reboot))
    if [ "$last_reboot" -gt 0 ] && [ "$since" -lt "$SYSTEM_REBOOT_COOLDOWN" ]; then log "System overload reboot skipped: cooldown ${since}/${SYSTEM_REBOOT_COOLDOWN}s"; return 1; fi
    system_state_write 0 "$now"
    log "System overload reboot scheduled: load1=$(load_one), cores=$(cpu_cores), mode=$(detect_mode)"
    history_log system_overload_reboot mode="$(detect_mode)"
    ( sleep 2; reboot ) >/dev/null 2>&1 &
    return 1
}

remove_cron_marker() {
    marker="$1"
    ensure_cron_files
    TMP_FILE="$CRON_FILE.$$"
    grep -v "# $marker" "$CRON_FILE" > "$TMP_FILE" 2>/dev/null || true
    mv "$TMP_FILE" "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
}

remove_cron() { remove_cron_marker "$MARKER"; }

enable_hourly() {
    ensure_dependencies || true
    SCHEDULE="${1:-$DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_cron
    printf '%s %s --quiet --mode %s run # %s\n' "$SCHEDULE" "/opt/bin/vless-go-recover" "$(detect_mode)" "$MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    start_cron_if_possible || true
    echo "Hourly recovery enabled: $SCHEDULE"
    echo "Mode: $(detect_mode)"
    echo "Healthy checks are silent; recovery actions are logged to $(recovery_log_file)"
}

disable_hourly() { remove_cron; echo "Hourly recovery disabled."; }

enable_system() {
    ensure_dependencies || true
    SCHEDULE="${1:-$SYSTEM_DEFAULT_SCHEDULE}"
    ensure_cron_files
    remove_cron_marker "$SYSTEM_MARKER"
    printf '%s SYSTEM_LOAD_MULTIPLIER=%s SYSTEM_CONSECUTIVE=%s SYSTEM_GRACE_AFTER_BOOT=%s SYSTEM_REBOOT_COOLDOWN=%s SYSTEM_REBOOT_ENABLED=%s %s --quiet --mode %s system-check # %s\n' "$SCHEDULE" "$SYSTEM_LOAD_MULTIPLIER" "$SYSTEM_CONSECUTIVE" "$SYSTEM_GRACE_AFTER_BOOT" "$SYSTEM_REBOOT_COOLDOWN" "$SYSTEM_REBOOT_ENABLED" "/opt/bin/vless-go-recover" "$(detect_mode)" "$SYSTEM_MARKER" >> "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true
    start_cron_if_possible || true
    echo "System overload recovery enabled: $SCHEDULE"
    echo "Mode: $(detect_mode)"
    echo "Reboot enabled: $SYSTEM_REBOOT_ENABLED"
    echo "Threshold: load1 >= cores * $SYSTEM_LOAD_MULTIPLIER for $SYSTEM_CONSECUTIVE consecutive checks"
    echo "Actions are logged to $(recovery_log_file)"
}

disable_system() { remove_cron_marker "$SYSTEM_MARKER"; echo "System overload recovery disabled."; }

status() {
    ensure_dependencies || true
    ensure_cron_files
    echo "VLESS Go recovery status:"
    echo "  command: /opt/bin/vless-go-recover"
    echo "  mode: $(detect_mode)"
    echo "  health: $(health_check && echo OK || echo FAILED)"
    echo "  active slot: $(active_slot)"
    echo "  socks: $SOCKS_HOST:$SOCKS_PORT"
    echo "  proxy iface: $PROXY_IFACE"
    echo "  proxy upstream: $(proxy_upstream_host):$SOCKS_PORT"
    echo "  daemon init: $(daemon_init)"
    echo "  log: $(recovery_log_file)"
    dependencies_summary
    echo "  system load: load1=$(load_one), cores=$(cpu_cores), threshold_multiplier=$SYSTEM_LOAD_MULTIPLIER"
    echo "  system reboot enabled: $SYSTEM_REBOOT_ENABLED"
    if grep "# $MARKER" "$CRON_FILE" >/dev/null 2>&1; then echo "  hourly recovery: enabled"; grep "# $MARKER" "$CRON_FILE"; else echo "  hourly recovery: disabled"; fi
    if grep "# $SYSTEM_MARKER" "$CRON_FILE" >/dev/null 2>&1; then echo "  system recovery: enabled"; grep "# $SYSTEM_MARKER" "$CRON_FILE"; else echo "  system recovery: disabled"; fi
    if cron_running; then echo "  cron: running"; else echo "  cron: not running or not visible"; fi
}

CMD="${1:-run}"
shift 2>/dev/null || true
case "$CMD" in
    check) health_check ;;
    run|recover) run_recovery ;;
    system-check|system|overload-check) run_system_check ;;
    proxy0|refresh-proxy0|ensure-proxy0) refresh_proxy0 ;;
    xray|restart-xray) restart_xray ;;
    watchdog|restart-watchdog|daemon|restart-daemon) restart_watchdog ;;
    enable-hourly|enable) enable_hourly "${1:-}" ;;
    disable-hourly|disable) disable_hourly ;;
    enable-system|enable-system-recovery) enable_system "${1:-}" ;;
    disable-system|disable-system-recovery) disable_system ;;
    status) status ;;
    -h|--help|help) usage ;;
    *) echo "ERROR: unknown command: $CMD" >&2; usage >&2; exit 2 ;;
esac
