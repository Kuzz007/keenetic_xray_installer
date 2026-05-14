#!/bin/sh
set -e

# Auto installer latest edition.
# Does not replace legacy xray_vless_failover_auto.sh.
# Chooses between:
#   - Go/Entware latest feed edition for normal /opt storage
#   - Minimal Go edition for low /opt storage

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FEED_URL="${GO_FEED_URL:-$REPO_BASE/scripts/install-entware-feed.sh}"
MINIMAL_GO_URL="${MINIMAL_GO_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"
MINIMAL_NEXT_URL="${MINIMAL_NEXT_URL:-$REPO_BASE/xray_vless_failover_minimal_next.sh}"

GO_TMP="/opt/tmp/install-entware-feed.latest.sh"
MINIMAL_GO_TMP="/opt/tmp/xray_vless_failover_minimal_go.sh"
MINIMAL_NEXT_TMP="/opt/tmp/xray_vless_failover_minimal_next.sh"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_auto_latest.sh [--go|--minimal-go|--minimal-next|--auto] [--yes] [--dry-run]

Environment overrides:
  EDITION=auto|go|minimal-go|minimal-next
  THRESHOLD_KB=80000
  ASSUME_YES=1
  DRY_RUN=1
  REPO_BASE=https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main
  GO_FEED_URL=<url>
  MINIMAL_GO_URL=<url>
  MINIMAL_NEXT_URL=<url>

This script does not modify legacy xray_vless_failover_auto.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --go) EDITION="go"; shift ;;
        --minimal|--minimal-go) EDITION="minimal-go"; shift ;;
        --minimal-next|--legacy-minimal) EDITION="minimal-next"; shift ;;
        --auto) EDITION="auto"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        --dry-run|--check|--print-selection) DRY_RUN="1"; shift ;;
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

space_mb() {
    kb="$1"
    awk "BEGIN { printf \"%.1f\", $kb / 1024 }"
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

if [ "$EDITION" = "auto" ]; then
    if [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
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

cat <<EOF
Free /opt space: ${FREE_KB} KB (${FREE_MB} MB)
Full/Go threshold: ${THRESHOLD_KB} KB (${THRESHOLD_MB} MB)
Selected edition: $SELECTED
Selection reason: $SELECT_REASON
EOF

if [ "$DRY_RUN" = "1" ]; then
    echo "Dry run: installer selection only; no edition installer executed."
    exit 0
fi

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
        exec "$MINIMAL_GO_TMP"
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