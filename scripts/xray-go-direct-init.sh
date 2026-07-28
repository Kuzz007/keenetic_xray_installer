#!/bin/sh
set -e

# Shared helpers used across install.sh and several scripts/*.sh entrypoints.
#
# This file is not meant to be sourced at runtime - scripts/build-generated-scripts.sh
# concatenates it into each published script (from scripts/src/direct/ and
# scripts/src/misc/) so every one of them stays a single self-contained file,
# safe to curl and run directly. Edit the functions here, then run
# scripts/build-generated-scripts.sh to regenerate the published scripts; do
# not hand-edit these function bodies in the generated files.
#
# Not every published script uses every function here - each still gets the
# full set, since a few unused shell functions cost nothing at runtime and
# it keeps this file the single source of truth rather than tracking a
# per-script subset.

fetch_url() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$output" "$url"
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

sha256_file() {
    file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

# xray-go-direct-init - experimental direct-install init.d/cron helper.
#
# This helper handles init.d/service pieces separately from the main direct-install
# skeleton. It is intentionally explicit: staging is read-only, install requires a
# dedicated flag, and no first-run profile setup is executed here.

XRAY_GO_DIRECT_INIT_VERSION="${XRAY_GO_DIRECT_INIT_VERSION:-0.1.0-direct-init}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
INSTALL_ENTRY_URL="${INSTALL_ENTRY_URL:-${RAW_BASE}/install.sh}"

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
RECOVERY_CRON_SCHEDULE="${RECOVERY_CRON_SCHEDULE:-7 * * * *}"
RECOVERY_CRON_MARKER="${RECOVERY_CRON_MARKER:-vless-go-hourly-recover}"
PLAN_FILE="${PLAN_FILE:-/opt/etc/xray/xray-go.direct-init.plan}"

MODE="prepare"
STAGE_WATCHDOG_INIT="0"
INSTALL_WATCHDOG_INIT="0"
ENABLE_RECOVERY_CRON="0"
DISABLE_RECOVERY_CRON="0"
POST_CHECK="0"
ASSUME_YES="0"

usage() {
    cat <<'USAGE'
xray-go-direct-init - experimental direct-install init.d/cron helper

Usage:
  xray-go-direct-init [options]

Modes:
  --detect-only              Print init plan only; make no changes
  --post-check               Read-only check of direct init/service state

Options:
  --stage-watchdog-init      Download and syntax-check watchdog installer into staging dir
  --install-watchdog-init    Stage and run watchdog installer; no first-run setup is executed
  --enable-recovery-cron     Enable hourly recovery cron entry
  --disable-recovery-cron    Disable hourly recovery cron entry
  --schedule '7 * * * *'     Recovery cron schedule for --enable-recovery-cron
  -y, --yes                  Do not ask confirmation before write actions
  -h, --help                 Show help

Notes:
  This helper does not rewrite VLESS sources and does not run first setup. The
  watchdog installer writes/updates the watchdog helper, init.d script and config.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --detect-only|--dry-run|--check) MODE="detect"; shift ;;
        --post-check|--check-installed|--verify-installed) POST_CHECK="1"; shift ;;
        --stage-watchdog-init) STAGE_WATCHDOG_INIT="1"; shift ;;
        --install-watchdog-init) STAGE_WATCHDOG_INIT="1"; INSTALL_WATCHDOG_INIT="1"; shift ;;
        --enable-recovery-cron|--enable-hourly-recovery) ENABLE_RECOVERY_CRON="1"; shift ;;
        --disable-recovery-cron|--disable-hourly-recovery) DISABLE_RECOVERY_CRON="1"; shift ;;
        --schedule)
            [ "$#" -ge 2 ] || { echo "ERROR: --schedule requires value" >&2; exit 2; }
            RECOVERY_CRON_SCHEDULE="$2"
            shift 2
            ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$ENABLE_RECOVERY_CRON" = "1" ] && [ "$DISABLE_RECOVERY_CRON" = "1" ] && {
    echo "ERROR: --enable-recovery-cron and --disable-recovery-cron cannot be used together." >&2
    exit 2
}

confirm_action() {
    prompt="$1"
    [ "$ASSUME_YES" = "1" ] && return 0

    if [ -r /dev/tty ]; then
        printf '%s' "$prompt [y/N]: " >/dev/tty
        IFS= read -r reply </dev/tty
    else
        printf '%s' "$prompt [y/N]: " >&2
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
Recovery cron schedule: $RECOVERY_CRON_SCHEDULE
Recovery cron marker: $RECOVERY_CRON_MARKER
Plan file: $PLAN_FILE
Stage watchdog init: $STAGE_WATCHDOG_INIT
Install watchdog init: $INSTALL_WATCHDOG_INIT
Enable recovery cron: $ENABLE_RECOVERY_CRON
Disable recovery cron: $DISABLE_RECOVERY_CRON
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
        echo "RECOVERY_CRON_SCHEDULE=\"$RECOVERY_CRON_SCHEDULE\""
        echo "RECOVERY_CRON_MARKER=\"$RECOVERY_CRON_MARKER\""
        echo "STAGE_WATCHDOG_INIT=\"$STAGE_WATCHDOG_INIT\""
        echo "INSTALL_WATCHDOG_INIT=\"$INSTALL_WATCHDOG_INIT\""
        echo "ENABLE_RECOVERY_CRON=\"$ENABLE_RECOVERY_CRON\""
        echo "DISABLE_RECOVERY_CRON=\"$DISABLE_RECOVERY_CRON\""
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
    confirm_action "Install/update watchdog init.d files?"
    echo "Running watchdog init installer..."
    WATCHDOG_BRANCH="$REPO_BRANCH" sh "$WATCHDOG_INSTALLER_STAGE"
    echo "Watchdog init installer complete."
}

remove_recovery_cron_lines() {
    input="$1"
    output="$2"
    if [ -s "$input" ]; then
        grep -v "# ${RECOVERY_CRON_MARKER}" "$input" >"$output" || true
    else
        : >"$output"
    fi
}

reload_cron_daemon() {
    if command -v crond >/dev/null 2>&1; then
        killall -HUP crond 2>/dev/null || true
    elif command -v cron >/dev/null 2>&1; then
        killall -HUP cron 2>/dev/null || true
    fi
}

enable_recovery_cron() {
    [ "$ENABLE_RECOVERY_CRON" = "1" ] || return 0
    [ -x "$RECOVER_CMD" ] || { echo "ERROR: recovery helper is not executable: $RECOVER_CMD" >&2; exit 1; }
    confirm_action "Enable hourly recovery cron?"

    mkdir -p "$(dirname "$CRON_FILE")"
    touch "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true

    tmp="${CRON_FILE}.$$"
    remove_recovery_cron_lines "$CRON_FILE" "$tmp"
    printf '%s %s --quiet --mode full run # %s\n' "$RECOVERY_CRON_SCHEDULE" "$RECOVER_CMD" "$RECOVERY_CRON_MARKER" >>"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$CRON_FILE"
    reload_cron_daemon
    echo "Recovery cron enabled: $RECOVERY_CRON_SCHEDULE $RECOVER_CMD --quiet --mode full run # $RECOVERY_CRON_MARKER"
}

disable_recovery_cron() {
    [ "$DISABLE_RECOVERY_CRON" = "1" ] || return 0
    confirm_action "Disable hourly recovery cron?"

    mkdir -p "$(dirname "$CRON_FILE")"
    touch "$CRON_FILE"
    chmod 600 "$CRON_FILE" 2>/dev/null || true

    tmp="${CRON_FILE}.$$"
    remove_recovery_cron_lines "$CRON_FILE" "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$CRON_FILE"
    reload_cron_daemon
    echo "Recovery cron disabled for marker: $RECOVERY_CRON_MARKER"
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

    if [ -s "$CRON_FILE" ]; then
        if grep -q "# ${RECOVERY_CRON_MARKER}" "$CRON_FILE"; then
            pc_ok "recovery cron entry present"
            grep "# ${RECOVERY_CRON_MARKER}" "$CRON_FILE" | sed 's/^/  /'
        else
            pc_warn "recovery cron entry not present"
        fi
    fi

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

print_public_next_checks() {
    cat <<EOF_NEXT
Next checks:
  curl -fsSL $INSTALL_ENTRY_URL | sh -s -- --direct-init-post-check
  xray-go recover status
EOF_NEXT
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
enable_recovery_cron
disable_recovery_cron
write_plan_file

echo
echo "Direct-init helper complete."
echo "No first-run setup was executed."
print_public_next_checks
