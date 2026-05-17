#!/bin/sh
set -e

# Auto installer latest edition.
# Does not replace legacy xray_vless_failover_auto.sh.
# Chooses between:
#   - Go/Entware latest feed edition for normal /opt storage
#   - Minimal Go edition for low /opt storage
# Safe modes are intentionally read-only or repair-lite and do not touch Telegram agents.

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FEED_URL="${GO_FEED_URL:-$REPO_BASE/scripts/install-entware-feed.sh}"
GO_FULL_URL="${GO_FULL_URL:-$REPO_BASE/xray_vless_failover_go.sh}"
MINIMAL_GO_URL="${MINIMAL_GO_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"
MINIMAL_NEXT_URL="${MINIMAL_NEXT_URL:-$REPO_BASE/xray_vless_failover_minimal_next.sh}"
RECOVER_URL="${RECOVER_URL:-$REPO_BASE/scripts/vless-go-recover.sh}"
DOCTOR_URL="${DOCTOR_URL:-$REPO_BASE/scripts/vless-go-doctor.sh}"
MINIMAL_GO_MENU_URL="${MINIMAL_GO_MENU_URL:-$REPO_BASE/scripts/minimal-go-menu.sh}"

GO_TMP="/opt/tmp/install-entware-feed.latest.sh"
GO_FULL_TMP="/opt/tmp/xray_vless_failover_go.sh"
MINIMAL_GO_TMP="/opt/tmp/xray_vless_failover_minimal_go.sh"
MINIMAL_NEXT_TMP="/opt/tmp/xray_vless_failover_minimal_next.sh"
MINIMAL_GO_MENU_BIN="/opt/bin/minimal-go-menu"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
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
  --yes                  Do not ask interactive install confirmation
  --force-go-resolver    Re-download /opt/bin/xray-failover-go during update-only repair
  --no-cron              Do not create/modify cron entries in safe update path
  --no-restart           Do not restart services in safe update path
  -h, --help             Show help

Environment overrides:
  EDITION=auto|go|minimal-go|minimal-next
  THRESHOLD_KB=80000
  ASSUME_YES=1
  MODE=install|detect-only|doctor|update-only
  FORCE_GO_RESOLVER_UPDATE=1
  NO_CRON=1
  NO_RESTART=1
  REPO_BASE=https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main
  GO_FEED_URL=<url>
  GO_FULL_URL=<url>
  MINIMAL_GO_URL=<url>
  MINIMAL_GO_MENU_URL=<url>
  MINIMAL_NEXT_URL=<url>

Rollback safety:
  This script does not modify Telegram agents and does not replace legacy xray_vless_failover_auto.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --go|--force-go) EDITION="go"; shift ;;
        --minimal|--minimal-go|--force-minimal) EDITION="minimal-go"; shift ;;
        --minimal-next|--legacy-minimal) EDITION="minimal-next"; shift ;;
        --auto) EDITION="auto"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        --dry-run|--check|--print-selection|--detect-only) MODE="detect-only"; DRY_RUN="1"; shift ;;
        --doctor) MODE="doctor"; shift ;;
        --update-only) MODE="update-only"; ASSUME_YES="1"; shift ;;
        --force-go-resolver|--force-resolver) FORCE_GO_RESOLVER_UPDATE="1"; shift ;;
        --no-cron) NO_CRON="1"; shift ;;
        --no-restart) NO_RESTART="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

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
    ans="$REPLY"
    case "$ans" in
        n|N|no|NO|Нет|нет) echo "Cancelled."; exit 0 ;;
    esac
}

need_opkg() {
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is required." >&2
        exit 1
    fi
}

opkg_install_missing() {
    missing=""
    for pkg in "$@"; do
        [ -n "$pkg" ] || continue
        if opkg status "$pkg" >/dev/null 2>&1; then
            continue
        fi
        missing="$missing $pkg"
    done

    [ -n "$missing" ] || return 0
    echo "Installing missing packages:$missing"
    opkg install $missing
}

ensure_curl() {
    if command -v curl >/dev/null 2>&1; then
        return 0
    fi

    echo "curl not found. Installing curl via Entware..."
    need_opkg
    opkg update
    opkg install curl ca-certificates || opkg install curl ca-bundle || opkg install curl

    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: failed to install curl." >&2
        echo "Try manually: opkg update && opkg install curl" >&2
        exit 1
    fi
}

ensure_xray() {
    if command -v xray >/dev/null 2>&1 || [ -x /opt/bin/xray ] || [ -x /opt/sbin/xray ]; then
        return 0
    fi

    echo "Installing Xray core..."
    opkg install xray-core || opkg install xray || {
        echo "ERROR: failed to install xray-core/xray." >&2
        exit 1
    }
}

ensure_cron() {
    [ "$NO_CRON" = "1" ] && { echo "No cron: skip cron setup."; return 0; }
    mkdir -p /opt/var/spool/cron/crontabs /opt/var/log
    touch /opt/var/spool/cron/crontabs/root 2>/dev/null || true
    chmod 600 /opt/var/spool/cron/crontabs/root 2>/dev/null || true

    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        echo "Installing cron..."
        opkg install cron || opkg install cronie || opkg install busybox-cron || {
            echo "WARN: failed to install cron package; hourly recovery will need manual setup." >&2
            return 0
        }
    fi

    if ! ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1; then
        if [ -x /opt/etc/init.d/S10cron ]; then
            /opt/etc/init.d/S10cron start >/dev/null 2>&1 || true
        elif [ -x /opt/etc/init.d/S10crond ]; then
            /opt/etc/init.d/S10crond start >/dev/null 2>&1 || true
        elif command -v crond >/dev/null 2>&1; then
            crond -c /opt/var/spool/cron/crontabs >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
        elif command -v cron >/dev/null 2>&1; then
            cron >/dev/null 2>&1 || true
        fi
    fi
}

bootstrap_common_dependencies() {
    need_opkg
    mkdir -p /opt/tmp /opt/etc/xray /opt/var/log
    opkg update
    ensure_curl
    opkg_install_missing ca-certificates ca-bundle >/dev/null 2>&1 || true
}

bootstrap_go_dependencies() {
    echo "Preparing dependencies for Go/Entware latest edition..."
    bootstrap_common_dependencies
    opkg_install_missing wget-ssl ca-certificates || true
    ensure_cron
}

bootstrap_minimal_go_dependencies() {
    echo "Preparing dependencies for Minimal Go edition..."
    bootstrap_common_dependencies
    ensure_xray
    ensure_cron
}

bootstrap_minimal_next_dependencies() {
    echo "Preparing dependencies for Minimal-next edition..."
    bootstrap_common_dependencies
    ensure_xray
}

bootstrap_selected_dependencies() {
    case "$1" in
        go) bootstrap_go_dependencies ;;
        minimal-go) bootstrap_minimal_go_dependencies ;;
        minimal-next) bootstrap_minimal_next_dependencies ;;
        *) echo "ERROR: unknown selected edition for dependency bootstrap: $1" >&2; exit 1 ;;
    esac
}

download_installer() {
    url="$1"
    output="$2"
    label="$3"

    echo "Downloading $label installer..."
    if ! curl -fsSL -o "$output" "$url"; then
        echo "ERROR: failed to download $label installer: $url" >&2
        echo "Check internet, DNS and GitHub/raw.githubusercontent.com availability." >&2
        exit 1
    fi

    if ! sh -n "$output"; then
        echo "ERROR: downloaded $label installer failed shell syntax check: $output" >&2
        exit 1
    fi

    chmod +x "$output"
}

download_helper() {
    url="$1"
    output="$2"
    label="$3"
    mkdir -p "$(dirname "$output")" /opt/tmp
    tmp="/opt/tmp/$(basename "$output").$$"
    echo "Refreshing $label..."
    if curl -fsSL -o "$tmp" "$url" && sh -n "$tmp"; then
        mv "$tmp" "$output"
        chmod +x "$output"
        return 0
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "WARN: failed to refresh $label from $url" >&2
    return 1
}

space_mb() {
    kb="$1"
    awk "BEGIN { printf \"%.1f\", $kb / 1024 }"
}

has_opkg_package() {
    pkg="$1"
    opkg status "$pkg" >/dev/null 2>&1
}

detect_installed_edition() {
    if [ -x /opt/bin/minimal-go-status ] || [ -x /opt/bin/minimal-go-switch ] || [ -f /opt/etc/xray/minimal-go-active ] || [ -x /opt/etc/init.d/S25xray-minimal-go-failover ]; then
        echo "minimal-go"
        return 0
    fi
    if [ -x /opt/bin/xray-go ] || [ -x /opt/bin/vless-go-failover ] || [ -f /opt/etc/xray/vless-go.active ] || has_opkg_package failover-go; then
        echo "go"
        return 0
    fi
    if [ -x /opt/bin/vless-failover ] || [ -f /opt/etc/xray/vless.active ]; then
        echo "minimal-next"
        return 0
    fi
    echo "none"
}

cron_state() {
    if ps 2>/dev/null | grep -Ei '[c]ron[d]?' >/dev/null 2>&1; then
        echo "running"
    else
        echo "not running"
    fi
}

print_detection() {
    cat <<EOF
Free /opt space: ${FREE_KB} KB (${FREE_MB} MB)
Full/Go threshold: ${THRESHOLD_KB} KB (${THRESHOLD_MB} MB)
Installed edition: $INSTALLED_EDITION
Selected edition: $SELECTED
Selection reason: $SELECT_REASON
Mode: $MODE
No cron: $NO_CRON
No restart: $NO_RESTART
Force Go resolver update: $FORCE_GO_RESOLVER_UPDATE
EOF
}

run_recovery_status() {
    mode="$1"
    if [ -x /opt/bin/vless-go-recover ]; then
        /opt/bin/vless-go-recover --mode "$mode" status 2>/dev/null || true
    else
        echo "vless-go-recover: not installed"
    fi
}

run_doctor() {
    echo "Diagnostics:"
    echo "  installed runtime: $INSTALLED_EDITION"
    echo "  selected runtime: $SELECTED"
    echo "  opkg: $(command -v opkg >/dev/null 2>&1 && echo yes || echo no)"
    echo "  curl: $(command -v curl >/dev/null 2>&1 && echo yes || echo no)"
    echo "  xray: $(command -v xray >/dev/null 2>&1 || [ -x /opt/bin/xray ] || [ -x /opt/sbin/xray ] && echo yes || echo no)"
    echo "  cron process: $(cron_state)"
    echo "  cron root file: $([ -f /opt/var/spool/cron/crontabs/root ] && echo yes || echo no)"
    echo "  minimal-go-status: $([ -x /opt/bin/minimal-go-status ] && echo yes || echo no)"
    echo "  minimal-go-switch: $([ -x /opt/bin/minimal-go-switch ] && echo yes || echo no)"
    echo "  minimal-go-menu: $([ -x /opt/bin/minimal-go-menu ] && echo yes || echo no)"
    echo "  minimal failover init: $([ -x /opt/etc/init.d/S25xray-minimal-go-failover ] && /opt/etc/init.d/S25xray-minimal-go-failover status 2>/dev/null | sed -n '1p' || echo not installed)"
    echo "  xray-go: $([ -x /opt/bin/xray-go ] && echo yes || echo no)"
    echo "  vless-go-failover: $([ -x /opt/bin/vless-go-failover ] && echo yes || echo no)"
    echo "  failover-go package present: $(has_opkg_package failover-go && echo yes || echo no)"
    echo "  vless-go-recover: $([ -x /opt/bin/vless-go-recover ] && echo yes || echo no)"
    echo "  vless-go-doctor: $([ -x /opt/bin/vless-go-doctor ] && echo yes || echo no)"
    echo
    case "$SELECTED" in
        minimal-go)
            echo "Recovery status (minimal):"
            run_recovery_status minimal
            ;;
        go)
            echo "Recovery status (full):"
            run_recovery_status full
            ;;
        *)
            echo "Recovery status: no supported edition selected"
            ;;
    esac
}

install_minimal_go_menu() {
    download_helper "$MINIMAL_GO_MENU_URL" "$MINIMAL_GO_MENU_BIN" "Minimal Go menu"
}

safe_update_minimal_go() {
    echo "Safe update for Minimal Go edition..."
    echo "Repair-lite: delegated to Minimal Go installer --repair-only; no config rewrite, no source rewrite."
    bootstrap_minimal_go_dependencies
    download_installer "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go repair"
    args="--repair-only"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Minimal Go repair: $MINIMAL_GO_TMP $args"
    sh "$MINIMAL_GO_TMP" $args
    install_minimal_go_menu || true
}

safe_update_go() {
    echo "Safe update for Go/Entware latest edition..."
    echo "Repair-lite: delegated to Full Go installer --repair-only; no config rewrite, no source rewrite."
    bootstrap_go_dependencies
    download_installer "$GO_FULL_URL" "$GO_FULL_TMP" "Full Go repair"
    args="--repair-only --no-restart"
    [ "$NO_CRON" = "1" ] && args="$args --no-cron"
    [ "$FORCE_GO_RESOLVER_UPDATE" = "1" ] && args="$args --force-go-resolver"
    echo "Running Full Go repair: $GO_FULL_TMP $args"
    sh "$GO_FULL_TMP" $args
}

safe_update_minimal_next() {
    echo "Safe update for Minimal-next edition..."
    echo "Repair-lite: installer refresh only; no config rewrite, no source rewrite."
    bootstrap_minimal_next_dependencies
    download_installer "$MINIMAL_NEXT_URL" "$MINIMAL_NEXT_TMP" "Minimal-next"
    echo "Minimal-next installer refreshed at: $MINIMAL_NEXT_TMP"
    echo "No config rewrite performed. Run the installer manually for full reinstall if needed."
}

run_update_only() {
    echo "Update-only mode: repair-lite; no config rewrite, no source rewrite, no Telegram agent changes."
    case "$SELECTED" in
        minimal-go) safe_update_minimal_go ;;
        go) safe_update_go ;;
        minimal-next) safe_update_minimal_next ;;
        *) echo "ERROR: no installed or selected edition to update" >&2; exit 1 ;;
    esac
    echo "Update-only complete."
}

need_opkg
ensure_curl
mkdir -p /opt/tmp

FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2 { print $4 }')"
case "$FREE_KB" in
    ''|*[!0-9]*) FREE_KB="0" ;;
esac

case "$THRESHOLD_KB" in
    ''|*[!0-9]*) echo "ERROR: THRESHOLD_KB must be numeric, got: $THRESHOLD_KB" >&2; exit 1 ;;
esac

case "$EDITION" in
    auto|go|minimal-go|minimal-next) ;;
    minimal) EDITION="minimal-go" ;;
    *) echo "ERROR: unsupported EDITION=$EDITION; use auto, go, minimal-go or minimal-next" >&2; exit 1 ;;
esac

case "$MODE" in
    install|detect-only|doctor|update-only) ;;
    *) echo "ERROR: unsupported MODE=$MODE" >&2; exit 1 ;;
esac

INSTALLED_EDITION="$(detect_installed_edition)"

if [ "$EDITION" = "auto" ]; then
    if [ "$MODE" = "install" ] && [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal-go"
        if [ "$INSTALLED_EDITION" != "none" ] && [ "$INSTALLED_EDITION" != "minimal-go" ]; then
            SELECT_REASON="low /opt space overrides installed $INSTALLED_EDITION remnants"
        else
            SELECT_REASON="free /opt space is below threshold"
        fi
    elif [ "$INSTALLED_EDITION" != "none" ]; then
        SELECTED="$INSTALLED_EDITION"
        SELECT_REASON="existing installation detected"
    elif [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal-go"
        SELECT_REASON="free /opt space is below threshold"
    else
        SELECTED="go"
        SELECT_REASON="free /opt space is at or above threshold"
    fi
else
    SELECTED="$EDITION"
    SELECT_REASON="explicit edition override"
fi

FREE_MB="$(space_mb "$FREE_KB")"
THRESHOLD_MB="$(space_mb "$THRESHOLD_KB")"

print_detection

case "$MODE" in
    detect-only)
        echo "Detect-only: no changes made."
        exit 0
        ;;
    doctor)
        echo
        run_doctor
        exit 0
        ;;
    update-only)
        run_update_only
        exit 0
        ;;
esac

bootstrap_selected_dependencies "$SELECTED"

case "$SELECTED" in
    minimal-go)
        cat <<'EOF'

Minimal Go edition:
  - direct vless:// links only
  - primary/backup failover
  - no subscriptions
  - no python3
  - no Entware feed package
  - intended for low-storage Entware installs around 40 MB free
EOF
        confirm_install "Minimal Go"
        download_installer "$MINIMAL_GO_URL" "$MINIMAL_GO_TMP" "Minimal Go"
        sh "$MINIMAL_GO_TMP"
        install_minimal_go_menu || true
        exit 0
        ;;
    minimal-next)
        cat <<'EOF'

Minimal-next legacy-compatible edition:
  - direct vless:// links only
  - no subscriptions
  - no python3
  - legacy shell backend
  - kept as compatibility fallback
EOF
        confirm_install "Minimal-next legacy-compatible"
        download_installer "$MINIMAL_NEXT_URL" "$MINIMAL_NEXT_TMP" "Minimal-next"
        exec "$MINIMAL_NEXT_TMP"
        ;;
esac

cat <<'EOF'

Go/Entware latest edition:
  - installs failover-go from GitHub Release feed
  - auto-selects Entware architecture in feed bootstrap
  - includes vless-go-doctor, watchdog, updater and menu helpers
EOF
confirm_install "Go/Entware latest"
download_installer "$GO_FEED_URL" "$GO_TMP" "Go/Entware latest"
exec sh "$GO_TMP"
