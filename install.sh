#!/bin/sh
set -e

# Keenetic Xray Go v2 public installer entrypoint.
#
# Default stage: safe compatibility wrapper around the existing Auto Latest
# selector. Direct-install v2 is available through public explicit aliases:
# --direct-plan, --direct-apply --yes, and --direct-check. The old
# --direct-*-experimental flags remain compatibility aliases.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
AUTO_LATEST_URL="${AUTO_LATEST_URL:-${REPO_BASE}/xray_vless_failover_auto_latest.sh}"
DIRECT_INSTALL_URL="${DIRECT_INSTALL_URL:-${REPO_BASE}/scripts/xray-go-direct-install.sh}"
DIRECT_INIT_URL="${DIRECT_INIT_URL:-${REPO_BASE}/scripts/xray-go-direct-init.sh}"
DIRECT_FULL_URL="${DIRECT_FULL_URL:-${REPO_BASE}/scripts/xray-go-direct-full.sh}"
DIRECT_UNINSTALL_URL="${DIRECT_UNINSTALL_URL:-${REPO_BASE}/scripts/xray-go-direct-uninstall.sh}"
DIRECT_SETUP_URL="${DIRECT_SETUP_URL:-${REPO_BASE}/scripts/xray-go-direct-setup.sh}"

if [ -d /opt ]; then
    TMP_DIR="${TMPDIR:-/opt/tmp}"
else
    TMP_DIR="${TMPDIR:-/tmp}"
fi

TMP_FILE="${TMP_DIR}/xray_vless_failover_auto_latest.$$"
DIRECT_TMP_FILE="${TMP_DIR}/xray_go_direct_install.$$"
DIRECT_INIT_TMP_FILE="${TMP_DIR}/xray_go_direct_init.$$"
DIRECT_FULL_TMP_FILE="${TMP_DIR}/xray_go_direct_full.$$"
DIRECT_UNINSTALL_TMP_FILE="${TMP_DIR}/xray_go_direct_uninstall.$$"
DIRECT_SETUP_TMP_FILE="${TMP_DIR}/xray_go_direct_setup.$$"

cleanup() {
    rm -f "$TMP_FILE" "$DIRECT_TMP_FILE" "$DIRECT_INIT_TMP_FILE" "$DIRECT_FULL_TMP_FILE" "$DIRECT_UNINSTALL_TMP_FILE" "$DIRECT_SETUP_TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

usage() {
    cat <<'USAGE'
Keenetic Xray Go installer

Usage:
  install.sh [auto_latest options]
  install.sh --direct-plan
  install.sh --direct-apply --yes
  install.sh --direct-check
  install.sh --direct-init-check
  install.sh --direct-setup-plan
  install.sh --direct-uninstall-plan
  install.sh --direct-uninstall-guarded --yes

Default mode:
  Without direct flags, this wrapper downloads and runs the compatible
  xray_vless_failover_auto_latest.sh selector.

Direct-install v2 public aliases:
  --direct-plan                  Print full direct-install plan; make no changes
  --direct-apply                 Apply full direct sequence; requires --yes
  --direct-check                 Run direct-install read-only post-check
  --direct-init-check            Run direct init/service read-only checks
  --direct-setup-plan            Analyze first-run/setup state; make no changes
  --direct-uninstall-plan        Print direct uninstall/cleanup plan; make no changes
  --direct-uninstall-guarded     Run guarded uninstall apply scaffold; requires --yes

Low-level direct-install compatibility aliases:
  --direct-experimental             Run scripts/xray-go-direct-install.sh
  --direct-detect-only              Run direct-install detection only; make no changes
  --direct-init-experimental        Run scripts/xray-go-direct-init.sh
  --direct-init-post-check          Alias of --direct-init-check
  --direct-full-dry-run             Alias of --direct-plan
  --direct-full-experimental        Alias of --direct-apply
  --direct-uninstall-dry-run        Alias of --direct-uninstall-plan
  --direct-uninstall-experimental   Alias of --direct-uninstall-guarded

Examples:
  install.sh --detect-only
  install.sh --direct-plan
  install.sh --direct-apply --yes
  install.sh --direct-check
  install.sh --direct-init-check
  install.sh --direct-setup-plan
  install.sh --direct-uninstall-plan
  install.sh --direct-experimental --post-check
  install.sh --direct-experimental --install-binary
  install.sh --direct-experimental --install-helpers
  install.sh --direct-init-experimental --stage-watchdog-init
  install.sh --direct-init-experimental --install-watchdog-init -y
  install.sh --direct-init-experimental --enable-recovery-cron --schedule '7 * * * *' -y
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

cache_bust_url() {
    url="$1"
    cb="$(date +%s 2>/dev/null || echo $$)"
    case "$url" in
        *\?*) printf '%s&cb=%s\n' "$url" "$cb" ;;
        *) printf '%s?cb=%s\n' "$url" "$cb" ;;
    esac
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
        echo "Mode: direct-install low-level"
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
        echo "Mode: direct-init low-level"
        run_downloaded_script "$DIRECT_INIT_URL" "$DIRECT_INIT_TMP_FILE" "direct-init helper" "$@"
        ;;
    --direct-init-check|--direct-init-post-check)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-init post-check"
        run_downloaded_script "$DIRECT_INIT_URL" "$DIRECT_INIT_TMP_FILE" "direct-init helper" --post-check "$@"
        ;;
    --direct-plan|--direct-full-dry-run)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct full plan"
        run_downloaded_script "$DIRECT_FULL_URL" "$DIRECT_FULL_TMP_FILE" "direct full orchestrator" --dry-run "$@"
        ;;
    --direct-apply|--direct-full-experimental)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct full apply"
        run_downloaded_script "$DIRECT_FULL_URL" "$DIRECT_FULL_TMP_FILE" "direct full orchestrator" --apply "$@"
        ;;
    --direct-check)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct-install post-check"
        run_downloaded_script "$DIRECT_INSTALL_URL" "$DIRECT_TMP_FILE" "direct-install skeleton" --post-check "$@"
        ;;
    --direct-setup-plan)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct setup plan"
        run_downloaded_script "$(cache_bust_url "$DIRECT_SETUP_URL")" "$DIRECT_SETUP_TMP_FILE" "direct setup planner" "$@"
        ;;
    --direct-uninstall-plan|--direct-uninstall-dry-run)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct uninstall plan"
        run_downloaded_script "$DIRECT_UNINSTALL_URL" "$DIRECT_UNINSTALL_TMP_FILE" "direct uninstall planner" --dry-run "$@"
        ;;
    --direct-uninstall-guarded|--direct-uninstall-experimental)
        shift
        echo "Keenetic Xray Go installer"
        echo "Entrypoint: install.sh"
        echo "Mode: direct uninstall guarded apply scaffold"
        run_downloaded_script "$DIRECT_UNINSTALL_URL" "$DIRECT_UNINSTALL_TMP_FILE" "direct uninstall planner" --apply "$@"
        ;;
esac

echo "Keenetic Xray Go installer"
echo "Entrypoint: install.sh"
echo "Downloading Auto Latest selector: $AUTO_LATEST_URL"
run_downloaded_script "$AUTO_LATEST_URL" "$TMP_FILE" "Auto Latest selector" "$@"
