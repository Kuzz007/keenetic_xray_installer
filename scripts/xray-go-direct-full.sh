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

# xray-go-direct-full - full-lite direct-install orchestrator.
#
# Default mode is read-only dry-run. Apply mode is explicit and requires --yes.
# The orchestrator installs/updates the Go resolver, installs profile-aware
# full-lite helpers, writes a direct manifest, and manages watchdog/recovery init.
# It does not run first setup and does not edit VLESS sources.
#
# Policy:
#   full-lite must not install vless-go-xray-core-update. Xray-core update remains
#   manual-only and explicit.
#   full-lite must not install SOCKS auth by default. Local SOCKS is plain unless
#   auth is added later explicitly.

XRAY_GO_DIRECT_FULL_VERSION="${XRAY_GO_DIRECT_FULL_VERSION:-0.1.4-direct-full-guardrail-text}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
DIRECT_INSTALL_URL="${DIRECT_INSTALL_URL:-${REPO_BASE}/scripts/xray-go-direct-install.sh}"
DIRECT_INIT_URL="${DIRECT_INIT_URL:-${REPO_BASE}/scripts/xray-go-direct-init.sh}"
HELPER_PROFILE_URL="${HELPER_PROFILE_URL:-${REPO_BASE}/scripts/xray-go-direct-helper-profile.sh}"

GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
MANIFEST_FILE="${MANIFEST_FILE:-/opt/etc/xray/xray-go.manifest}"
DIRECT_PLAN_FILE="${DIRECT_PLAN_FILE:-/opt/etc/xray/xray-go.direct-install.plan}"
DIRECT_INIT_PLAN_FILE="${DIRECT_INIT_PLAN_FILE:-/opt/etc/xray/xray-go.direct-init.plan}"
WATCHDOG_INIT="${WATCHDOG_INIT:-/opt/etc/init.d/S26vless-go-watchdog}"
WATCHDOG_CONF="${WATCHDOG_CONF:-/opt/etc/xray/vless-go-watchdog.conf}"
RECOVERY_CMD="${RECOVERY_CMD:-/opt/bin/vless-go-recover}"
CRON_FILE="${CRON_FILE:-/opt/var/spool/cron/crontabs/root}"
RECOVERY_CRON_SCHEDULE="${RECOVERY_CRON_SCHEDULE:-7 * * * *}"
RECOVERY_CRON_MARKER="${RECOVERY_CRON_MARKER:-vless-go-hourly-recover}"
XRAY_CORE_UPDATE_CMD="${XRAY_CORE_UPDATE_CMD:-/opt/bin/vless-go-xray-core-update}"
SOCKS_AUTH_CMD="${SOCKS_AUTH_CMD:-/opt/bin/vless-go-socks-auth}"
SOCKS_AUTH_CONF="${SOCKS_AUTH_CONF:-/opt/etc/xray/vless-go-socks-auth.conf}"
TMP_DIR="${TMPDIR:-/opt/tmp}"

MODE="dry-run"
SHOW_COMMANDS="1"
ASSUME_YES="0"

usage() {
    cat <<'USAGE'
xray-go-direct-full - full-lite direct-install orchestrator

Usage:
  xray-go-direct-full --dry-run
  xray-go-direct-full --apply --yes

Modes:
  --dry-run              Print full-lite direct-install plan; make no changes
  --apply                Run the verified direct full-lite sequence; requires --yes

Options:
  --schedule '7 * * * *' Recovery cron schedule
  --no-commands          Hide exact curl/install.sh command examples
  -y, --yes              Required for --apply
  -h, --help             Show help

Notes:
  Apply mode installs/updates direct binary, profile-aware full-lite helpers,
  manifest, watchdog init and recovery cron. It does not run first setup and
  does not edit VLESS sources. It restarts the watchdog service after helper/init
  updates so the daemon uses the freshly installed recovery logic.

Policy:
  full-lite excludes vless-go-xray-core-update. Xray-core update is manual-only.
  full-lite excludes SOCKS auth by default. SOCKS auth is optional-only.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run|--plan|--check) MODE="dry-run"; shift ;;
        --apply|--run|--install) MODE="apply"; shift ;;
        --schedule)
            [ "$#" -ge 2 ] || { echo "ERROR: --schedule requires a value" >&2; exit 2; }
            RECOVERY_CRON_SCHEDULE="$2"
            shift 2
            ;;
        --no-commands) SHOW_COMMANDS="0"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

opkg_bin() {
    if command -v opkg >/dev/null 2>&1; then
        command -v opkg
    elif [ -x /opt/bin/opkg ]; then
        echo /opt/bin/opkg
    else
        echo ""
    fi
}

detect_entware_arch() {
    OPKG_BIN="$(opkg_bin)"
    if [ -n "$OPKG_BIN" ]; then
        "$OPKG_BIN" print-architecture 2>/dev/null | awk '$2 != "all" && ($3 + 0) >= max { arch = $2; max = $3 + 0 } END { if (arch != "") print arch }'
    fi
}

asset_name_for_arch() {
    arch="$1"
    case "$arch" in
        aarch64-3.10|aarch64*|arm64) echo "xray-failover-go-linux-arm64" ;;
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*) echo "xray-failover-go-linux-mipsle" ;;
        *) echo "" ;;
    esac
}

manifest_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

check_line() {
    label="$1"
    path="$2"
    if [ -e "$path" ]; then
        echo "[OK] $label: $path"
    else
        echo "[WARN] missing $label: $path"
    fi
}

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
    tmp="${TMP_DIR}/xray-go-direct-full-$(echo "$label" | tr ' /' '__').$$.sh"
    effective_url="$(cache_bust_url "$url")"
    echo
    echo "== $label =="
    echo "Downloading: $effective_url"
    fetch_url "$effective_url" "$tmp"
    looks_like_shell_script "$tmp" || { echo "ERROR: downloaded $label is not a shell script" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    sh -n "$tmp" || { echo "ERROR: downloaded $label failed sh -n" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    chmod +x "$tmp"
    sh "$tmp" "$@"
    rm -f "$tmp" 2>/dev/null || true
}

restart_watchdog_if_present() {
    echo
    echo "== restart watchdog daemon =="
    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" restart || {
            echo "ERROR: watchdog restart failed: $WATCHDOG_INIT" >&2
            exit 1
        }
        echo "Watchdog daemon restarted so updated helper logic is active."
    else
        echo "[WARN] watchdog init missing or not executable: $WATCHDOG_INIT"
        echo "Skipping watchdog restart."
    fi
}

current_binary_matches_manifest() {
    [ -x "$GO_RESOLVER" ] || return 1
    [ -n "$MANIFEST_SHA" ] || return 1
    [ -n "$GO_SHA256" ] || return 1
    [ "$GO_SHA256" = "$MANIFEST_SHA" ] || return 1
    return 0
}

maybe_install_binary() {
    if current_binary_matches_manifest; then
        echo
        echo "== direct install binary =="
        echo "Skipping Go resolver download: installed binary already matches manifest sha256."
        echo "  Binary: $GO_RESOLVER"
        echo "  Sha256: $GO_SHA256"
        return 0
    fi

    run_remote_helper "direct install binary" "$DIRECT_INSTALL_URL" --install-binary
}

remove_manual_only_helper_if_present() {
    echo
    echo "== full-lite manual-only policy =="
    if [ -e "$XRAY_CORE_UPDATE_CMD" ] || [ -L "$XRAY_CORE_UPDATE_CMD" ]; then
        rm -f "$XRAY_CORE_UPDATE_CMD"
        echo "Removed manual-only helper from full-lite layer: $XRAY_CORE_UPDATE_CMD"
    else
        echo "[OK] manual-only Xray-core updater is absent from full-lite layer."
    fi
}

remove_socks_auth_if_present() {
    echo
    echo "== full-lite SOCKS auth policy =="
    if [ -e "$SOCKS_AUTH_CMD" ] || [ -L "$SOCKS_AUTH_CMD" ]; then
        rm -f "$SOCKS_AUTH_CMD"
        echo "Removed optional SOCKS auth helper from full-lite layer: $SOCKS_AUTH_CMD"
    else
        echo "[OK] optional SOCKS auth helper absent from full-lite layer."
    fi
    if [ -e "$SOCKS_AUTH_CONF" ]; then
        rm -f "$SOCKS_AUTH_CONF"
        echo "Removed SOCKS auth config from default full-lite layer: $SOCKS_AUTH_CONF"
    else
        echo "[OK] SOCKS auth config absent."
    fi
}

direct_full_post_check() {
    echo
    echo "== Direct full-lite post-check =="
    fail=0

    if [ -x "$GO_RESOLVER" ]; then
        echo "[OK] Go resolver executable: $GO_RESOLVER"
    else
        echo "[FAIL] Go resolver missing: $GO_RESOLVER"
        fail=$((fail + 1))
    fi

    if [ -s "$MANIFEST_FILE" ]; then
        echo "[OK] manifest present: $MANIFEST_FILE"
        mode="$(manifest_value INSTALL_MODE)"
        [ "$mode" = "direct" ] && echo "[OK] manifest install mode: direct" || echo "[WARN] manifest install mode: ${mode:-unknown}"
    else
        echo "[FAIL] manifest missing: $MANIFEST_FILE"
        fail=$((fail + 1))
    fi

    for helper in \
        /opt/bin/xray-go \
        /opt/bin/vless-go-update \
        /opt/bin/vless-go-failover \
        /opt/bin/failover-go \
        /opt/bin/xray-go-size-check \
        /opt/bin/xray-go-space-gate \
        /opt/bin/xray-go-setup \
        /opt/bin/vless-go-watchdog \
        /opt/bin/vless-go-recover \
        /opt/bin/vless-go-doctor \
        /opt/bin/vless-go-doctor-summary \
        /opt/bin/vless-go-privacy-check \
        /opt/bin/xray-go-safety-check
    do
        [ -x "$helper" ] && echo "[OK] helper executable: $helper" || echo "[WARN] helper missing: $helper"
    done

    if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
        echo "[FAIL] manual-only helper must not be installed by full-lite: $XRAY_CORE_UPDATE_CMD"
        fail=$((fail + 1))
    else
        echo "[OK] manual-only Xray-core updater absent from full-lite layer"
    fi

    if [ -e "$SOCKS_AUTH_CMD" ] || [ -e "$SOCKS_AUTH_CONF" ]; then
        echo "[FAIL] SOCKS auth must be absent from default full-lite layer"
        fail=$((fail + 1))
    else
        echo "[OK] SOCKS auth absent from default full-lite layer"
    fi

    [ "$fail" -eq 0 ] || exit 1
}

ENTWARE_ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ENTWARE_ARCH" ] || ENTWARE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
GO_ASSET_NAME="${GO_ASSET_NAME:-$(asset_name_for_arch "$ENTWARE_ARCH") }"
GO_ASSET_NAME="$(printf '%s' "$GO_ASSET_NAME" | sed 's/[[:space:]]*$//')"
GO_SHA256="$(sha256_file "$GO_RESOLVER")"
MANIFEST_MODE="$(manifest_value INSTALL_MODE)"
MANIFEST_SHA="$(manifest_value BINARY_SHA256)"
MANIFEST_MODULES="$(manifest_value MODULES)"

cat <<EOF_PLAN
Keenetic Xray Go direct full orchestrator
Mode: $MODE
Version: $XRAY_GO_DIRECT_FULL_VERSION
Repository branch: $REPO_BRANCH
Entware architecture: $ENTWARE_ARCH
Go asset: ${GO_ASSET_NAME:-unsupported}
Direct install helper: $DIRECT_INSTALL_URL
Helper profile installer: $HELPER_PROFILE_URL
Direct init helper: $DIRECT_INIT_URL
Recovery cron schedule: $RECOVERY_CRON_SCHEDULE
EOF_PLAN

echo
echo "== Current direct state =="
check_line "Go resolver" "$GO_RESOLVER"
[ -n "$GO_SHA256" ] && echo "[OK] Go resolver sha256: $GO_SHA256" || echo "[WARN] Go resolver sha256 unavailable"
check_line "manifest" "$MANIFEST_FILE"
[ -n "$MANIFEST_MODE" ] && echo "[OK] manifest install mode: $MANIFEST_MODE" || echo "[WARN] manifest install mode unavailable"
if [ -n "$MANIFEST_SHA" ] && [ -n "$GO_SHA256" ]; then
    if [ "$MANIFEST_SHA" = "$GO_SHA256" ]; then
        echo "[OK] manifest binary sha256 matches target"
    else
        echo "[WARN] manifest binary sha256 differs from target"
        echo "      manifest: $MANIFEST_SHA"
        echo "      target:   $GO_SHA256"
    fi
fi
[ -n "$MANIFEST_MODULES" ] && echo "[OK] manifest modules: $MANIFEST_MODULES" || true
check_line "direct-install plan" "$DIRECT_PLAN_FILE"
check_line "direct-init plan" "$DIRECT_INIT_PLAN_FILE"
check_line "watchdog init" "$WATCHDOG_INIT"
check_line "watchdog config" "$WATCHDOG_CONF"
check_line "recovery helper" "$RECOVERY_CMD"
check_line "cron file" "$CRON_FILE"
if [ -f "$CRON_FILE" ] && grep -q "$RECOVERY_CRON_MARKER" "$CRON_FILE" 2>/dev/null; then
    echo "[OK] recovery cron marker present: $RECOVERY_CRON_MARKER"
else
    echo "[WARN] recovery cron marker not found: $RECOVERY_CRON_MARKER"
fi
if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
    echo "[WARN] manual-only helper currently present and will be removed from full-lite: $XRAY_CORE_UPDATE_CMD"
else
    echo "[OK] manual-only helper absent: $XRAY_CORE_UPDATE_CMD"
fi
if [ -e "$SOCKS_AUTH_CMD" ] || [ -e "$SOCKS_AUTH_CONF" ]; then
    echo "[WARN] SOCKS auth currently present and will be removed from default full-lite"
else
    echo "[OK] SOCKS auth absent from default full-lite state"
fi

echo
echo "== Planned full direct-install sequence =="
cat <<'EOF_STEPS'
1. direct-install detect-only
2. install Go resolver binary only when current binary does not match manifest sha256
3. install profile-aware full-lite helpers
4. remove stale manual-only Xray-core updater helper if present
5. remove stale SOCKS auth helper/config from default full-lite if present
6. write direct manifest
7. run profile-aware direct full-lite post-check
8. stage/install watchdog init/service layer
9. enable hourly recovery cron by marker
10. restart watchdog daemon so updated helper logic is active
11. run direct-init post-check after restart
12. print final xray-go commands for user validation
EOF_STEPS

if [ "$SHOW_COMMANDS" = "1" ]; then
    echo
    echo "== Equivalent commands =="
    cat <<EOF_CMDS
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-detect-only
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --install-binary
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-direct-helper-profile.sh | sh -s -- --profile full-lite --apply --yes
rm -f /opt/bin/vless-go-xray-core-update /opt/bin/vless-go-socks-auth /opt/etc/xray/vless-go-socks-auth.conf
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --write-manifest -y
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --install-watchdog-init -y
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --enable-recovery-cron --schedule '$RECOVERY_CRON_SCHEDULE' -y
/opt/etc/init.d/S26vless-go-watchdog restart
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-post-check
EOF_CMDS
fi

if [ "$MODE" = "dry-run" ]; then
    echo
    echo "Direct full dry-run complete. No changes made."
    exit 0
fi

if [ "$MODE" != "apply" ]; then
    echo "ERROR: unsupported mode: $MODE" >&2
    exit 2
fi

if [ "$ASSUME_YES" != "1" ]; then
    echo "ERROR: --apply requires --yes." >&2
    echo "This prevents accidental full direct changes." >&2
    exit 2
fi

[ -n "$GO_ASSET_NAME" ] || { echo "ERROR: unsupported architecture for Go resolver: $ENTWARE_ARCH" >&2; exit 1; }

echo
echo "== Applying full-lite direct-install sequence =="
run_remote_helper "direct detect-only" "$DIRECT_INSTALL_URL" --detect-only
maybe_install_binary
run_remote_helper "direct install profile-aware full-lite helpers" "$HELPER_PROFILE_URL" --profile full-lite --apply --yes
remove_manual_only_helper_if_present
remove_socks_auth_if_present
run_remote_helper "direct write manifest" "$DIRECT_INSTALL_URL" --write-manifest -y
direct_full_post_check
run_remote_helper "direct init install watchdog" "$DIRECT_INIT_URL" --install-watchdog-init -y
run_remote_helper "direct init enable recovery cron" "$DIRECT_INIT_URL" --enable-recovery-cron --schedule "$RECOVERY_CRON_SCHEDULE" -y
restart_watchdog_if_present
run_remote_helper "direct init post-check" "$DIRECT_INIT_URL" --post-check

echo
echo "Direct full-lite apply complete."
echo "No first-run setup was executed. VLESS sources were not edited."
echo "Xray-core updater helper was not installed by full-lite."
echo "SOCKS auth was not installed by default full-lite."
echo "Watchdog daemon was restarted after helper/init update."
echo "Final validation commands:"
echo "  xray-go manifest"
echo "  xray-go recover status"
echo "  xray-go doctor --support"
echo "  xray-go size-check"
