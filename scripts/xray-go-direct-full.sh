#!/bin/sh
set -e

# xray-go-direct-full - experimental full direct-install orchestrator.
#
# Default mode is read-only dry-run. Apply mode is explicit and requires --yes.
# The orchestrator runs already validated direct-install/direct-init helpers in a
# safe order. It does not run first setup and does not edit VLESS sources.

XRAY_GO_DIRECT_FULL_VERSION="${XRAY_GO_DIRECT_FULL_VERSION:-0.1.0-direct-full}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
DIRECT_INSTALL_URL="${DIRECT_INSTALL_URL:-${REPO_BASE}/scripts/xray-go-direct-install.sh}"
DIRECT_INIT_URL="${DIRECT_INIT_URL:-${REPO_BASE}/scripts/xray-go-direct-init.sh}"

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
TMP_DIR="${TMPDIR:-/opt/tmp}"

MODE="dry-run"
SHOW_COMMANDS="1"
ASSUME_YES="0"

usage() {
    cat <<'USAGE'
xray-go-direct-full - experimental full direct-install orchestrator

Usage:
  xray-go-direct-full --dry-run
  xray-go-direct-full --apply --yes

Modes:
  --dry-run              Print full v2 direct-install plan; make no changes
  --apply                Run the verified direct full sequence; requires --yes

Options:
  --schedule '7 * * * *' Recovery cron schedule
  --no-commands          Hide exact curl/install.sh command examples
  -y, --yes              Required for --apply
  -h, --help             Show help

Notes:
  Apply mode installs/updates direct binary, helpers, manifest, watchdog init and
  recovery cron using the smaller direct helpers. It does not run first setup,
  does not edit VLESS sources and does not restart services by itself.
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
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*|mipsel-3.4|mipsel-3.4_kn|mipselsf-k3.4|mipselsf-k3.4_kn) echo "xray-failover-go-linux-mipsle" ;;
        *) echo "" ;;
    esac
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

    echo "ERROR: curl or wget is required." >&2
    return 127
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

run_remote_helper() {
    label="$1"
    url="$2"
    shift 2

    mkdir -p "$TMP_DIR"
    tmp="${TMP_DIR}/xray-go-direct-full-$(echo "$label" | tr ' /' '__').$$.sh"
    echo
    echo "== $label =="
    echo "Downloading: $url"
    fetch_url "$url" "$tmp"
    looks_like_shell_script "$tmp" || { echo "ERROR: downloaded $label is not a shell script" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    sh -n "$tmp" || { echo "ERROR: downloaded $label failed sh -n" >&2; rm -f "$tmp" 2>/dev/null || true; exit 1; }
    chmod +x "$tmp"
    sh "$tmp" "$@"
    rm -f "$tmp" 2>/dev/null || true
}

ENTWARE_ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ENTWARE_ARCH" ] || ENTWARE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
GO_ASSET_NAME="${GO_ASSET_NAME:-$(asset_name_for_arch "$ENTWARE_ARCH")}"
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

echo
echo "== Planned full direct-install sequence =="
cat <<'EOF_STEPS'
1. direct-install detect-only
2. install Go resolver binary from GitHub release asset with sha256 verification
3. install shell helpers after staging + sh -n verification
4. write direct manifest
5. run direct post-check
6. stage/install watchdog init/service layer
7. enable hourly recovery cron by marker
8. run direct-init post-check
9. print final xray-go commands for user validation
EOF_STEPS

if [ "$SHOW_COMMANDS" = "1" ]; then
    echo
    echo "== Equivalent commands =="
    cat <<EOF_CMDS
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-detect-only
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --install-binary
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --install-helpers
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --write-manifest -y
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --post-check
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --install-watchdog-init -y
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --enable-recovery-cron --schedule '$RECOVERY_CRON_SCHEDULE' -y
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
echo "== Applying full direct-install sequence =="
run_remote_helper "direct detect-only" "$DIRECT_INSTALL_URL" --detect-only
run_remote_helper "direct install binary" "$DIRECT_INSTALL_URL" --install-binary
run_remote_helper "direct install helpers" "$DIRECT_INSTALL_URL" --install-helpers
run_remote_helper "direct write manifest" "$DIRECT_INSTALL_URL" --write-manifest -y
run_remote_helper "direct post-check" "$DIRECT_INSTALL_URL" --post-check
run_remote_helper "direct init install watchdog" "$DIRECT_INIT_URL" --install-watchdog-init -y
run_remote_helper "direct init enable recovery cron" "$DIRECT_INIT_URL" --enable-recovery-cron --schedule "$RECOVERY_CRON_SCHEDULE" -y
run_remote_helper "direct init post-check" "$DIRECT_INIT_URL" --post-check

echo
echo "Direct full apply complete."
echo "No first-run setup was executed. VLESS sources were not edited."
echo "Final validation commands:"
echo "  xray-go manifest"
echo "  xray-go recover status"
echo "  xray-go doctor --support"
