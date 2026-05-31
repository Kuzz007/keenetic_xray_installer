#!/bin/sh
set -e

# Auto installer latest edition.
# Thin downloader/selector wrapper: no embedded gzip/base64 payload.
# Chooses between:
#   - Go/Entware latest feed edition for normal /opt storage
#   - Minimal Go edition for low /opt storage

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FEED_URL="${GO_FEED_URL:-$REPO_BASE/scripts/install-entware-feed.sh}"
GO_FULL_URL="${GO_FULL_URL:-$REPO_BASE/xray_vless_failover_go.sh}"
MINIMAL_GO_URL="${MINIMAL_GO_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"
MINIMAL_NEXT_URL="${MINIMAL_NEXT_URL:-$REPO_BASE/xray_vless_failover_minimal_next.sh}"
MINIMAL_GO_MENU_URL="${MINIMAL_GO_MENU_URL:-$REPO_BASE/scripts/minimal-go-menu.sh}"

GO_TMP="/opt/tmp/install-entware-feed.latest.sh"
GO_FULL_TMP="/opt/tmp/xray_vless_failover_go.sh"
MINIMAL_GO_TMP="/opt/tmp/xray_vless_failover_minimal_go.sh"
MINIMAL_NEXT_TMP="/opt/tmp/xray_vless_failover_minimal_next.sh"
MINIMAL_GO_MENU_BIN="/opt/bin/minimal-go-menu"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
MODE="${MODE:-install}"
NO_CRON="${NO_CRON:-0}"
NO_RESTART="${NO_RESTART:-0}"
FORCE_GO_RESOLVER_UPDATE="${FORCE_GO_RESOLVER_UPDATE:-0}"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_auto_latest.sh [options]

Edition selection:
  --auto                 Auto: low /opt space selects Minimal Go; update-only repairs installed edition
  --go                   Force Go/Entware latest edition
  --minimal-go           Force Minimal Go edition
  --minimal-next         Force legacy minimal-next edition

Modes:
  --detect-only          Print detection/selection only; make no changes
  --doctor               Print diagnostics and recovery status; make no install changes
  --update-only          Safe repair-lite update for already installed edition
  --dry-run              Alias for --detect-only compatibility

Other options:
  --yes                  Do not ask interactive confirmation
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
        --minimal-next|--legacy-minimal) EDITION="minimal-next"; shift ;;
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
case "$EDITION" in auto|go|minimal-go|minimal-next) ;; minimal) EDITION="minimal-go" ;; *) echo "ERROR: unsupported EDITION=$EDITION" >&2; exit 1 ;; esac
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
    if command -v opkg >/dev/null 2>&1; then command -v opkg; elif [ -x /opt/bin/opkg ]; then echo /opt/bin/opkg; else echo ""; fi
}

need_opkg() {
    [ -n "$(opkg_bin)" ] || { echo "ERROR: opkg not found. Entware is required." >&2; exit 1; }
}

opkg_install_missing() {
    OPKG_BIN="$(opkg_bin)"
    missing=""
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        "$OPKG_BIN" status "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    [ -n "$missing" ] || return 0
    echo "Installing missing packages:$missing"
    "$OPKG_BIN" install $missing
}

ensure_curl() {
    command -v curl >/dev/null 2>&1 && return 0
    echo "curl not found. Installing curl via Entware..."
    OPKG_BIN="$(opkg_bin)"
    "$OPKG_BIN" update
    "$OPKG_BIN" install curl ca-certificates || "$OPKG_BIN" install curl ca-bundle || "$OPKG_BIN" install curl
    command -v curl >/dev/null 2>&1 || { echo "ERROR: failed to install curl." >&2; exit 1; }
}

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then command -v xray; elif [ -x /opt/sbin/xray ]; then echo /opt/sbin/xray; elif [ -x /opt/bin/xray ]; then echo /opt/bin/xray; else echo ""; fi
}

ensure_xray() {
    [ -n "$(get_xray_bin)" ] && return 0
    echo "Installing Xray core..."
    OPKG_BIN="$(opkg_bin)"
    "$OPKG_BIN" install xray-core || "$OPKG_BIN" install xray || { echo "ERROR: failed to install xray-core/xray." >&2; exit 1; }
}

ensure_cron() {
    [ "$NO_CRON" = "1" ] && { echo "No cron: skip cron setup."; return 0; }
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        OPKG_BIN="$(opkg_bin)"
        "$OPKG_BIN" install cron || "$OPKG_BIN" install cronie || "$OPKG_BIN" install busybox-cron || echo "WARN: failed to install cron package."
    fi
    if ! ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1; then
        if [ -x /opt/etc/init.d/S10cron ]; then /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
        elif [ -x /opt/etc/init.d/S10crond ]; then /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
        elif command -v crond >/dev/null 2>&1; then crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        elif command -v cron >/dev/null 2>&1; then cron >/dev/null 2>&1 || true
        fi
    fi
}

bootstrap_common_dependencies() {
    need_opkg
    mkdir -p /opt/tmp /opt/etc/xray /opt/var/log
    OPKG_BIN="$(opkg_bin)"
    "$OPKG_BIN" update
    ensure_curl
    opkg_install_missing ca-certificates ca-bundle >/dev/null 2>&1 || true
}

bootstrap_selected_dependencies() {
    case "$1" in
        go) echo "Preparing dependencies for Go/Entware latest edition..."; bootstrap_common_dependencies; opkg_install_missing wget-ssl ca-certificates || true; ensure_cron ;;
        minimal-go) echo "Preparing dependencies for Minimal Go edition..."; bootstrap_common_dependencies; ensure_xray; ensure_cron ;;
        minimal-next) echo "Preparing dependencies for Minimal-next edition..."; bootstrap_common_dependencies; ensure_xray ;;
        *) echo "ERROR: unknown selected edition: $1" >&2; exit 1 ;;
    esac
}

check_shell_syntax() {
    file="$1"
    for shell in /opt/bin/sh /bin/sh sh; do
        ([ -x "$shell" ] || command -v "$shell" >/dev/null 2>&1) || continue
        out="$($shell -n "$file" 2>&1)" && return 0
        case "$out" in *"Invalid option"*|*"illegal option"*|*"bad option"*) continue ;; *) echo "$out" >&2; return 1 ;; esac
    done
    return 0
}

looks_like_shell_script() {
    head -n 1 "$1" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'
}

download_installer() {
    url="$1"
    output="$2"
    label="$3"
    mkdir -p "$(dirname "$output")"
    echo "Downloading $label installer..."
    curl -fsSL -H 'Cache-Control: no-cache' -o "$output" "$url" || { echo "ERROR: failed to download $label installer: $url" >&2; exit 1; }
    looks_like_shell_script "$output" || { echo "ERROR: downloaded $label installer does not look like a shell script: $url" >&2; head -n 3 "$output" >&2 || true; exit 1; }
    check_shell_syntax "$output" || { echo "ERROR: downloaded $label installer failed shell syntax check: $output" >&2; exit 1; }
    chmod +x "$output"
}

download_helper() {
    url="$1"; output="$2"; label="$3"
    mkdir -p "$(dirname "$output")" /opt/tmp
    tmp="/opt/tmp/$(basename "$output").$$"
    echo "Refreshing $label..."
    if curl -fsSL -H 'Cache-Control: no-cache' -o "$tmp" "$url" && looks_like_shell_script "$tmp" && check_shell_syntax "$tmp"; then
        mv "$tmp" "$output"; chmod +x "$output"; return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "WARN: failed to refresh $label from $url" >&2
    return 1
}

space_mb() { awk "BEGIN { printf \"%.1f\", $1 / 1024 }"; }

has_opkg_package() { OPKG_BIN="$(opkg_bin)"; [ -n "$OPKG_BIN" ] && "$OPKG_BIN" status "$1" >/dev/null 2>&1; }

detect_installed_edition() {
    if [ -x /opt/bin/minimal-go-status ] || [ -x /opt/bin/minimal-go-switch ] || [ -f /opt/etc/xray/minimal-go-active ] || [ -x /opt/etc/init.d/S25xray-minimal-go-failover ]; then echo minimal-go; return; fi
    if [ -x /opt/bin/xray-go ] || [ -x /opt/bin/vless-go-failover ] || [ -f /opt/etc/xray/vless-go.active ] || has_opkg_package failover-go; then echo go; return; fi
    if [ -x /opt/bin/vless-failover ] || [ -f /opt/etc/xray/vless.active ]; then echo minimal-next; return; fi
    echo none
}

cron_state() { ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1 && echo running || echo "not running"; }

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
EOF_DETECTION
}

print_selection_notes() {
    echo
    echo "Selection notes:"
    case "$SELECTED" in
        minimal-go)
            echo "  - Minimal Go is selected: direct vless:// only, low storage footprint."
            [ "$FREE_KB" -lt "$THRESHOLD_KB" ] && echo "  - Low /opt space detected; Full Go may fail to install xray-core/failover-go."
            [ "$INSTALLED_EDITION" != "none" ] && [ "$INSTALLED_EDITION" != "minimal-go" ] && echo "  - Existing $INSTALLED_EDITION remnants were detected, but Minimal Go is safer for this /opt size."
            echo "  - After install/check: minimal-go-status ; vless-go-recover --mode minimal status ; minimal-go-menu"
            ;;
        go)
            echo "  - Go/Entware latest is selected: feed package, full menu helpers, subscriptions/failover tooling."
            echo "  - After install/check: xray-go status ; xray-go doctor --json ; vless-go-recover --mode full status"
            ;;
        minimal-next) echo "  - Minimal-next legacy-compatible edition is selected. Prefer Minimal Go for new low-space installs." ;;
    esac
    echo
}

print_post_install_checks() {
    echo
    echo "Post-install checks:"
    case "$1" in
        minimal-go) echo "  minimal-go-status"; echo "  vless-go-recover --mode minimal status"; echo "  minimal-go-menu" ;;
        go) echo "  xray-go status"; echo "  xray-go doctor --json"; echo "  vless-go-recover --mode full status" ;;
        *) echo "  Run status/doctor commands for the selected edition." ;;
    esac
    echo
}

run_recovery_status() { [ -x /opt/bin/vless-go-recover ] && /opt/bin/vless-go-recover --mode "$1" status 2>/dev/null || echo "vless-go-recover: not installed"; }

run_doctor() {
    echo "Diagnostics:"
    echo "  installed runtime: $INSTALLED_EDITION"
    echo "  selected runtime: $SELECTED"
    echo "  opkg: $(command -v opkg >/dev/null 2>&1 && echo yes || echo no)"
    echo "  curl: $(command -v curl >/dev/null 2>&1 && echo yes || echo no)"
    echo "  xray: $([ -n "$(get_xray_bin)" ] && echo yes || echo no)"
    echo "  cron process: $(cron_state)"
    echo "  minimal-go-status: $([ -x /opt/bin/minimal-go-status ] && echo yes || echo no)"
    echo "  minimal-go-switch: $([ -x /opt/bin/minimal-go-switch ] && echo yes || echo no)"
    echo "  minimal-go-menu: $([ -x /opt/bin/minimal-go-menu ] && echo yes || echo no)"
    echo "  xray-go: $([ -x /opt/bin/xray-go ] && echo yes || echo no)"
    echo "  vless-go-failover: $([ -x /opt/bin/vless-go-failover ] && echo yes || echo no)"
    echo "  failover-go package present: $(has_opkg_package failover-go && echo yes || echo no)"
    echo "  vless-go-recover: $([ -x /opt/bin/vless-go-recover ] && echo yes || echo no)"
    echo
    case "$SELECTED" in minimal-go) echo "Recovery status (minimal):"; run_recovery_status minimal ;; go) echo "Recovery status (full):"; run_recovery_status full ;; esac
}

install_minimal_go_menu() { download_helper "$MINIMAL_GO_MENU_URL" "$MINIMAL_GO_MENU_BIN" "Minimal Go menu"; }

safe_update_minimal_go() {
    echo "Safe update for Minimal Go edition..."
    bootstrap_selected_dependencies minimal-go
    download_installer "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go repair"
    args="--repair-only"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$NO_RESTART" = "1" ] && args="$args --no-restart"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Minimal Go repair: $MINIMAL_GO_TMP $args"
    sh "$MINIMAL_GO_TMP" $args
    install_minimal_go_menu || true
    print_post_install_checks minimal-go
}

safe_update_go() {
    echo "Safe update for Go/Entware latest edition..."
    bootstrap_selected_dependencies go
    download_installer "$GO_FULL_URL" "$GO_FULL_TMP" "Full Go repair"
    args="--repair-only"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$NO_RESTART" = "1" ] && args="$args --no-restart"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Full Go repair: $GO_FULL_TMP $args"
    sh "$GO_FULL_TMP" $args
    print_post_install_checks go
}

safe_update_minimal_next() {
    echo "Safe update for Minimal-next edition..."
    bootstrap_selected_dependencies minimal-next
    download_installer "$MINIMAL_NEXT_URL" "$MINIMAL_NEXT_TMP" "Minimal-next"
    echo "Minimal-next installer refreshed at: $MINIMAL_NEXT_TMP"
}

run_update_only() {
    echo "Update-only mode: repair-lite; no config rewrite, no source rewrite, no agent changes."
    case "$SELECTED" in minimal-go) safe_update_minimal_go ;; go) safe_update_go ;; minimal-next) safe_update_minimal_next ;; *) echo "ERROR: no installed or selected edition to update" >&2; exit 1 ;; esac
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
bootstrap_selected_dependencies "$SELECTED"

case "$SELECTED" in
    minimal-go)
        cat <<'EOF_MINIMAL_GO'
Minimal Go edition:
  - direct vless:// links only
  - primary/backup failover
  - no subscriptions
  - no python3
  - no Entware feed package
  - intended for low-storage Entware installs around 40 MB free
EOF_MINIMAL_GO
        confirm_install "Minimal Go"
        download_installer "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go"
        sh "$MINIMAL_GO_TMP"
        install_minimal_go_menu || true
        print_post_install_checks minimal-go
        exit 0
        ;;
    minimal-next)
        cat <<'EOF_MINIMAL_NEXT'
Minimal-next legacy-compatible edition:
  - direct vless:// links only
  - no subscriptions
  - no python3
  - legacy shell backend
  - kept as compatibility fallback
EOF_MINIMAL_NEXT
        confirm_install "Minimal-next legacy-compatible"
        download_installer "$MINIMAL_NEXT_URL" "$MINIMAL_NEXT_TMP" "Minimal-next"
        exec sh "$MINIMAL_NEXT_TMP"
        ;;
esac

cat <<'EOF_GO'
Go/Entware latest edition:
  - installs failover-go from GitHub Release feed
  - auto-selects Entware architecture in feed bootstrap
  - includes vless-go-doctor, watchdog, updater and menu helpers
EOF_GO
confirm_install "Go/Entware latest"
download_installer "$GO_FEED_URL" "$GO_TMP" "Go/Entware latest"
exec sh "$GO_TMP"
