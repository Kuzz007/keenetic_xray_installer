#!/bin/sh
set -e

# Auto installer latest edition.
# Thin selector/downloader wrapper. It intentionally points only to the current Go entrypoints:
#   - xray_vless_failover_go.sh
#   - xray_vless_failover_minimal_go.sh
# Legacy minimal-next is not downloaded from this wrapper.

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FULL_URL="${GO_FULL_URL:-$REPO_BASE/xray_vless_failover_go.sh}"
MINIMAL_GO_URL="${MINIMAL_GO_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"
MINIMAL_GO_MENU_URL="${MINIMAL_GO_MENU_URL:-$REPO_BASE/scripts/minimal-go-menu.sh}"
PROXY0_LAN_FIX_URL="${PROXY0_LAN_FIX_URL:-$REPO_BASE/scripts/proxy0-lan-upstream-fix.sh}"

GO_FULL_TMP="/opt/tmp/xray_vless_failover_go.sh"
MINIMAL_GO_TMP="/opt/tmp/xray_vless_failover_minimal_go.sh"
MINIMAL_GO_MENU_BIN="/opt/bin/minimal-go-menu"
PROXY0_LAN_FIX_BIN="/opt/bin/proxy0-lan-upstream-fix"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
MODE="${MODE:-install}"
NO_CRON="${NO_CRON:-0}"
NO_RESTART="${NO_RESTART:-0}"
FORCE_GO_RESOLVER_UPDATE="${FORCE_GO_RESOLVER_UPDATE:-0}"
LEGACY_REDIRECT="0"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_auto_latest.sh [options]

Edition selection:
  --auto                 Auto: low /opt space selects Minimal Go; update-only repairs installed edition
  --go                   Force xray_vless_failover_go.sh
  --minimal-go           Force xray_vless_failover_minimal_go.sh
  --minimal              Alias for --minimal-go
  --minimal-next         Legacy alias redirected to --minimal-go
  --legacy-minimal       Legacy alias redirected to --minimal-go

Modes:
  --detect-only          Print detection/selection only; make no changes
  --doctor               Print diagnostics and recovery status; make no install changes
  --update-only          Safe repair-lite update for already installed edition
  --dry-run              Alias for --detect-only compatibility

Other options:
  -y, --yes              Do not ask interactive confirmation
  --force-go-resolver    Re-download /opt/bin/xray-failover-go during update-only repair
  --no-cron              Do not create/modify cron entries in safe update path
  --no-restart           Do not restart services in safe update path
  -h, --help             Show help
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --go|--force-go) EDITION="go"; shift ;;
        --minimal|--minimal-go|--force-minimal) EDITION="minimal-go"; shift ;;
        --minimal-next|--legacy-minimal) EDITION="minimal-go"; LEGACY_REDIRECT="1"; shift ;;
        --auto) EDITION="auto"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        --dry-run|--check|--print-selection|--detect-only) MODE="detect-only"; shift ;;
        --doctor) MODE="doctor"; shift ;;
        --update-only) MODE="update-only"; ASSUME_YES="1"; shift ;;
        --force-go-resolver|--force-resolver) FORCE_GO_RESOLVER_UPDATE="1"; shift ;;
        --no-cron) NO_CRON="1"; shift ;;
        --no-restart) NO_RESTART="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$THRESHOLD_KB" in ''|*[!0-9]*) echo "ERROR: THRESHOLD_KB must be numeric, got: $THRESHOLD_KB" >&2; exit 1 ;; esac
case "$EDITION" in auto|go|minimal-go) ;; *) echo "ERROR: unsupported EDITION=$EDITION" >&2; exit 1 ;; esac
case "$MODE" in install|detect-only|doctor|update-only) ;; *) echo "ERROR: unsupported MODE=$MODE" >&2; exit 1 ;; esac

read_tty() {
    prompt="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
}

confirm_install() {
    label="$1"
    [ "$ASSUME_YES" = "1" ] && return 0
    read_tty "Install $label edition? [Y/n]: "
    case "$REPLY" in n|N|no|NO|Нет|нет) echo "Cancelled."; exit 0 ;; esac
}

opkg_bin() {
    if command -v opkg >/dev/null 2>&1; then command -v opkg
    elif [ -x /opt/bin/opkg ]; then echo /opt/bin/opkg
    else echo ""
    fi
}

need_opkg() { [ -n "$(opkg_bin)" ] || { echo "ERROR: opkg not found. Entware is required." >&2; exit 1; }; }

ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    echo "curl not found. Installing curl via Entware..."
    OPKG_BIN="$(opkg_bin)"
    "$OPKG_BIN" update
    "$OPKG_BIN" install curl ca-certificates || "$OPKG_BIN" install curl ca-bundle || "$OPKG_BIN" install curl
    command -v curl >/dev/null 2>&1 || { echo "ERROR: failed to install curl." >&2; exit 1; }
}

has_opkg_package() {
    OPKG_BIN="$(opkg_bin)"
    [ -n "$OPKG_BIN" ] && "$OPKG_BIN" status "$1" >/dev/null 2>&1
}

looks_like_shell_script() { head -n 1 "$1" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; }

download_file() {
    url="$1"; output="$2"; label="$3"
    mkdir -p "$(dirname "$output")"
    echo "Downloading $label: $url"
    curl -fsSL -H 'Cache-Control: no-cache' -o "$output" "$url" || { echo "ERROR: failed to download $label: $url" >&2; exit 1; }
    looks_like_shell_script "$output" || { echo "ERROR: downloaded $label does not look like a shell script: $url" >&2; head -n 3 "$output" >&2 || true; exit 1; }
    sh -n "$output" || { echo "ERROR: downloaded $label failed shell syntax check: $output" >&2; exit 1; }
    chmod +x "$output"
}

download_helper() {
    url="$1"; output="$2"; label="$3"
    mkdir -p "$(dirname "$output")" /opt/tmp
    tmp="/opt/tmp/$(basename "$output").$$"
    echo "Refreshing $label..."
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$tmp" "$url" && looks_like_shell_script "$tmp" && sh -n "$tmp"; then
        mv "$tmp" "$output"
        chmod +x "$output"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "WARN: failed to refresh $label from $url" >&2
    return 1
}

install_minimal_go_menu() { download_helper "$MINIMAL_GO_MENU_URL" "$MINIMAL_GO_MENU_BIN" "Minimal Go menu"; }
install_proxy0_lan_fix() { download_helper "$PROXY0_LAN_FIX_URL" "$PROXY0_LAN_FIX_BIN" "Proxy0 LAN upstream helper"; }
run_proxy0_lan_fix() {
    install_proxy0_lan_fix || return 0
    "$PROXY0_LAN_FIX_BIN" || true
}

space_mb() { awk "BEGIN { printf \"%.1f\", $1 / 1024 }"; }

detect_installed_edition() {
    if [ -x /opt/bin/minimal-go-status ] || [ -x /opt/bin/minimal-go-switch ] || [ -f /opt/etc/xray/minimal-go-active ] || [ -x /opt/etc/init.d/S25xray-minimal-go-failover ]; then echo minimal-go; return; fi
    if [ -x /opt/bin/xray-go ] || [ -x /opt/bin/vless-go-failover ] || [ -f /opt/etc/xray/vless-go.active ] || has_opkg_package failover-go; then echo go; return; fi
    if [ -x /opt/bin/vless-failover ] || [ -f /opt/etc/xray/vless.active ]; then echo minimal-go; return; fi
    echo none
}

cron_state() { ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1 && echo running || echo "not running"; }
run_recovery_status() { [ -x /opt/bin/vless-go-recover ] && /opt/bin/vless-go-recover --mode "$1" status 2>/dev/null || echo "vless-go-recover: not installed"; }

run_doctor() {
    echo "Diagnostics:"
    echo "  installed runtime: $INSTALLED_EDITION"
    echo "  selected runtime: $SELECTED"
    echo "  opkg: $(command -v opkg >/dev/null 2>&1 && echo yes || echo no)"
    echo "  curl: $(command -v curl >/dev/null 2>&1 && echo yes || echo no)"
    echo "  cron process: $(cron_state)"
    echo "  minimal-go-status: $([ -x /opt/bin/minimal-go-status ] && echo yes || echo no)"
    echo "  xray-go: $([ -x /opt/bin/xray-go ] && echo yes || echo no)"
    echo "  vless-go-failover: $([ -x /opt/bin/vless-go-failover ] && echo yes || echo no)"
    echo "  failover-go package present: $(has_opkg_package failover-go && echo yes || echo no)"
    echo "  vless-go-recover: $([ -x /opt/bin/vless-go-recover ] && echo yes || echo no)"
    echo "  proxy0-lan-fix: $([ -x "$PROXY0_LAN_FIX_BIN" ] && echo yes || echo no)"
    echo
    case "$SELECTED" in minimal-go) echo "Recovery status (minimal):"; run_recovery_status minimal ;; go) echo "Recovery status (full):"; run_recovery_status full ;; esac
}

print_detection() {
    cat <<EOF_DETECTION
Free /opt space: ${FREE_KB} KB (${FREE_MB} MB)
Full/Go threshold: ${THRESHOLD_KB} KB (${THRESHOLD_MB} MB)
Installed edition: $INSTALLED_EDITION
Selected edition: $SELECTED
Selection reason: $SELECT_REASON
Mode: $MODE
No cron: $NO_CRON
No restart: $NO_RESTART
Force Go resolver update: $FORCE_GO_RESOLVER_UPDATE
Go installer URL: $GO_FULL_URL
Minimal Go installer URL: $MINIMAL_GO_URL
Proxy0 LAN fix URL: $PROXY0_LAN_FIX_URL
EOF_DETECTION
}

print_selection_notes() {
    echo
    echo "Selection notes:"
    [ "$LEGACY_REDIRECT" = "1" ] && echo "  - Legacy minimal option requested; redirected to Minimal Go."
    case "$SELECTED" in
        minimal-go) echo "  - Minimal Go is selected."; echo "  - Installer: xray_vless_failover_minimal_go.sh" ;;
        go) echo "  - Go/Entware latest is selected."; echo "  - Installer: xray_vless_failover_go.sh" ;;
    esac
    echo
}

print_post_install_checks() {
    echo
    echo "Post-install checks:"
    case "$1" in
        minimal-go) echo "  minimal-go-status"; echo "  vless-go-recover --mode minimal status"; echo "  minimal-go-menu" ;;
        go) echo "  xray-go status"; echo "  xray-go doctor --json"; echo "  vless-go-recover --mode full status" ;;
    esac
    echo "  proxy0-lan-upstream-fix"
    echo
}

safe_update_minimal_go() {
    echo "Safe update for Minimal Go edition..."
    download_file "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go repair installer"
    args="--repair-only"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$NO_RESTART" = "1" ] && args="$args --no-restart"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Minimal Go repair: $MINIMAL_GO_TMP $args"
    sh "$MINIMAL_GO_TMP" $args
    install_minimal_go_menu || true
    run_proxy0_lan_fix
    print_post_install_checks minimal-go
}

safe_update_go() {
    echo "Safe update for Go/Entware latest edition..."
    download_file "$GO_FULL_URL" "$GO_FULL_TMP" "Full Go repair installer"
    args="--repair-only"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$NO_RESTART" = "1" ] && args="$args --no-restart"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Full Go repair: $GO_FULL_TMP $args"
    sh "$GO_FULL_TMP" $args
    run_proxy0_lan_fix
    print_post_install_checks go
}

run_update_only() {
    echo "Update-only mode: repair-lite; no source rewrite, no agent changes."
    case "$SELECTED" in minimal-go) safe_update_minimal_go ;; go) safe_update_go ;; *) echo "ERROR: no installed or selected edition to update" >&2; exit 1 ;; esac
    echo "Update-only complete."
}

FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2 { print $4 }')"
case "$FREE_KB" in ''|*[!0-9]*) FREE_KB="0" ;; esac

INSTALLED_EDITION="$(detect_installed_edition)"
if [ "$EDITION" = "auto" ]; then
    if [ "$MODE" = "install" ] && [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal-go"
        if [ "$INSTALLED_EDITION" != "none" ] && [ "$INSTALLED_EDITION" != "minimal-go" ]; then SELECT_REASON="low /opt space overrides installed $INSTALLED_EDITION remnants"; else SELECT_REASON="free /opt space is below threshold"; fi
    elif [ "$INSTALLED_EDITION" != "none" ]; then
        SELECTED="$INSTALLED_EDITION"; SELECT_REASON="existing installation detected"
    elif [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal-go"; SELECT_REASON="free /opt space is below threshold"
    else
        SELECTED="go"; SELECT_REASON="free /opt space is at or above threshold"
    fi
else
    SELECTED="$EDITION"; SELECT_REASON="explicit edition override"
fi

FREE_MB="$(space_mb "$FREE_KB")"
THRESHOLD_MB="$(space_mb "$THRESHOLD_KB")"
print_detection
print_selection_notes

case "$MODE" in
    detect-only) echo "Detect-only: no changes made."; exit 0 ;;
    doctor) echo; run_doctor; exit 0 ;;
    update-only) need_opkg; ensure_curl; mkdir -p /opt/tmp; run_update_only; exit 0 ;;
esac

need_opkg
ensure_curl
mkdir -p /opt/tmp

case "$SELECTED" in
    minimal-go)
        echo "Minimal Go edition: downloads xray_vless_failover_minimal_go.sh"
        confirm_install "Minimal Go"
        download_file "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go installer"
        sh "$MINIMAL_GO_TMP"
        install_minimal_go_menu || true
        run_proxy0_lan_fix
        print_post_install_checks minimal-go
        exit 0
        ;;
esac

echo "Go/Entware latest edition: downloads xray_vless_failover_go.sh"
confirm_install "Go/Entware latest"
download_file "$GO_FULL_URL" "$GO_FULL_TMP" "Go/Entware latest installer"
sh "$GO_FULL_TMP"
run_proxy0_lan_fix
print_post_install_checks go
