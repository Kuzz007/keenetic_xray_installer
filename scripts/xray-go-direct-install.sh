#!/bin/sh
set -e

# xray-go-direct-install - experimental direct-install v2 skeleton.
#
# This script is intentionally conservative. It can detect architecture, stage the
# Go resolver binary, install the staged binary on explicit request, stage/install
# shell helpers, install the manifest helper, write an experimental manifest and
# run read-only post-install checks. It does not run first setup and does not
# replace the stable auto_latest/IPK flow yet.

XRAY_GO_DIRECT_VERSION="${XRAY_GO_DIRECT_VERSION:-0.1.0-direct-skeleton}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
GO_RELEASE_TAG="${GO_RELEASE_TAG:-latest}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_RELEASE_TAG}}"

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
TMP_DIR="${TMPDIR:-/opt/tmp}"
STAGE_DIR="${XRAY_GO_DIRECT_STAGE_DIR:-${TMP_DIR}/xray-go-direct-install}"
HELPER_STAGE_DIR="${HELPER_STAGE_DIR:-${STAGE_DIR}/helpers}"
HELPER_INDEX="${HELPER_INDEX:-${STAGE_DIR}/xray-go.helpers.index}"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
GO_RESOLVER_BACKUP="${GO_RESOLVER_BACKUP:-${GO_RESOLVER}.bak.direct}"
MANIFEST_CMD="${MANIFEST_CMD:-/opt/bin/xray-go-manifest}"
MANIFEST_URL="${MANIFEST_URL:-${RAW_BASE}/scripts/xray-go-manifest.sh}"
MANIFEST_FILE="${MANIFEST_FILE:-${XRAY_DIR}/xray-go.manifest}"
PLAN_FILE="${PLAN_FILE:-${XRAY_DIR}/xray-go.direct-install.plan}"

XRAY_GO_CMD="${XRAY_GO_CMD:-/opt/bin/xray-go}"
XRAY_GO_URL="${XRAY_GO_URL:-${RAW_BASE}/scripts/xray-go.sh}"
GO_UPDATE_CMD="${GO_UPDATE_CMD:-/opt/bin/vless-go-update}"
GO_UPDATE_URL="${GO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-update.sh}"
GO_AUTO_UPDATE_CMD="${GO_AUTO_UPDATE_CMD:-/opt/bin/vless-go-auto-update}"
GO_AUTO_UPDATE_URL="${GO_AUTO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-auto-update.sh}"
GO_FAILOVER_CMD="${GO_FAILOVER_CMD:-/opt/bin/vless-go-failover}"
GO_FAILOVER_URL="${GO_FAILOVER_URL:-${RAW_BASE}/scripts/vless-go-failover.sh}"
GO_HISTORY_CMD="${GO_HISTORY_CMD:-/opt/bin/vless-go-history}"
GO_HISTORY_URL="${GO_HISTORY_URL:-${RAW_BASE}/scripts/vless-go-history.sh}"
GO_CLEANUP_CMD="${GO_CLEANUP_CMD:-/opt/bin/vless-go-cleanup}"
GO_CLEANUP_URL="${GO_CLEANUP_URL:-${RAW_BASE}/scripts/vless-go-cleanup.sh}"
GO_RECOVER_CMD="${GO_RECOVER_CMD:-/opt/bin/vless-go-recover}"
GO_RECOVER_URL="${GO_RECOVER_URL:-${RAW_BASE}/scripts/vless-go-recover.sh}"
GO_SOCKS_AUTH_CMD="${GO_SOCKS_AUTH_CMD:-/opt/bin/vless-go-socks-auth}"
GO_SOCKS_AUTH_URL="${GO_SOCKS_AUTH_URL:-${RAW_BASE}/scripts/vless-go-socks-auth.sh}"
FAILOVER_GO_CMD="${FAILOVER_GO_CMD:-/opt/bin/failover-go}"
FAILOVER_GO_URL="${FAILOVER_GO_URL:-${RAW_BASE}/scripts/failover-go.sh}"
XRAY_CORE_UPDATE_CMD="${XRAY_CORE_UPDATE_CMD:-/opt/bin/vless-go-xray-core-update}"
XRAY_CORE_UPDATE_URL="${XRAY_CORE_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-xray-core-update.sh}"
DOCTOR_CMD="${DOCTOR_CMD:-/opt/bin/vless-go-doctor}"
DOCTOR_URL="${DOCTOR_URL:-${RAW_BASE}/scripts/vless-go-doctor.sh}"
LOCK_HELPER="${LOCK_HELPER:-/opt/libexec/vless-go-lock.sh}"
LOCK_HELPER_URL="${LOCK_HELPER_URL:-${RAW_BASE}/scripts/vless-go-lock.sh}"
LAN_IP_LIB="${LAN_IP_LIB:-/opt/libexec/vless-go-lan-ip.sh}"
LAN_IP_LIB_URL="${LAN_IP_LIB_URL:-${RAW_BASE}/scripts/vless-go-lan-ip.sh}"

MODE="prepare"
DOWNLOAD_BINARY="0"
INSTALL_BINARY="0"
STAGE_HELPERS="0"
INSTALL_HELPERS="0"
POST_CHECK="0"
INSTALL_MANIFEST_HELPER="1"
WRITE_MANIFEST="0"
ASSUME_YES="0"

usage() {
    cat <<'USAGE'
xray-go-direct-install - experimental direct-install v2 skeleton

Usage:
  xray-go-direct-install [options]

Modes:
  --detect-only          Only print detection/plan; make no changes
  --prepare-only         Stage v2 direct-install metadata and plan (default)
  --post-check           Read-only check of direct-install files and runtime status
  --write-manifest       Also write /opt/etc/xray/xray-go.manifest as direct

Options:
  --download-binary      Download and verify the Go resolver into staging dir
  --install-binary       Download, verify and install Go resolver into target path
  --stage-helpers        Download and syntax-check shell helpers into staging dir
  --install-helpers      Stage shell helpers and install them into /opt/bin,/opt/libexec
  --no-helper            Do not install /opt/bin/xray-go-manifest
  -y, --yes              Do not ask for confirmation when writing manifest
  -h, --help             Show help

Environment:
  REPO_BRANCH=main
  GO_RELEASE_TAG=latest
  XRAY_GO_DIRECT_STAGE_DIR=/opt/tmp/xray-go-direct-install

Notes:
  This is not the final installer yet. It does not run first setup and does not
  replace the stable auto_latest/IPK-compatible Full Go flow.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --detect-only|--dry-run|--check) MODE="detect"; shift ;;
        --prepare-only|--prepare) MODE="prepare"; shift ;;
        --post-check|--check-installed|--verify-installed) POST_CHECK="1"; shift ;;
        --write-manifest) WRITE_MANIFEST="1"; shift ;;
        --download-binary) DOWNLOAD_BINARY="1"; shift ;;
        --install-binary) DOWNLOAD_BINARY="1"; INSTALL_BINARY="1"; shift ;;
        --stage-helpers) STAGE_HELPERS="1"; shift ;;
        --install-helpers) STAGE_HELPERS="1"; INSTALL_HELPERS="1"; shift ;;
        --no-helper|--no-manifest-helper) INSTALL_MANIFEST_HELPER="0"; shift ;;
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
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
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
        aarch64-3.10|aarch64*|arm64)
            echo "xray-failover-go-linux-arm64"
            ;;
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*)
            echo "xray-failover-go-linux-mipsle"
            ;;
        *)
            echo ""
            ;;
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

sha256_from_file() {
    file="$1"
    sed -n '1s/[[:space:]].*$//p' "$file" 2>/dev/null
}

manifest_value() {
    key="$1"
    file="${2:-$MANIFEST_FILE}"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$file" 2>/dev/null | tail -n 1
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

verify_shell_helper() {
    file="$1"
    label="$2"

    if ! sh -n "$file"; then
        echo "ERROR: $label failed shell syntax check: $file" >&2
        exit 1
    fi
}

patch_recover_helper_auth() {
    file="$1"
    tmp="${file}.auth.$$"
    awk '
        /^health_check\(\) \{/ {
            print "load_socks_auth_config() {"
            print "    XRAY_SOCKS_AUTH=\"${XRAY_SOCKS_AUTH:-0}\""
            print "    XRAY_SOCKS_USER=\"${XRAY_SOCKS_USER:-}\""
            print "    XRAY_SOCKS_PASS=\"${XRAY_SOCKS_PASS:-}\""
            print "    if [ -s \"$XRAY_DIR/vless-go-socks-auth.conf\" ]; then"
            print "        . \"$XRAY_DIR/vless-go-socks-auth.conf\""
            print "    fi"
            print "}"
            print ""
            print "socks_auth_enabled() {"
            print "    load_socks_auth_config"
            print "    [ \"${XRAY_SOCKS_AUTH:-0}\" = \"1\" ] && [ -n \"${XRAY_SOCKS_USER:-}\" ] && [ -n \"${XRAY_SOCKS_PASS:-}\" ]"
            print "}"
            print ""
            print "health_check() {"
            print "    ensure_dependencies || return 1"
            print "    for URL in $CHECK_URLS; do"
            print "        if socks_auth_enabled; then"
            print "            if curl -fsS --proxy-user \"$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS\" --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$URL\" >/dev/null 2>&1; then"
            print "                return 0"
            print "            fi"
            print "        elif curl -fsS --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$URL\" >/dev/null 2>&1; then"
            print "            return 0"
            print "        fi"
            print "    done"
            print "    return 1"
            print "}"
            skip=1
            next
        }
        skip && /^}/ { skip=0; next }
        skip { next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

patch_doctor_helper_auth() {
    file="$1"
    tmp="${file}.auth.$$"
    awk '
        /^check_socks_health\(\) \{/ {
            print "load_socks_auth_config() {"
            print "    XRAY_SOCKS_AUTH=\"${XRAY_SOCKS_AUTH:-0}\""
            print "    XRAY_SOCKS_USER=\"${XRAY_SOCKS_USER:-}\""
            print "    XRAY_SOCKS_PASS=\"${XRAY_SOCKS_PASS:-}\""
            print "    if [ -s \"$XRAY_DIR/vless-go-socks-auth.conf\" ]; then"
            print "        . \"$XRAY_DIR/vless-go-socks-auth.conf\""
            print "    fi"
            print "}"
            print ""
            print "socks_auth_enabled() {"
            print "    load_socks_auth_config"
            print "    [ \"${XRAY_SOCKS_AUTH:-0}\" = \"1\" ] && [ -n \"${XRAY_SOCKS_USER:-}\" ] && [ -n \"${XRAY_SOCKS_PASS:-}\" ]"
            print "}"
            print ""
            print "check_socks_health() {"
            print "    if ! has_cmd curl; then warn \"curl не найден; SOCKS health-check невозможен\"; return 0; fi"
            print "    if socks_auth_enabled; then"
            print "        ok \"SOCKS auth config найден; health-check использует proxy-user\""
            print "        if curl -fsS --proxy-user \"$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS\" --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$CHECK_URL\" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then"
            print "            ok \"SOCKS health-check OK через $CHECK_URL\""
            print "        else"
            print "            warn \"SOCKS health-check не прошёл через $CHECK_URL\""
            print "            sed '\''s/^/  /'\'' /tmp/vless-go-doctor.curl.$$"
            print "        fi"
            print "    elif curl -fsS --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$CHECK_URL\" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then"
            print "        ok \"SOCKS health-check OK через $CHECK_URL\""
            print "    else"
            print "        warn \"SOCKS health-check не прошёл через $CHECK_URL\""
            print "        sed '\''s/^/  /'\'' /tmp/vless-go-doctor.curl.$$"
            print "    fi"
            print "    rm -f /tmp/vless-go-doctor.curl.$$ 2>/dev/null || true"
            print "}"
            skip=1
            next
        }
        skip && /^}/ { skip=0; next }
        skip { next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

patch_staged_helper_auth() {
    file="$1"
    label="$2"
    case "$(basename "$file")" in
        vless-go-recover)
            echo "Patching $label for SOCKS auth-aware health-check"
            patch_recover_helper_auth "$file"
            ;;
        vless-go-doctor)
            echo "Patching $label for SOCKS auth-aware health-check"
            patch_doctor_helper_auth "$file"
            ;;
    esac
}

confirm_manifest_write() {
    [ "$WRITE_MANIFEST" = "1" ] || return 0
    [ "$ASSUME_YES" = "1" ] && return 0
    if [ -r /dev/tty ]; then
        printf '%s' "Write experimental direct manifest to /opt/etc/xray/xray-go.manifest? [y/N]: " >/dev/tty
        IFS= read -r reply </dev/tty
    else
        printf '%s' "Write experimental direct manifest to /opt/etc/xray/xray-go.manifest? [y/N]: " >&2
        IFS= read -r reply
    fi
    case "$reply" in y|Y|yes|YES|Да|да) return 0 ;; *) echo "Cancelled manifest write."; exit 0 ;; esac
}

ENTWARE_ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ENTWARE_ARCH" ] || ENTWARE_ARCH="$(uname -m 2>/dev/null || echo unknown)"
GO_ASSET_NAME="${GO_ASSET_NAME:-$(asset_name_for_arch "$ENTWARE_ARCH")}" 
GO_BINARY_URL="${GO_BINARY_URL:-${RELEASE_BASE}/${GO_ASSET_NAME}}"
GO_SHA256_URL="${GO_SHA256_URL:-${GO_BINARY_URL}.sha256}"
STAGED_BINARY="${STAGE_DIR}/${GO_ASSET_NAME}"
STAGED_SHA256="${STAGE_DIR}/${GO_ASSET_NAME}.sha256"
BINARY_SHA256=""
EXPECTED_SHA256=""

refresh_target_binary_sha() {
    if [ -z "$BINARY_SHA256" ] && [ -s "$GO_RESOLVER" ]; then
        BINARY_SHA256="$(sha256_file "$GO_RESOLVER")"
    fi
}

print_plan() {
    cat <<EOF_PLAN
Keenetic Xray Go direct-install v2 skeleton
Mode: $MODE
Version: $XRAY_GO_DIRECT_VERSION
Repository branch: $REPO_BRANCH
Release tag: $GO_RELEASE_TAG
Entware architecture: $ENTWARE_ARCH
Go asset: ${GO_ASSET_NAME:-unsupported}
Go binary URL: ${GO_BINARY_URL:-unsupported}
Stage dir: $STAGE_DIR
Helper stage dir: $HELPER_STAGE_DIR
Helper index: $HELPER_INDEX
Target binary path: $GO_RESOLVER
Target binary backup: $GO_RESOLVER_BACKUP
Manifest helper: $MANIFEST_CMD
Manifest helper URL: $MANIFEST_URL
Manifest file: $MANIFEST_FILE
Plan file: $PLAN_FILE
Download binary: $DOWNLOAD_BINARY
Install binary: $INSTALL_BINARY
Stage helpers: $STAGE_HELPERS
Install helpers: $INSTALL_HELPERS
Post-check: $POST_CHECK
Install manifest helper: $INSTALL_MANIFEST_HELPER
Write manifest: $WRITE_MANIFEST
EOF_PLAN
}

helper_specs() {
    cat <<EOF_HELPERS
exec|$XRAY_GO_CMD|$XRAY_GO_URL|xray-go wrapper
exec|$GO_UPDATE_CMD|$GO_UPDATE_URL|vless-go-update helper
exec|$GO_AUTO_UPDATE_CMD|$GO_AUTO_UPDATE_URL|vless-go-auto-update helper
exec|$GO_FAILOVER_CMD|$GO_FAILOVER_URL|vless-go-failover helper
exec|$GO_HISTORY_CMD|$GO_HISTORY_URL|vless-go-history helper
exec|$GO_CLEANUP_CMD|$GO_CLEANUP_URL|vless-go-cleanup helper
exec|$GO_RECOVER_CMD|$GO_RECOVER_URL|vless-go-recover helper
exec|$GO_SOCKS_AUTH_CMD|$GO_SOCKS_AUTH_URL|vless-go-socks-auth helper
exec|$FAILOVER_GO_CMD|$FAILOVER_GO_URL|failover-go menu
exec|$XRAY_CORE_UPDATE_CMD|$XRAY_CORE_UPDATE_URL|Xray-core updater helper
exec|$DOCTOR_CMD|$DOCTOR_URL|doctor helper
read|$LOCK_HELPER|$LOCK_HELPER_URL|lock helper
read|$LAN_IP_LIB|$LAN_IP_LIB_URL|shared LAN IP detection
EOF_HELPERS
}

write_plan_file() {
    refresh_target_binary_sha
    mkdir -p "$XRAY_DIR"
    tmp="${PLAN_FILE}.$$"
    {
        echo '# Keenetic Xray Go direct-install plan'
        echo '# This file is informational and contains no VLESS/subscription secrets.'
        echo "VERSION=\"$XRAY_GO_DIRECT_VERSION\""
        echo "MODE=\"$MODE\""
        echo "REPO_BRANCH=\"$REPO_BRANCH\""
        echo "GO_RELEASE_TAG=\"$GO_RELEASE_TAG\""
        echo "ENTWARE_ARCH=\"$ENTWARE_ARCH\""
        echo "GO_ASSET_NAME=\"$GO_ASSET_NAME\""
        echo "GO_BINARY_URL=\"$GO_BINARY_URL\""
        echo "GO_BINARY_SHA256=\"$BINARY_SHA256\""
        echo "EXPECTED_SHA256=\"$EXPECTED_SHA256\""
        echo "STAGE_DIR=\"$STAGE_DIR\""
        echo "HELPER_STAGE_DIR=\"$HELPER_STAGE_DIR\""
        echo "HELPER_INDEX=\"$HELPER_INDEX\""
        echo "TARGET_BINARY=\"$GO_RESOLVER\""
        echo "TARGET_BINARY_BACKUP=\"$GO_RESOLVER_BACKUP\""
        echo "MANIFEST_HELPER=\"$MANIFEST_CMD\""
        echo "MANIFEST_FILE=\"$MANIFEST_FILE\""
        echo "DOWNLOAD_BINARY=\"$DOWNLOAD_BINARY\""
        echo "INSTALL_BINARY=\"$INSTALL_BINARY\""
        echo "STAGE_HELPERS=\"$STAGE_HELPERS\""
        echo "INSTALL_HELPERS=\"$INSTALL_HELPERS\""
        echo "CREATED_AT=\"$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')\""
    } >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$PLAN_FILE"
    echo "Direct-install plan written: $PLAN_FILE"
}

install_manifest_helper() {
    [ "$INSTALL_MANIFEST_HELPER" = "1" ] || return 0
    mkdir -p /opt/bin "$STAGE_DIR"
    tmp="${STAGE_DIR}/xray-go-manifest.$$"
    echo "Installing manifest helper: $MANIFEST_CMD"
    fetch_url "$MANIFEST_URL" "$tmp"
    looks_like_shell_script "$tmp" || { echo "ERROR: downloaded manifest helper is not a shell script." >&2; exit 1; }
    verify_shell_helper "$tmp" "manifest helper"
    chmod +x "$tmp"
    mv "$tmp" "$MANIFEST_CMD"
    chmod +x "$MANIFEST_CMD"
}

download_binary_to_stage() {
    [ "$DOWNLOAD_BINARY" = "1" ] || return 0
    [ -n "$GO_ASSET_NAME" ] || { echo "ERROR: unsupported architecture for Go resolver: $ENTWARE_ARCH" >&2; exit 1; }
    mkdir -p "$STAGE_DIR"

    echo "Downloading Go resolver to staging: $STAGED_BINARY"
    fetch_url "$GO_BINARY_URL" "$STAGED_BINARY"
    chmod +x "$STAGED_BINARY"

    echo "Downloading sha256: $STAGED_SHA256"
    fetch_url "$GO_SHA256_URL" "$STAGED_SHA256"

    BINARY_SHA256="$(sha256_file "$STAGED_BINARY")"
    EXPECTED_SHA256="$(sha256_from_file "$STAGED_SHA256")"

    if [ -z "$BINARY_SHA256" ]; then
        echo "ERROR: cannot calculate sha256 for staged binary." >&2
        exit 1
    fi
    if [ -z "$EXPECTED_SHA256" ]; then
        echo "ERROR: downloaded sha256 file is empty or invalid." >&2
        exit 1
    fi
    if [ "$BINARY_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "ERROR: sha256 mismatch for staged Go resolver." >&2
        echo "Expected: $EXPECTED_SHA256" >&2
        echo "Actual:   $BINARY_SHA256" >&2
        exit 1
    fi

    echo "Staged Go resolver sha256 OK: $BINARY_SHA256"
}

install_binary_from_stage() {
    [ "$INSTALL_BINARY" = "1" ] || return 0
    [ -s "$STAGED_BINARY" ] || { echo "ERROR: staged Go resolver is missing: $STAGED_BINARY" >&2; exit 1; }
    [ -n "$BINARY_SHA256" ] || BINARY_SHA256="$(sha256_file "$STAGED_BINARY")"
    [ -n "$BINARY_SHA256" ] || { echo "ERROR: cannot calculate sha256 for staged Go resolver." >&2; exit 1; }

    mkdir -p "$(dirname "$GO_RESOLVER")"
    tmp_dest="$(dirname "$GO_RESOLVER")/.$(basename "$GO_RESOLVER").$$"
    echo "Installing Go resolver: $GO_RESOLVER"

    cp "$STAGED_BINARY" "$tmp_dest"
    chmod +x "$tmp_dest"

    if [ -s "$GO_RESOLVER" ]; then
        if [ -s "$GO_RESOLVER_BACKUP" ]; then
            echo "Existing Go resolver backup preserved: $GO_RESOLVER_BACKUP"
        else
            cp "$GO_RESOLVER" "$GO_RESOLVER_BACKUP" 2>/dev/null || true
            chmod +x "$GO_RESOLVER_BACKUP" 2>/dev/null || true
            echo "Previous Go resolver backup: $GO_RESOLVER_BACKUP"
        fi
    fi

    mv "$tmp_dest" "$GO_RESOLVER"
    chmod +x "$GO_RESOLVER"

    target_sha="$(sha256_file "$GO_RESOLVER")"
    if [ "$target_sha" != "$BINARY_SHA256" ]; then
        echo "ERROR: installed Go resolver sha256 mismatch." >&2
        echo "Expected: $BINARY_SHA256" >&2
        echo "Actual:   $target_sha" >&2
        exit 1
    fi

    echo "Go resolver installed. sha256=$BINARY_SHA256"
}

stage_shell_helpers() {
    [ "$STAGE_HELPERS" = "1" ] || return 0
    mkdir -p "$HELPER_STAGE_DIR" "$(dirname "$HELPER_INDEX")"
    tmp_index="${HELPER_INDEX}.$$"
    : >"$tmp_index"

    helper_specs | while IFS='|' read -r mode dest url label; do
        [ -n "$dest" ] || continue
        staged="${HELPER_STAGE_DIR}/$(basename "$dest")"

        echo "Staging $label: $staged"
        fetch_url "$url" "$staged"
        patch_staged_helper_auth "$staged" "$label"
        verify_shell_helper "$staged" "$label"

        case "$mode" in
            exec) chmod +x "$staged" ;;
            read) chmod 644 "$staged" ;;
            *) echo "ERROR: unsupported helper mode '$mode' for $label" >&2; exit 1 ;;
        esac

        helper_sha="$(sha256_file "$staged")"
        printf '%s|%s|%s|%s|%s\n' "$mode" "$dest" "$staged" "$helper_sha" "$label" >>"$tmp_index"
    done

    chmod 600 "$tmp_index" 2>/dev/null || true
    mv "$tmp_index" "$HELPER_INDEX"
    echo "Shell helpers staged and verified. Index: $HELPER_INDEX"
}

install_shell_helpers() {
    [ "$INSTALL_HELPERS" = "1" ] || return 0
    [ -s "$HELPER_INDEX" ] || { echo "ERROR: helper index not found: $HELPER_INDEX" >&2; exit 1; }

    while IFS='|' read -r mode dest staged helper_sha label; do
        [ -n "$dest" ] || continue
        [ -s "$staged" ] || { echo "ERROR: staged helper is missing: $staged" >&2; exit 1; }

        mkdir -p "$(dirname "$dest")"
        tmp_dest="$(dirname "$dest")/.$(basename "$dest").$$"
        echo "Installing $label: $dest"
        cp "$staged" "$tmp_dest"

        case "$mode" in
            exec) chmod +x "$tmp_dest" ;;
            read) chmod 644 "$tmp_dest" ;;
            *) echo "ERROR: unsupported helper mode '$mode' for $label" >&2; rm -f "$tmp_dest" 2>/dev/null || true; exit 1 ;;
        esac

        mv "$tmp_dest" "$dest"
    done <"$HELPER_INDEX"

    echo "Shell helpers installed."
}

manifest_modules() {
    modules="manifest,direct-experimental"
    [ "$DOWNLOAD_BINARY" = "1" ] && modules="$modules,binary-staged"
    [ "$INSTALL_BINARY" = "1" ] && modules="$modules,binary-installed"
    [ -s "$GO_RESOLVER" ] && modules="$modules,binary-present"
    [ "$STAGE_HELPERS" = "1" ] && modules="$modules,helpers-staged"
    [ "$INSTALL_HELPERS" = "1" ] && modules="$modules,helpers-installed"
    printf '%s' "$modules"
}

write_manifest() {
    [ "$WRITE_MANIFEST" = "1" ] || return 0
    [ -x "$MANIFEST_CMD" ] || { echo "ERROR: manifest helper is not installed: $MANIFEST_CMD" >&2; exit 1; }
    refresh_target_binary_sha
    confirm_manifest_write

    "$MANIFEST_CMD" init \
        --install-mode direct \
        --edition full \
        --version "$XRAY_GO_DIRECT_VERSION" \
        --arch "$ENTWARE_ARCH" \
        --channel "$REPO_BRANCH" \
        --source "${GO_BINARY_URL:-direct-experimental}" \
        --binary-path "$GO_RESOLVER" \
        --binary-sha256 "$BINARY_SHA256" \
        --modules "$(manifest_modules)"
}

post_check_ok=0
post_check_warn=0
post_check_fail=0

pc_ok() { echo "[OK] $*"; post_check_ok=$((post_check_ok + 1)); }
pc_warn() { echo "[WARN] $*"; post_check_warn=$((post_check_warn + 1)); }
pc_fail() { echo "[FAIL] $*"; post_check_fail=$((post_check_fail + 1)); }

post_check_file_exec() {
    path="$1"
    label="$2"
    if [ -x "$path" ]; then
        pc_ok "$label: $path"
    elif [ -e "$path" ]; then
        pc_fail "$label exists but is not executable/readable as expected: $path"
    else
        pc_fail "$label missing: $path"
    fi
}

run_post_check() {
    echo
    echo "== Direct-install post-check =="

    echo
    echo "-- Binary --"
    post_check_file_exec "$GO_RESOLVER" "Go resolver"
    if [ -s "$GO_RESOLVER" ]; then
        target_sha="$(sha256_file "$GO_RESOLVER")"
        [ -n "$target_sha" ] && pc_ok "Go resolver sha256: $target_sha" || pc_warn "Go resolver sha256 unavailable"
        if "$GO_RESOLVER" -version >/tmp/xray-go-direct-version.$$ 2>&1; then
            pc_ok "Go resolver version: $(sed -n '1p' /tmp/xray-go-direct-version.$$)"
        else
            pc_warn "Go resolver -version failed"
        fi
        rm -f /tmp/xray-go-direct-version.$$ 2>/dev/null || true
    fi
    [ -s "$GO_RESOLVER_BACKUP" ] && pc_ok "Go resolver backup present: $GO_RESOLVER_BACKUP" || pc_warn "Go resolver backup not found: $GO_RESOLVER_BACKUP"

    echo
    echo "-- Helpers --"
    helper_specs | while IFS='|' read -r mode dest url label; do
        [ -n "$dest" ] || continue
        case "$mode" in
            exec)
                [ -x "$dest" ] && echo "[OK] $label installed: $dest" || echo "[FAIL] $label missing/not executable: $dest"
                ;;
            read)
                [ -r "$dest" ] && echo "[OK] $label installed: $dest" || echo "[FAIL] $label missing/not readable: $dest"
                ;;
        esac
    done

    echo
    echo "-- Auth-aware health helpers --"
    if [ -s "$DOCTOR_CMD" ] && grep -q -- '--proxy-user' "$DOCTOR_CMD"; then pc_ok "doctor helper is SOCKS-auth aware"; else pc_warn "doctor helper does not show SOCKS auth patch"; fi
    if [ -s "$GO_RECOVER_CMD" ] && grep -q -- '--proxy-user' "$GO_RECOVER_CMD"; then pc_ok "recovery helper is SOCKS-auth aware"; else pc_warn "recovery helper does not show SOCKS auth patch"; fi

    echo
    echo "-- Manifest and plan --"
    [ -s "$PLAN_FILE" ] && pc_ok "plan file present: $PLAN_FILE" || pc_warn "plan file not found: $PLAN_FILE"
    if [ -s "$MANIFEST_FILE" ]; then
        pc_ok "manifest present: $MANIFEST_FILE"
        manifest_mode="$(manifest_value INSTALL_MODE)"
        manifest_sha="$(manifest_value BINARY_SHA256)"
        [ "$manifest_mode" = "direct" ] && pc_ok "manifest install mode: direct" || pc_warn "manifest install mode is '${manifest_mode:-missing}'"
        if [ -n "$target_sha" ] && [ -n "$manifest_sha" ]; then
            [ "$target_sha" = "$manifest_sha" ] && pc_ok "manifest binary sha256 matches target" || pc_warn "manifest binary sha256 differs from target"
        fi
    else
        pc_warn "manifest not found: $MANIFEST_FILE"
    fi

    echo
    echo "-- Runtime status --"
    if [ -x "$XRAY_GO_CMD" ]; then
        if "$XRAY_GO_CMD" manifest summary >/tmp/xray-go-direct-manifest.$$ 2>&1; then
            pc_ok "xray-go manifest summary works"
            sed 's/^/  /' /tmp/xray-go-direct-manifest.$$
        else
            pc_warn "xray-go manifest summary failed"
        fi
        rm -f /tmp/xray-go-direct-manifest.$$ 2>/dev/null || true
    else
        pc_warn "xray-go wrapper not executable: $XRAY_GO_CMD"
    fi

    if [ -x "$GO_RECOVER_CMD" ]; then
        if "$GO_RECOVER_CMD" --mode full status >/tmp/xray-go-direct-recover.$$ 2>&1; then
            if grep -q 'health: OK' /tmp/xray-go-direct-recover.$$; then
                pc_ok "recovery health: OK"
            else
                pc_warn "recovery status ran but health is not OK"
            fi
            sed 's/^/  /' /tmp/xray-go-direct-recover.$$
        else
            pc_warn "recovery status command failed"
        fi
        rm -f /tmp/xray-go-direct-recover.$$ 2>/dev/null || true
    else
        pc_warn "recovery helper not executable: $GO_RECOVER_CMD"
    fi

    echo
    echo "Post-check summary: OK=$post_check_ok WARN=$post_check_warn FAIL=$post_check_fail"
    [ "$post_check_fail" -eq 0 ] || exit 1
}

print_plan

if [ "$MODE" = "detect" ]; then
    echo "Detect-only: no changes made."
    exit 0
fi

if [ "$POST_CHECK" = "1" ]; then
    run_post_check
    exit 0
fi

mkdir -p "$STAGE_DIR" "$XRAY_DIR"
install_manifest_helper
download_binary_to_stage
install_binary_from_stage
stage_shell_helpers
install_shell_helpers
write_plan_file
write_manifest

echo
echo "Direct-install skeleton complete."
echo "No first-run setup was executed. Stable Full Go flow is unchanged."
echo "Next checks:"
echo "  xray-go manifest"
echo "  xray-go recover status"
echo "  cat $PLAN_FILE"
