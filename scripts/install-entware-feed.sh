#!/bin/sh
set -e

REPO_TAG="${REPO_TAG:-0.1.2-go-experimental}"
FEED_NAME="failover-go"
FEED_URL="${FEED_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${REPO_TAG}}"
FEED_DIR="/opt/etc/opkg"
FEED_FILE="$FEED_DIR/${FEED_NAME}.conf"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'ERROR: required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

need_cmd opkg

log "[1/4] Updating Entware package lists..."
opkg update

log "[2/4] Installing HTTPS downloader support..."
opkg install ca-certificates wget-ssl
opkg remove wget-nossl >/dev/null 2>&1 || true

if command -v wget >/dev/null 2>&1; then
    if ! wget --help 2>&1 | grep -qi https; then
        warn "wget does not advertise HTTPS support after installing wget-ssl."
        warn "If opkg update fails on https:// feed, reinstall wget-ssl manually: opkg install --force-reinstall wget-ssl"
    fi
fi

log "[3/4] Registering failover-go feed..."
mkdir -p "$FEED_DIR"
if [ -f "$FEED_FILE" ]; then
    cp "$FEED_FILE" "$FEED_FILE.bak.$(date +%s)" 2>/dev/null || true
fi
printf 'src/gz %s %s\n' "$FEED_NAME" "$FEED_URL" > "$FEED_FILE"
log "Feed file: $FEED_FILE"
log "Feed URL:  $FEED_URL"

log "[4/4] Installing failover-go from feed..."
opkg update
opkg install failover-go

log ""
log "failover-go Entware feed installation completed."
log "Next steps:"
log "  xray_vless_failover_go.sh"
log "  failover-go"
log "  vless-go-doctor"
