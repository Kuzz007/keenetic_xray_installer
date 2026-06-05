#!/bin/sh
set -e

# Auto installer latest edition.
# Thin selector/downloader wrapper. It intentionally points only to the current Go entrypoints:
#   - xray_vless_failover_go.sh
#   - xray_vless_failover_minimal_go.sh
# Legacy minimal-next is not downloaded from this wrapper.

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"
GO_FULL_URL="${GO_FULL_URL:-$REPO_BASE/xray_vless_failover_go.sh}"
MINIMAL_GO_URL="${MINIMAL_GO_URL:-$REPO_BASE/xray_vless_failover_minimal_go.sh}"

GO_FULL_TMP="/opt/tmp/xray_vless_failover_go.sh"
MINIMAL_GO_TMP="/opt/tmp/xray_vless_failover_minimal_go.sh"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"
EDITION="${EDITION:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
MODE="${MODE:-install}"
LEGACY_REDIRECT="0"

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_auto_latest.sh [options]

Edition selection:
  --auto                 Auto: low /opt space selects Minimal Go
  --go                   Force xray_vless_failover_go.sh
  --minimal-go           Force xray_vless_failover_minimal_go.sh
  --minimal              Alias for --minimal-go
  --minimal-next         Legacy alias redirected to --minimal-go
  --legacy-minimal       Legacy alias redirected to --minimal-go

Modes:
  --detect-only          Print selected installer and exit
  --dry-run              Alias for --detect-only

Other options:
  -y, --yes              Do not ask interactive confirmation
  -h, --help             Show help
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --go|--force-go) EDITION="go"; shift ;;
        --minimal|--minimal-go|--force-minimal) EDITION="minimal-go"; shift ;;
        --minimal-next|--legacy-minimal) EDITION="minimal-go"; LEGACY_REDIRECT="1"; shift ;;
        --auto) EDITION="auto"; shift ;;
        -y|--yes) ASSUME_YES="1"; shift ;;
        --dry-run|--check|--print-selection|--detect-only) MODE="detect-only"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

case "$THRESHOLD_KB" in ''|*[!0-9]*) echo "ERROR: THRESHOLD_KB must be numeric, got: $THRESHOLD_KB" >&2; exit 1 ;; esac
case "$EDITION" in auto|go|minimal-go) ;; *) echo "ERROR: unsupported EDITION=$EDITION" >&2; exit 1 ;; esac
case "$MODE" in install|detect-only) ;; *) echo "ERROR: unsupported MODE=$MODE" >&2; exit 1 ;; esac

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
    case "$REPLY" in n|N|no|NO|Нет|нет) echo "Cancelled."; exit 0 ;; esac
}

looks_like_shell_script() {
    head -n 1 "$1" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'
}

download_installer() {
    url="$1"
    output="$2"
    label="$3"
    mkdir -p "$(dirname "$output")"
    echo "Downloading $label installer: $url"
    curl -fsSL -H 'Cache-Control: no-cache' -o "$output" "$url" || { echo "ERROR: failed to download $label installer: $url" >&2; exit 1; }
    looks_like_shell_script "$output" || { echo "ERROR: downloaded $label installer does not look like a shell script: $url" >&2; head -n 3 "$output" >&2 || true; exit 1; }
    sh -n "$output" || { echo "ERROR: downloaded $label installer failed shell syntax check: $output" >&2; exit 1; }
    chmod +x "$output"
}

FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2 { print $4 }')"
case "$FREE_KB" in ''|*[!0-9]*) FREE_KB="0" ;; esac

if [ "$EDITION" = "auto" ]; then
    if [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
        SELECTED="minimal-go"
        REASON="free /opt space is below threshold"
    else
        SELECTED="go"
        REASON="free /opt space is at or above threshold"
    fi
else
    SELECTED="$EDITION"
    REASON="explicit edition override"
fi

case "$SELECTED" in
    minimal-go) INSTALLER_URL="$MINIMAL_GO_URL"; INSTALLER_TMP="$MINIMAL_GO_TMP"; INSTALLER_LABEL="Minimal Go" ;;
    go) INSTALLER_URL="$GO_FULL_URL"; INSTALLER_TMP="$GO_FULL_TMP"; INSTALLER_LABEL="Go/Entware latest" ;;
    *) echo "ERROR: unknown selected edition: $SELECTED" >&2; exit 1 ;;
esac

echo "Free /opt space: ${FREE_KB} KB"
echo "Full/Go threshold: ${THRESHOLD_KB} KB"
echo "Selected edition: $SELECTED"
echo "Selection reason: $REASON"
echo "Installer URL: $INSTALLER_URL"
[ "$LEGACY_REDIRECT" = "1" ] && echo "Legacy minimal option was requested; redirected to Minimal Go."

if [ "$MODE" = "detect-only" ]; then
    echo "Detect-only: no changes made."
    exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found. Install curl/ca-certificates via Entware first." >&2; exit 1; }

confirm_install "$INSTALLER_LABEL"
download_installer "$INSTALLER_URL" "$INSTALLER_TMP" "$INSTALLER_LABEL"
exec sh "$INSTALLER_TMP"
