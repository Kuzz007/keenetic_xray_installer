#!/bin/sh
set -e

# Auto installer latest edition.
# Does not replace legacy xray_vless_failover_auto.sh.
# Chooses between:
#   - Go/Entware latest feed edition for normal /opt storage
#   - Minimal-next legacy-compatible edition for low /opt storage

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FEED_URL="${GO_FEED_URL:-$REPO_BASE/scripts/install-entware-feed.sh}"
MINIMAL_NEXT_URL="${MINIMAL_NEXT_URL:-$REPO_BASE/xray_vless_failover_minimal_next.sh}"

GO_TMP="/opt/tmp/install-entware-feed.latest.sh"
MINIMAL_NEXT_TMP="/opt/tmp/xray_vless_failover_minimal_next.sh"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_auto_latest.sh [--go|--minimal|--auto] [--yes]

Environment overrides:
  EDITION=auto|go|minimal
  THRESHOLD_KB=80000
  ASSUME_YES=1
  REPO_BASE=https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main
  GO_FEED_URL=<url>
  MINIMAL_NEXT_URL=<url>

This script does not modify legacy xray_vless_failover_auto.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --go) EDITION="go"; shift ;;
        --minimal) EDITION="minimal"; shift ;;
        --auto) EDITION="auto"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
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

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl not found." >&2
    echo "Run: opkg update && opkg install curl ca-bundle" >&2
    exit 1
fi

if ! command -v opkg >/dev/null 2>&1; then
    echo "ERROR: opkg not found. Entware is required." >&2
    exit 1
fi

mkdir -p /opt/tmp

FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2 { print $4 }')"
[ -n "$FREE_KB" ] || FREE_KB="0"

case "$EDITION" in
    auto|go|minimal) ;;
    *) echo "ERROR: unsupported EDITION=$EDITION; use auto, go or minimal" >&2; exit 1 ;;
esac

if [ "$EDITION" = "auto" ]; then
    if [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal"
    else
        SELECTED="go"
    fi
else
    SELECTED="$EDITION"
fi

cat <<EOF
Free /opt space: ${FREE_KB} KB
Full/Go threshold: ${THRESHOLD_KB} KB
Selected edition: $SELECTED
EOF

if [ "$SELECTED" = "minimal" ]; then
    cat <<'EOF'

Minimal-next edition:
  - direct vless:// links only
  - no subscriptions
  - no python3
  - no cron auto-update
  - intended for low-storage Entware installs
EOF
    confirm_install "Minimal-next"
    download_installer "$MINIMAL_NEXT_URL" "$MINIMAL_NEXT_TMP" "Minimal-next"
    exec "$MINIMAL_NEXT_TMP"
fi

cat <<'EOF'

Go/Entware latest edition:
  - installs failover-go from GitHub Release feed
  - auto-selects Entware architecture
  - supports latest aarch64 and mipsel feeds
  - includes vless-go-doctor, watchdog, updater and menu helpers
EOF
confirm_install "Go/Entware latest"
download_installer "$GO_FEED_URL" "$GO_TMP" "Go/Entware latest"
exec sh "$GO_TMP"
