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

# xray-go-direct-uninstall - direct-install uninstall/cleanup planner.
#
# Default mode is dry-run and read-only. Guarded apply scaffold requires
# --apply --yes but still does not remove anything in this build. This keeps the
# command surface stable while we validate safety boundaries before real removal.

XRAY_GO_DIRECT_UNINSTALL_VERSION="${XRAY_GO_DIRECT_UNINSTALL_VERSION:-0.1.0-direct-uninstall-guarded}"
XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
MANIFEST_FILE="${XRAY_GO_MANIFEST:-${XRAY_DIR}/xray-go.manifest}"
DIRECT_INSTALL_PLAN="${DIRECT_INSTALL_PLAN:-${XRAY_DIR}/xray-go.direct-install.plan}"
DIRECT_INIT_PLAN="${DIRECT_INIT_PLAN:-${XRAY_DIR}/xray-go.direct-init.plan}"
STAGE_DIR="${XRAY_GO_DIRECT_STAGE_DIR:-/opt/tmp/xray-go-direct-install}"
HELPER_INDEX="${HELPER_INDEX:-${STAGE_DIR}/xray-go.helpers.index}"
WATCHDOG_INIT="${WATCHDOG_INIT:-/opt/etc/init.d/S26vless-go-watchdog}"
WATCHDOG_CONFIG="${WATCHDOG_CONFIG:-${XRAY_DIR}/vless-go-watchdog.conf}"
CRON_FILE="${CRON_FILE:-/opt/var/spool/cron/crontabs/root}"
RECOVERY_CRON_MARKER="${RECOVERY_CRON_MARKER:-vless-go-hourly-recover}"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
GO_RESOLVER_BACKUP="${GO_RESOLVER_BACKUP:-${GO_RESOLVER}.bak.direct}"

MODE="dry-run"
ASSUME_YES="0"
SHOW_EXISTING_ONLY="0"

usage() {
    cat <<'USAGE'
xray-go-direct-uninstall - direct-install uninstall planner

Usage:
  xray-go-direct-uninstall --dry-run [options]
  xray-go-direct-uninstall --apply --yes

Options:
  --dry-run              Print uninstall/cleanup plan; make no changes (default)
  --apply                Guarded apply scaffold; requires --yes; no removal yet
  -y, --yes              Required for --apply
  --existing-only        Print only entries that currently exist
  -h, --help             Show help

Safety:
  This build is read-only even in --apply mode. It does not stop services, delete
  files, edit cron, or modify VLESS sources/configs. Future real removal must keep
  --dry-run as default and require explicit --apply --yes.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run|--plan|dry-run|plan) MODE="dry-run"; shift ;;
        --apply|apply) MODE="apply"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        --existing-only) SHOW_EXISTING_ONLY="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

manifest_get_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

entry_exists() {
    path="$1"
    [ -e "$path" ] || [ -L "$path" ]
}

print_entry() {
    action="$1"
    path="$2"
    note="$3"

    exists="missing"
    if entry_exists "$path"; then
        exists="exists"
    fi

    [ "$SHOW_EXISTING_ONLY" = "1" ] && [ "$exists" != "exists" ] && return 0
    printf '%-9s %-7s %s' "$action" "[$exists]" "$path"
    [ -n "$note" ] && printf '  # %s' "$note"
    printf '\n'
}

print_header() {
    echo
    echo "== $1 =="
}

helper_targets() {
    cat <<'EOF_HELPERS'
/opt/bin/xray-go|main wrapper
/opt/bin/xray-go-manifest|manifest helper
/opt/bin/xray-go-direct-full|direct full orchestrator
/opt/bin/xray-go-direct-uninstall|direct uninstall helper
/opt/bin/vless-go-update|update helper
/opt/bin/vless-go-auto-update|auto-update helper
/opt/bin/vless-go-failover|failover helper
/opt/bin/vless-go-history|history helper
/opt/bin/vless-go-cleanup|cleanup helper
/opt/bin/vless-go-recover|recovery helper
/opt/bin/vless-go-socks-auth|SOCKS auth helper
/opt/bin/failover-go|menu helper
/opt/bin/vless-go-xray-core-update|Xray-core updater helper
/opt/bin/vless-go-doctor|doctor helper
/opt/bin/vless-go-watchdog|watchdog helper
/opt/libexec/vless-go-lock.sh|lock helper
EOF_HELPERS
}

state_preserve_targets() {
    cat <<'EOF_STATE'
/opt/etc/xray/current_vless|current source pointer/profile
/opt/etc/xray/primary_vless|primary source
/opt/etc/xray/backup_vless|backup source
/opt/etc/xray/vless-primary.selector|primary selector
/opt/etc/xray/vless-backup.selector|backup selector
/opt/etc/xray/config.json|active Xray config
/opt/etc/xray/vless-go-socks-auth.conf|SOCKS auth config
/opt/var/log/vless-go-switch-history.log|switch history
/opt/var/log/vless-go-watchdog.log|watchdog log
/opt/var/log/vless-go-recover.log|recovery log
EOF_STATE
}

print_cron_plan() {
    if [ -s "$CRON_FILE" ]; then
        if grep -q -- "$RECOVERY_CRON_MARKER" "$CRON_FILE" 2>/dev/null; then
            echo "would remove cron lines with marker: $RECOVERY_CRON_MARKER"
            grep -- "$RECOVERY_CRON_MARKER" "$CRON_FILE" 2>/dev/null | sed 's/^/  /'
        else
            echo "no recovery cron marker found: $RECOVERY_CRON_MARKER"
        fi
    else
        echo "cron file missing or empty: $CRON_FILE"
    fi
}

print_manifest_summary() {
    if [ -s "$MANIFEST_FILE" ]; then
        echo "Manifest: $MANIFEST_FILE"
        echo "Install mode: $(manifest_get_value INSTALL_MODE)"
        echo "Edition: $(manifest_get_value EDITION)"
        echo "Version: $(manifest_get_value VERSION)"
        echo "Architecture: $(manifest_get_value ARCH)"
        echo "Binary: $(manifest_get_value BINARY_PATH)"
        echo "Binary sha256: $(manifest_get_value BINARY_SHA256)"
        target_sha="$(sha256_file "${GO_RESOLVER}")"
        if [ -n "$target_sha" ]; then
            echo "Current binary sha256: $target_sha"
        fi
    else
        echo "Manifest not found: $MANIFEST_FILE"
    fi
}

require_apply_confirmation() {
    if [ "$MODE" = "apply" ] && [ "$ASSUME_YES" != "1" ]; then
        echo "ERROR: --apply requires --yes." >&2
        echo "Run dry-run first: xray-go uninstall --dry-run" >&2
        exit 2
    fi
}

print_apply_scaffold() {
    print_header "Guarded apply scaffold"
    require_apply_confirmation
    install_mode="$(manifest_get_value INSTALL_MODE)"
    if [ "$install_mode" != "direct" ]; then
        echo "ERROR: refusing apply because manifest INSTALL_MODE is not direct." >&2
        echo "Current INSTALL_MODE: ${install_mode:-unknown}" >&2
        exit 2
    fi
    echo "Confirmation accepted: --apply --yes"
    echo "No changes made in this build. Real removal is intentionally disabled."
    echo "Validated safety boundary: dry-run remains default; user/runtime data would be preserved."
}

cat <<EOF_INTRO
Keenetic Xray Go direct uninstall planner
Mode: $MODE
Version: $XRAY_GO_DIRECT_UNINSTALL_VERSION
Manifest file: $MANIFEST_FILE
Direct install plan: $DIRECT_INSTALL_PLAN
Direct init plan: $DIRECT_INIT_PLAN
Stage dir: $STAGE_DIR
Cron marker: $RECOVERY_CRON_MARKER
EOF_INTRO

print_header "Manifest"
print_manifest_summary

print_header "Would remove direct code files"
print_entry remove "$GO_RESOLVER" "Go resolver binary"
print_entry remove "$GO_RESOLVER_BACKUP" "direct backup of previous Go resolver"
helper_targets | while IFS='|' read -r path note; do
    [ -n "$path" ] || continue
    print_entry remove "$path" "$note"
done

print_header "Would remove service/automation hooks"
print_entry remove "$WATCHDOG_INIT" "watchdog init.d service"
print_cron_plan

print_header "Would remove direct metadata/staging"
print_entry remove "$MANIFEST_FILE" "direct manifest"
print_entry remove "$DIRECT_INSTALL_PLAN" "direct-install plan"
print_entry remove "$DIRECT_INIT_PLAN" "direct-init plan"
print_entry remove "$HELPER_INDEX" "staged helper index"
print_entry remove "$STAGE_DIR" "direct-install staging directory"

print_header "Would preserve user/runtime data by default"
print_entry preserve "$WATCHDOG_CONFIG" "watchdog config; future --purge may remove it"
state_preserve_targets | while IFS='|' read -r path note; do
    [ -n "$path" ] || continue
    print_entry preserve "$path" "$note"
done

print_header "Safety boundary"
if [ "$MODE" = "apply" ]; then
    print_apply_scaffold
else
    echo "No changes made."
    echo "This dry-run does not stop services, delete files, edit cron, or modify VLESS sources."
    echo "Guarded apply scaffold requires: --apply --yes"
fi
