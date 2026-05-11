#!/bin/sh
set -e

REPO_TAG="${REPO_TAG:-0.1.2-go-experimental}"
FEED_NAME="failover-go"
FEED_URL="${FEED_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${REPO_TAG}}"
FEED_DIR="/opt/etc/opkg"
FEED_FILE="$FEED_DIR/${FEED_NAME}.conf"
OPKG_CONF="/opt/etc/opkg.conf"

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

clean_stale_feed() {
    # Previous failed/manual attempts may have left an HTTPS failover-go feed
    # in opkg.conf or /opt/etc/opkg/failover-go.conf. Remove it before the
    # first opkg update, otherwise non-SSL wget can break bootstrap before
    # wget-ssl is installed.
    if [ -f "$FEED_FILE" ]; then
        cp "$FEED_FILE" "$FEED_FILE.bak.$(date +%s)" 2>/dev/null || true
        rm -f "$FEED_FILE"
    fi

    if [ -f "$OPKG_CONF" ] && grep -q 'failover-go' "$OPKG_CONF" 2>/dev/null; then
        cp "$OPKG_CONF" "$OPKG_CONF.bak.$(date +%s)" 2>/dev/null || true
        grep -v 'failover-go' "$OPKG_CONF" > /opt/tmp/opkg.conf.failover-go-clean.$$ || true
        cat /opt/tmp/opkg.conf.failover-go-clean.$$ > "$OPKG_CONF"
        rm -f /opt/tmp/opkg.conf.failover-go-clean.$$
    fi

    rm -f /opt/var/opkg-lists/failover-go 2>/dev/null || true
}

need_cmd opkg

log "[0/5] Cleaning stale failover-go feed entries..."
mkdir -p "$FEED_DIR"
clean_stale_feed

log "[1/5] Updating Entware package lists..."
opkg update

log "[2/5] Installing HTTPS downloader support..."
opkg install ca-certificates wget-ssl
opkg remove wget-nossl >/dev/null 2>&1 || true

if command -v wget >/dev/null 2>&1; then
    if ! wget --help 2>&1 | grep -qi https; then
        warn "wget does not advertise HTTPS support after installing wget-ssl."
        warn "If opkg update fails on https:// feed, reinstall wget-ssl manually: opkg install --force-reinstall wget-ssl"
    fi
fi

log "[3/5] Registering failover-go feed..."
printf 'src/gz %s %s\n' "$FEED_NAME" "$FEED_URL" > "$FEED_FILE"
log "Feed file: $FEED_FILE"
log "Feed URL:  $FEED_URL"

log "[4/5] Updating package lists with failover-go feed..."
opkg update

log "[5/5] Installing failover-go from feed..."
opkg install failover-go

log ""
log "failover-go Entware feed installation completed."
log "Next steps:"
log "  xray_vless_failover_go.sh"
log "  failover-go"
log "  vless-go-doctor"
