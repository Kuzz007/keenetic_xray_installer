#!/bin/sh
set -e

# Minimal-next entrypoint.
# Does not replace legacy xray_vless_failover_minimal.sh.
# Wraps the existing minimal installer with safer preflight checks and a stable new URL.

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
LEGACY_MINIMAL_URL="${LEGACY_MINIMAL_URL:-$REPO_BASE/xray_vless_failover_minimal.sh}"
LEGACY_MINIMAL_TMP="/opt/tmp/xray_vless_failover_minimal.legacy.sh"
ASSUME_YES="${ASSUME_YES:-0}"
RUN_LEGACY_ARGS="${RUN_LEGACY_ARGS:-}"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_minimal_next.sh [--yes] [--reuse-failover]

Environment overrides:
  ASSUME_YES=1
  REPO_BASE=https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main
  LEGACY_MINIMAL_URL=<url>

Minimal-next intentionally keeps a separate URL from legacy xray_vless_failover_minimal.sh.
It currently delegates the installation to the legacy minimal backend after preflight checks.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES="1"; shift ;;
        --reuse-failover) RUN_LEGACY_ARGS="${RUN_LEGACY_ARGS} --reuse-failover"; shift ;;
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
    [ "$ASSUME_YES" = "1" ] && return 0
    read_tty "Install Minimal-next legacy-compatible edition? [Y/n]: "
    ans="$REPLY"
    case "$ans" in
        n|N|no|NO|Нет|нет) echo "Cancelled."; exit 0 ;;
    esac
}

show_space() {
    echo "Storage summary:"
    df -h /opt 2>/dev/null || true
    echo
}

preflight() {
    if ! command -v opkg >/dev/null 2>&1; then
        echo "ERROR: opkg not found. Entware is required." >&2
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl not found; attempting minimal curl install..."
        opkg update
        opkg install curl ca-bundle
    else
        opkg install ca-bundle >/dev/null 2>&1 || true
    fi

    mkdir -p /opt/tmp /opt/etc/xray /opt/var/log
}

download_legacy_minimal() {
    echo "Downloading legacy minimal backend..."
    if ! curl -fsSL -o "$LEGACY_MINIMAL_TMP" "$LEGACY_MINIMAL_URL"; then
        echo "ERROR: failed to download legacy minimal backend: $LEGACY_MINIMAL_URL" >&2
        exit 1
    fi
    if ! sh -n "$LEGACY_MINIMAL_TMP"; then
        echo "ERROR: downloaded legacy minimal backend failed shell syntax check: $LEGACY_MINIMAL_TMP" >&2
        exit 1
    fi
    chmod +x "$LEGACY_MINIMAL_TMP"
}

cat <<'EOF'
Minimal-next edition

This is a separate entrypoint and does not modify legacy xray_vless_failover_minimal.sh.
Current behavior:
  - performs preflight checks
  - downloads the legacy minimal backend
  - runs it unchanged

Minimal limitations:
  - direct vless:// links only
  - no subscriptions
  - no python3 requirement
  - no cron auto-update
EOF

show_space
confirm_install
preflight
download_legacy_minimal

# shellcheck disable=SC2086
exec "$LEGACY_MINIMAL_TMP" $RUN_LEGACY_ARGS
