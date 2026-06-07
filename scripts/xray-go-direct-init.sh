#!/bin/sh
set -e

# xray-go-direct-init - experimental direct-install init.d helper.
#
# This helper handles init.d/service pieces separately from the main direct-install
# skeleton. It is intentionally explicit: staging is read-only, install requires a
# dedicated flag, and no first-run profile setup is executed here.

XRAY_GO_DIRECT_INIT_VERSION="${XRAY_GO_DIRECT_INIT_VERSION:-0.1.0-direct-init}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"

TMP_DIR="${TMPDIR:-/opt/tmp}"
STAGE_DIR="${XRAY_GO_DIRECT_STAGE_DIR:-${TMP_DIR}/xray-go-direct-install}"
INIT_STAGE_DIR="${INIT_STAGE_DIR:-${STAGE_DIR}/init}"
WATCHDOG_INSTALLER_URL="${WATCHDOG_INSTALLER_URL:-${RAW_BASE}/xray_vless_go_watchdog_install.sh}"
WATCHDOG_INSTALLER_STAGE="${WATCHDOG_INSTALLER_STAGE:-${INIT_STAGE_DIR}/xray_vless_go_watchdog_install.sh}"
WATCHDOG_CMD="${WATCHDOG_CMD:-/opt/bin/vless-go-watchdog}"
WATCHDOG_INIT="${WATCHDOG_INIT:-/opt/etc/init.d/S26vless-go-watchdog}"
WATCHDOG_CONF="${WATCHDOG_CONF:-/opt/etc/xray/vless-go-watchdog.conf}"
RECOVER_CMD="${RECOVER_CMD:-/opt/bin/vless-go-recover}"
CRON_FILE="${CRON_FILE:-/opt/var/spool/cron/crontabs/root}"
PLAN_FILE="${PLAN_FILE:-/opt/etc/xray/xray-go.direct-init.plan}"

MODE="prepare"
STAGE_WATCHDOG_INIT="0"
INSTALL_WATCHDOG_INIT="0"
POST_CHECK="0"
ASSUME_YES="0"

usage() {
    cat <<'USAGE'
xray-go-direct-init - experimental direct-install init.d helper

Usage:
  xray-go-direct-init [options]

Modes:
  --detect-only              Print init plan only; make no changes
  --post-check               Read-only check of direct init/service state

Options:
  --stage-watchdog-init      Download and syntax-check watchdog installer into staging dir
  --install-watchdog-init    Stage and run watchdog installer; no first-run setup is executed
  -y, --yes                  Do not ask confirmation before install-watchdog-init
  -h, --help                 Show help

Notes:
  This helper does not rewrite VLESS sources, does not run first setup and does not
  restart services by itself. The existing watchdog installer writes/updates the
  watchdog helper, init.d script and config.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --detect-only|--dry-run|--check) MODE="detect"; shift ;;
        --post-check|--check-installed|--verify-installed) POST_CHECK="1"; shift ;;
        --stage-watchdog-init) STAGE_WATCHDOG_INIT="1"; shift ;;
        --install-watchdog-init) STAGE_WATCHDOG_INIT="1"; INSTALL_WATCHDOG_INIT="1"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

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

    echo "ERROR: curl or wget is required." >&2
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

confirm_install() {
    [ "$INSTALL_WATCHDOG_INIT" = "1" ] || return 0
    [ "$ASSUME_YES" = "1" ] && return 0

    if [ -r /dev/tty ]; then
        printf '%s' "Install/update watchdog init.d files? [y/N]: " >/dev/tty
        IFS= read -r reply </dev/tty
    else
        printf '%s' "Install/update watchdog init.d files? [y/N]: " >&2
        IFS= read -r reply
    fi

    case "$reply" in y|Y|yes|YES|Да|да) return 0 ;; *) echo "Cancelled."; exit 0 ;; esac
}

print_plan() {
    cat <<EOF_PLAN
Keenetic Xray Go direct-init helper
Mode: $MODE
Version: $XRAY_GO_DIRECT_INIT_VERSION
Repository branch: $REPO_BRANCH
Stage dir: $STAGE_DIR
Init stage dir: $INIT_STAGE_DIR
Watchdog installer URL: $WATCHDOG_INSTALLER_URL
Watchdog installer staged: $WATCHDOG_INSTALLER_STAGE
Watchdog command: $WATCHDOG_CMD
Watchdog init: $WATCHDOG_INIT
Watchdog config: $WATCHDOG_CONF
Recovery command: $RECOVER_CMD
Cron file: $CRON_FILE
Plan file: $PLAN_FILE
Stage watchdog init: $STAGE_WATCHDOG_INIT
Install watchdog init: $INSTALL_WATCHDOG_INIT
Post-check: $POST_CHECK
EOF_PLAN
}

write_plan_file() {
    mkdir -p "$(dirname "$PLAN_FILE")"
    tmp="${PLAN_FILE}.$$"
    {
        echo '# Keenetic Xray Go direct-init plan'
        echo '# This file is informational and contains no VLESS/subscription secrets.'
        echo "VERSION=\"$XRAY_GO_DIRECT_INIT_VERSION\""
        echo "REPO_BRANCH=\"$REPO_BRANCH\""
        echo "STAGE_DIR=\"$STAGE_DIR\""
        echo "INIT_STAGE_DIR=\"$INIT_STAGE_DIR\""
        echo "WATCHDOG_INSTALLER_URL=\"$WATCHDOG_INSTALLER_URL\""
        echo "WATCHDOG_INSTALLER_STAGE=\"$WATCHDOG_INSTALLER_STAGE\""
        echo "WATCHDOG_CMD=\"$WATCHDOG_CMD\""
        echo "WATCHDOG_INIT=\"$WATCHDOG_INIT\""
        echo "WATCHDOG_CONF=\"$WATCHDOG_CONF\""
        echo "RECOVER_CMD=\"$RECOVER_CMD\""
        echo "CRON_FILE=\"$CRON_FILE\""
        echo "STAGE_WATCHDOG_INIT=\"$STAGE_WATCHDOG_INIT\""
        echo "INSTALL_WATCHDOG_INIT=\"$INSTALL_WATCHDOG_INIT\""
        echo "CREATED_AT=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')\""
    } >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$PLAN_FILE"
    echo "Direct-init plan written: $PLAN_FILE"
}

stage_watchdog_init() {
    [ "$STAGE_WATCHDOG_INIT" = "1" ] || return 0
    mkdir -p "$INIT_STAGE_DIR"
    echo "Staging watchdog installer: $WATCHDOG_INSTALLER_STAGE"
    fetch_url "$WATCHDOG_INSTALLER_URL" "$WATCHDOG_INSTALLER_STAGE"
    looks_like_shell_script "$WATCHDOG_INSTALLER_STAGE" || { echo "ERROR: staged watchdog installer is not a shell script." >&2; exit 1; }
    sh -n "$WATCHDOG_INSTALLER_STAGE" || { echo "ERROR: staged watchdog installer failed shell syntax check." >&2; exit 1; }
    chmod +x "$WATCHDOG_INSTALLER_STAGE"
    echo "Watchdog installer staged and verified."
}

install_watchdog_init() {
    [ "$INSTALL_WATCHDOG_INIT" = "1" ] || return 0
    [ -x "$WATCHDOG_INSTALLER_STAGE" ] || { echo "ERROR: watchdog installer is not staged: $WATCHDOG_INSTALLER_STAGE" >&2; exit 1; }
    confirm_install
    echo "Running watchdog init installer..."
    WATCHDOG_BRANCH="$REPO_BRANCH" sh "$WATCHDOG_INSTALLER_STAGE"
    echo "Watchdog init installer complete."
}

check_ok=0
check_warn=0
check_fail=0
pc_ok() { echo "[OK] $*"; check_ok=$((check_ok + 1)); }
pc_warn() { echo "[WARN] $*"; check_warn=$((check_warn + 1)); }
pc_fail() { echo "[FAIL] $*"; check_fail=$((check_fail + 1)); }

run_post_check() {
    echo
    echo "== Direct-init post-check =="

    [ -x "$WATCHDOG_CMD" ] && pc_ok "watchdog helper executable: $WATCHDOG_CMD" || pc_fail "watchdog helper missing/not executable: $WATCHDOG_CMD"
    [ -x "$WATCHDOG_INIT" ] && pc_ok "watchdog init executable: $WATCHDOG_INIT" || pc_fail "watchdog init missing/not executable: $WATCHDOG_INIT"
    [ -s "$WATCHDOG_CONF" ] && pc_ok "watchdog config present: $WATCHDOG_CONF" || pc_warn "watchdog config missing: $WATCHDOG_CONF"
    [ -x "$RECOVER_CMD" ] && pc_ok "recovery helper executable: $RECOVER_CMD" || pc_warn "recovery helper missing/not executable: $RECOVER_CMD"
    [ -s "$CRON_FILE" ] && pc_ok "cron file present: $CRON_FILE" || pc_warn "cron file missing: $CRON_FILE"

    if [ -x "$WATCHDOG_INIT" ]; then
        if "$WATCHDOG_INIT" status >/tmp/xray-go-direct-init-watchdog.$$ 2>&1; then
            pc_ok "watchdog init status command works"
        else
            pc_warn "watchdog init status returned non-zero"
        fi
        sed 's/^/  /' /tmp/xray-go-direct-init-watchdog.$$ 2>/dev/null || true
        rm -f /tmp/xray-go-direct-init-watchdog.$$ 2>/dev/null || true
    fi

    if [ -x "$RECOVER_CMD" ]; then
        if "$RECOVER_CMD" --mode full status >/tmp/xray-go-direct-init-recover.$$ 2>&1; then
            if grep -q 'health: OK' /tmp/xray-go-direct-init-recover.$$; then
                pc_ok "recovery health OK"
            else
                pc_warn "recovery status works but health is not OK"
            fi
        else
            pc_warn "recovery status command returned non-zero"
        fi
        sed 's/^/  /' /tmp/xray-go-direct-init-recover.$$ 2>/dev/null || true
        rm -f /tmp/xray-go-direct-init-recover.$$ 2>/dev/null || true
    fi

    echo
    echo "Direct-init post-check summary: OK=$check_ok WARN=$check_warn FAIL=$check_fail"
    [ "$check_fail" -eq 0 ] || exit 1
}

print_plan

if [ "$MODE" = "detect" ]; then
    echo "Detect-only: no changes made."
    exit 0
fi

if [ "$POST_CHECK" = "1" ]; then
    run_post_check
    exit 0
fi

mkdir -p "$STAGE_DIR" "$INIT_STAGE_DIR"
stage_watchdog_init
install_watchdog_init
write_plan_file

echo
echo "Direct-init helper complete."
echo "No first-run setup was executed."
echo "Next checks:"
echo "  $0 --post-check"
echo "  xray-go recover status"
