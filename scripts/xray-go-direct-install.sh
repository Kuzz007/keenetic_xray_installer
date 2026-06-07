#!/bin/sh
set -e

# xray-go-direct-install - experimental direct-install v2 skeleton.
#
# This script is intentionally conservative. It can detect architecture, stage the
# Go resolver binary, install the manifest helper and write an experimental
# manifest. It does not run first setup and does not replace the stable
# auto_latest/IPK flow yet.

XRAY_GO_DIRECT_VERSION="${XRAY_GO_DIRECT_VERSION:-0.1.0-direct-skeleton}"
REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
GO_RELEASE_TAG="${GO_RELEASE_TAG:-latest}"
RELEASE_BASE="${RELEASE_BASE:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${GO_RELEASE_TAG}}"

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
TMP_DIR="${TMPDIR:-/opt/tmp}"
STAGE_DIR="${XRAY_GO_DIRECT_STAGE_DIR:-${TMP_DIR}/xray-go-direct-install}"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
MANIFEST_CMD="${MANIFEST_CMD:-/opt/bin/xray-go-manifest}"
MANIFEST_URL="${MANIFEST_URL:-${RAW_BASE}/scripts/xray-go-manifest.sh}"
PLAN_FILE="${PLAN_FILE:-${XRAY_DIR}/xray-go.direct-install.plan}"

MODE="prepare"
DOWNLOAD_BINARY="0"
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
  --write-manifest       Also write /opt/etc/xray/xray-go.manifest as direct

Options:
  --download-binary      Download and verify the Go resolver into staging dir
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
        --write-manifest) WRITE_MANIFEST="1"; shift ;;
        --download-binary) DOWNLOAD_BINARY="1"; shift ;;
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
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*|mipsel-3.4|mipsel-3.4_kn|mipselsf-k3.4|mipselsf-k3.4_kn)
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

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
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
Target binary path: $GO_RESOLVER
Manifest helper: $MANIFEST_CMD
Manifest helper URL: $MANIFEST_URL
Plan file: $PLAN_FILE
Download binary: $DOWNLOAD_BINARY
Install manifest helper: $INSTALL_MANIFEST_HELPER
Write manifest: $WRITE_MANIFEST
EOF_PLAN
}

write_plan_file() {
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
        echo "TARGET_BINARY=\"$GO_RESOLVER\""
        echo "MANIFEST_HELPER=\"$MANIFEST_CMD\""
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
    sh -n "$tmp" || { echo "ERROR: manifest helper failed shell syntax check." >&2; exit 1; }
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

write_manifest() {
    [ "$WRITE_MANIFEST" = "1" ] || return 0
    [ -x "$MANIFEST_CMD" ] || { echo "ERROR: manifest helper is not installed: $MANIFEST_CMD" >&2; exit 1; }
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
        --modules "manifest,direct-experimental"
}

print_plan

if [ "$MODE" = "detect" ]; then
    echo "Detect-only: no changes made."
    exit 0
fi

mkdir -p "$STAGE_DIR" "$XRAY_DIR"
install_manifest_helper
download_binary_to_stage
write_plan_file
write_manifest

echo
echo "Direct-install skeleton complete."
echo "No first-run setup was executed. Stable Full Go flow is unchanged."
echo "Next checks:"
echo "  xray-go manifest"
echo "  cat $PLAN_FILE"
