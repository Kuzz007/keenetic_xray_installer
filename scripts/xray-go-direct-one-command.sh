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

# xray-go-direct-one-command - test entrypoint for one-command direct install.
#
# This orchestrates the already separated layers from a single command:
#   1. direct full-lite code/helper/init apply
#   2. interactive setup wizard only when state/source files are missing
#   3. initial Xray binary install when missing
#   4. disable/remove SOCKS auth leftovers
#   5. active config generation and service restart when possible
#   6. staging cleanup and size/policy summary
#
# Xray-core update remains manual-only. Initial install runs only when Xray is
# missing and does not install vless-go-xray-core-update.
# SOCKS auth is optional only and is removed from the default one-command flow.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
DIRECT_FULL_URL="${DIRECT_FULL_URL:-${REPO_BASE}/scripts/xray-go-direct-full.sh}"
XRAY_INITIAL_URL="${XRAY_INITIAL_URL:-${REPO_BASE}/scripts/xray-go-xray-initial-install.sh}"
SETUP_WIZARD_CMD="${SETUP_WIZARD_CMD:-/opt/bin/xray-go-setup}"
SIZE_CHECK_CMD="${SIZE_CHECK_CMD:-/opt/bin/xray-go-size-check}"
FAILOVER_CMD="${FAILOVER_CMD:-/opt/bin/vless-go-failover}"
XRAY_CORE_UPDATE_CMD="${XRAY_CORE_UPDATE_CMD:-/opt/bin/vless-go-xray-core-update}"
SOCKS_AUTH_CMD="${SOCKS_AUTH_CMD:-/opt/bin/vless-go-socks-auth}"
XRAY_BIN="${XRAY_BIN:-/opt/sbin/xray}"
XRAY_INIT="${XRAY_INIT:-/opt/etc/init.d/S24xray}"
WATCHDOG_INIT="${WATCHDOG_INIT:-/opt/etc/init.d/S26vless-go-watchdog}"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
TMP_DIR="${TMPDIR:-/opt/tmp}"

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_SELECTOR="$XRAY_DIR/vless-go.primary.selector"
BACKUP_SELECTOR="$XRAY_DIR/vless-go.backup.selector"
MANIFEST_FILE="$XRAY_DIR/xray-go.manifest"
CONFIG_FILE="$XRAY_DIR/config.json"
SOCKS_AUTH_CONF="$XRAY_DIR/vless-go-socks-auth.conf"

MODE="apply"
ASSUME_YES="0"
RUN_SETUP="auto"
CLEAN_STAGE="1"

usage() {
    cat <<'USAGE'
xray-go direct one-command test installer

Usage:
  install.sh --direct-one-command --yes
  install.sh --direct-one-command --yes --skip-setup

What it does:
  1. installs/updates direct full-lite code/helper/init layer
  2. runs interactive setup wizard only if source/state files are missing
  3. installs Xray binary only if missing
  4. removes default SOCKS auth leftovers
  5. generates active config and restarts Xray/watchdog when possible
  6. removes direct staging and prints size/policy summary

Safety:
  Requires --yes because it changes the direct helper/init layer.
  Setup wizard still protects existing source/state files from overwrite.
  Raw VLESS/subscription values are not printed after input.
  Xray-core update helper is manual-only and must not remain installed.
  SOCKS auth is plain/no-auth by default; add auth later explicitly if needed.
  Use --keep-stage only for debugging.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply|apply) MODE="apply"; shift ;;
        --yes|-y) ASSUME_YES="1"; shift ;;
        --skip-setup|--no-setup) RUN_SETUP="skip"; shift ;;
        --force-setup) RUN_SETUP="force"; shift ;;
        --keep-stage|--no-clean-stage) CLEAN_STAGE="0"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$MODE" != "apply" ]; then
    echo "ERROR: unsupported mode: $MODE" >&2
    exit 2
fi

if [ "$ASSUME_YES" != "1" ]; then
    echo "ERROR: --direct-one-command requires --yes" >&2
    exit 2
fi

cache_bust_url() {
    url="$1"
    cb="$(date +%s 2>/dev/null || echo $$)"
    case "$url" in
        *\?*) printf '%s&cb=%s\n' "$url" "$cb" ;;
        *) printf '%s?cb=%s\n' "$url" "$cb" ;;
    esac
}

run_remote_helper() {
    label="$1"
    url="$2"
    shift 2

    mkdir -p "$TMP_DIR"
    tmp="${TMP_DIR}/xray-go-one-command-$(echo "$label" | tr ' /' '__').$$.sh"
    effective_url="$(cache_bust_url "$url")"
    echo
    echo "== $label =="
    echo "Downloading: $effective_url"
    fetch_url "$effective_url" "$tmp"
    looks_like_shell_script "$tmp" || { echo "ERROR: downloaded $label is not a shell script" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    sh -n "$tmp" || { echo "ERROR: downloaded $label failed sh -n" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    chmod +x "$tmp"
    sh "$tmp" "$@"
    rc="$?"
    rm -f "$tmp" 2>/dev/null || true
    return "$rc"
}

state_ready() {
    [ -s "$SOURCE_STORE" ] && \
    [ -s "$PRIMARY_STORE" ] && \
    [ -s "$BACKUP_STORE" ] && \
    [ -s "$ACTIVE_STORE" ] && \
    [ -s "$PRIMARY_SELECTOR" ] && \
    [ -s "$BACKUP_SELECTOR" ]
}

print_state_summary() {
    echo
    echo "== State summary =="
    for f in \
        "$PRIMARY_STORE" \
        "$BACKUP_STORE" \
        "$ACTIVE_STORE" \
        "$PRIMARY_SELECTOR" \
        "$BACKUP_SELECTOR" \
        "$SOURCE_STORE"
    do
        if [ -s "$f" ]; then
            echo "[OK] $f ($(wc -c < "$f" 2>/dev/null | tr -d ' ') bytes)"
        else
            echo "[WARN] missing $f"
        fi
    done
}

run_setup_if_needed() {
    case "$RUN_SETUP" in
        skip)
            echo
            echo "== setup wizard =="
            echo "Skipped by --skip-setup."
            return 0
            ;;
        auto)
            if state_ready; then
                echo
                echo "== setup wizard =="
                echo "State/source files already exist; skipping interactive setup."
                print_state_summary
                return 0
            fi
            ;;
        force) ;;
    esac

    echo
    echo "== setup wizard =="
    [ -x "$SETUP_WIZARD_CMD" ] || { echo "ERROR: setup wizard missing after direct full apply: $SETUP_WIZARD_CMD" >&2; exit 1; }
    echo "Running interactive setup wizard. It will not print raw source values after input."
    REPO_BRANCH="$REPO_BRANCH" "$SETUP_WIZARD_CMD" --apply --yes
    print_state_summary
}

install_xray_if_needed() {
    echo
    echo "== initial Xray install =="
    if [ -x "$XRAY_BIN" ] || command -v xray >/dev/null 2>&1 || [ -x /opt/bin/xray ]; then
        echo "Xray binary already exists; initial install helper will run as no-op/compatibility check."
    fi
    run_remote_helper "initial Xray install" "$XRAY_INITIAL_URL" --apply --yes
}

remove_socks_auth_defaults() {
    echo
    echo "== SOCKS auth default policy =="
    if [ -e "$SOCKS_AUTH_CONF" ]; then
        rm -f "$SOCKS_AUTH_CONF"
        echo "[OK] removed SOCKS auth config: $SOCKS_AUTH_CONF"
    else
        echo "[OK] SOCKS auth config absent"
    fi
    if [ -e "$SOCKS_AUTH_CMD" ] || [ -L "$SOCKS_AUTH_CMD" ]; then
        rm -f "$SOCKS_AUTH_CMD"
        echo "[OK] removed optional SOCKS auth helper: $SOCKS_AUTH_CMD"
    else
        echo "[OK] SOCKS auth helper absent"
    fi
}

generate_active_config_if_possible() {
    echo
    echo "== generate active Xray config =="
    if ! state_ready; then
        echo "[WARN] state/source files incomplete; skipping config generation."
        return 0
    fi
    if [ ! -x "$FAILOVER_CMD" ]; then
        echo "[WARN] failover helper missing; skipping config generation: $FAILOVER_CMD"
        return 0
    fi
    if ! command -v xray >/dev/null 2>&1 && [ ! -x "$XRAY_BIN" ] && [ ! -x /opt/bin/xray ]; then
        echo "[WARN] Xray binary missing; skipping config generation."
        return 0
    fi

    "$FAILOVER_CMD" update-active --no-restart

    if [ -x "$XRAY_INIT" ] && [ -s "$CONFIG_FILE" ]; then
        echo "Restarting Xray after config generation..."
        "$XRAY_INIT" restart || "$XRAY_INIT" start || true
    fi

    if [ -x "$WATCHDOG_INIT" ]; then
        echo "Restarting watchdog after Xray/config update..."
        "$WATCHDOG_INIT" restart || true
    fi
}

cleanup_success_staging() {
    echo
    echo "== cleanup staging =="
    if [ "$CLEAN_STAGE" != "1" ]; then
        echo "Keeping staging by request (--keep-stage)."
        return 0
    fi
    for d in \
        /opt/tmp/xray-go-direct-install \
        /opt/tmp/xray-go-helper-profile \
        /tmp/xray-go-direct-install \
        /tmp/xray-go-helper-profile
    do
        if [ -e "$d" ]; then
            rm -rf "$d"
            echo "[OK] removed: $d"
        fi
    done
}

print_final_summary() {
    echo
    echo "== Final one-command summary =="
    [ -x "$GO_RESOLVER" ] && echo "[OK] Go resolver: $GO_RESOLVER" || echo "[FAIL] Go resolver missing: $GO_RESOLVER"
    [ -s "$MANIFEST_FILE" ] && echo "[OK] manifest: $MANIFEST_FILE" || echo "[FAIL] manifest missing: $MANIFEST_FILE"
    [ -s "$CONFIG_FILE" ] && echo "[OK] Xray config: $CONFIG_FILE" || echo "[WARN] Xray config missing: $CONFIG_FILE"

    if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
        echo "[FAIL] manual-only Xray-core updater is installed unexpectedly: $XRAY_CORE_UPDATE_CMD"
    else
        echo "[OK] manual-only Xray-core updater absent"
    fi

    if [ -e "$SOCKS_AUTH_CONF" ] || [ -x "$SOCKS_AUTH_CMD" ]; then
        echo "[FAIL] SOCKS auth leftover detected"
    else
        echo "[OK] SOCKS auth disabled/absent"
    fi

    if [ -x "$XRAY_BIN" ]; then
        echo "[OK] Xray binary: $XRAY_BIN"
        "$XRAY_BIN" version 2>/dev/null | sed -n '1,2p' || true
    elif command -v xray >/dev/null 2>&1; then
        found="$(command -v xray)"
        echo "[OK] Xray binary: $found"
        "$found" version 2>/dev/null | sed -n '1,2p' || true
    else
        echo "[WARN] Xray binary missing: $XRAY_BIN"
    fi

    if [ -x "$SIZE_CHECK_CMD" ]; then
        echo
        "$SIZE_CHECK_CMD"
    else
        echo "[WARN] size-check helper missing: $SIZE_CHECK_CMD"
    fi
}

cat <<EOF_INTRO
== Xray Go one-command direct install test ==
Repository branch: $REPO_BRANCH
Direct full-lite helper: $DIRECT_FULL_URL
Initial Xray helper: $XRAY_INITIAL_URL
EOF_INTRO

run_remote_helper "direct full-lite apply" "$DIRECT_FULL_URL" --apply --yes
run_setup_if_needed
install_xray_if_needed
remove_socks_auth_defaults
generate_active_config_if_possible
cleanup_success_staging
print_final_summary

echo
echo "One-command direct install test complete."
