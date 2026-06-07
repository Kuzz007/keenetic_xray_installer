#!/bin/sh
set -e

# Keenetic Xray Go v2 public installer entrypoint.
#
# Default stage: safe compatibility wrapper around the existing Auto Latest
# selector. Experimental direct-install v2 can be started explicitly with
# --direct-experimental, but it does not replace the stable flow yet.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
AUTO_LATEST_URL="${AUTO_LATEST_URL:-${REPO_BASE}/xray_vless_failover_auto_latest.sh}"
DIRECT_INSTALL_URL="${DIRECT_INSTALL_URL:-${REPO_BASE}/scripts/xray-go-direct-install.sh}"
DIRECT_INIT_URL="${DIRECT_INIT_URL:-${REPO_BASE}/scripts/xray-go-direct-init.sh}"

if [ -d /opt ]; then
    TMP_DIR="${TMPDIR:-/opt/tmp}"
else
    TMP_DIR="${TMPDIR:-/tmp}"
fi

TMP_FILE="${TMP_DIR}/xray_vless_failover_auto_latest.$$"
DIRECT_TMP_FILE="${TMP_DIR}/xray_go_direct_install.$$"
DIRECT_INIT_TMP_FILE="${TMP_DIR}/xray_go_direct_init.$$"

cleanup() {
    rm -f "$TMP_FILE" "$DIRECT_TMP_FILE" "$DIRECT_INIT_TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'USAGE'
Keenetic Xray Go installer

Usage:
  install.sh [auto_latest options]
  install.sh --direct-experimental [direct options]
  install.sh --direct-detect-only [direct options]
  install.sh --direct-init-experimental [direct init options]
  install.sh --direct-init-post-check

Default mode:
  Without direct flags, this wrapper downloads and runs the stable
  xray_vless_failover_auto_latest.sh selector.

Experimental direct-install v2:
  --direct-experimental        Run scripts/xray-go-direct-install.sh
  --direct-detect-only         Run direct-install detection only; make no changes
  --direct-init-experimental   Run scripts/xray-go-direct-init.sh
  --direct-init-post-check     Run direct init/service read-only checks

Examples:
  install.sh --detect-only
  install.sh --direct-detect-only
  install.sh --direct-experimental --prepare-only
  install.sh --direct-experimental --download-binary
  install.sh --direct-experimental --install-binary
  install.sh --direct-experimental --stage-helpers
  install.sh --direct-experimental --install-helpers
  install.sh --direct-experimental --post-check
  install.sh --direct-init-experimental --stage-watchdog-init
  install.sh --direct-init-experimental --install-watchdog-init -y
  install.sh --direct-init-post-check
USAGE
}

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

    echo "ERROR: curl or wget is required to download installer." >&2
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

run_downloaded_script() {
    url="$1"
    output="$2"
    label="$3"
    shift 3

    echo "Downloading $label: $url"
    fetch_url "$url" "$output" || {
        echo "ERROR: failed to download $label." >&2
        exit 1
    }

    looks_like_shell_script "$output" || {
        echo "ERROR: downloaded $label does not look like a shell script." >&2
        head -n 3 "$output" >&2 || true
        exit 1
    }

    sh -n "$output" || {
        echo "ERROR: downloaded $label failed shell syntax check." >&2
        exit 1
    }

    chmod +x "$output"
    set +e
    sh "$output" "$@"
    rc="$?"
    set -e
    exit "$rc"
}

mkdir -p "$TMP_DIR"

case "${1:-}" in
    -h|--help|help)
        usage
        exit 0
        ;;
    --direct-experimental)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-install experimental"
        run_downloaded_script "$DIRECT_INSTALL_URL" "$DIRECT_TMP_FILE" "direct-install skeleton" "$@"
        ;;
    --direct-detect-only)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-install detect-only"
        run_downloaded_script "$DIRECT_INSTALL_URL" "$DIRECT_TMP_FILE" "direct-install skeleton" --detect-only "$@"
        ;;
    --direct-init-experimental)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-init experimental"
        run_downloaded_script "$DIRECT_INIT_URL" "$DIRECT_INIT_TMP_FILE" "direct-init helper" "$@"
        ;;
    --direct-init-post-check)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-init post-check"
        run_downloaded_script "$DIRECT_INIT_URL" "$DIRECT_INIT_TMP_FILE" "direct-init helper" --post-check "$@"
        ;;
esac

echo "Keenetic Xray Go installer"
echo "Entrypoint: install.sh"
echo "Downloading Auto Latest selector: $AUTO_LATEST_URL"
run_downloaded_script "$AUTO_LATEST_URL" "$TMP_FILE" "Auto Latest selector" "$@"
