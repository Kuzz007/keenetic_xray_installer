#!/bin/sh
set -e

WEB_TAG="${WEB_TAG:-latest}"
WEB_BIN="/opt/bin/vless-go-web"
WEB_CONF="/opt/etc/xray/vless-go-web.conf"
WEB_TOKEN="/opt/etc/xray/vless-go-web.token"
WEB_INIT="/opt/etc/init.d/S27vless-go-web"
WEB_LISTEN="${WEB_LISTEN:-127.0.0.1:18088}"
TMP_DIR="/opt/tmp"

opkg_bin() { if command -v opkg >/dev/null 2>&1; then command -v opkg; elif [ -x /opt/bin/opkg ]; then echo /opt/bin/opkg; else echo ""; fi; }

detect_entware_arch() {
    OPKG_BIN="$(opkg_bin)"
    [ -n "$OPKG_BIN" ] || return 0
    "$OPKG_BIN" print-architecture 2>/dev/null | awk '$2 != "all" && ($3+0) >= max { arch=$2; max=$3+0 } END { if (arch != "") print arch }'
}

asset_name_for_arch() {
    case "$1" in
        aarch64-3.10|aarch64*|arm64) echo "vless-go-web-linux-arm64" ;;
        mips|mipsel|mipsel-*|mipsel_*|mipselsf-*|mipselsf_*|mipsel-3.4|mipsel-3.4_kn|mipselsf-k3.4|mipselsf-k3.4_kn) echo "vless-go-web-linux-mipsle" ;;
        *) echo "" ;;
    esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

need_cmd curl
mkdir -p /opt/bin /opt/etc/xray "$TMP_DIR"

ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ARCH" ] || ARCH="$(uname -m 2>/dev/null || echo unknown)"
ASSET="${WEB_ASSET_NAME:-$(asset_name_for_arch "$ARCH")}"
[ -n "$ASSET" ] || { echo "ERROR: unsupported architecture for vless-go-web: $ARCH" >&2; exit 1; }
URL="${WEB_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${WEB_TAG}/${ASSET}}"
TMP_BIN="$TMP_DIR/vless-go-web.$$"

echo "Detected architecture: $ARCH"
echo "Downloading vless-go-web: $URL"
curl -fL -o "$TMP_BIN" "$URL"
chmod +x "$TMP_BIN"
mv "$TMP_BIN" "$WEB_BIN"
chmod +x "$WEB_BIN"

if [ ! -s "$WEB_CONF" ]; then
    cat > "$WEB_CONF" <<EOF
LISTEN="$WEB_LISTEN"
EOF
    chmod 600 "$WEB_CONF" 2>/dev/null || true
fi

if [ ! -s "$WEB_TOKEN" ]; then
    if command -v hexdump >/dev/null 2>&1; then
        dd if=/dev/urandom bs=16 count=1 2>/dev/null | hexdump -ve '1/1 "%02x"' > "$WEB_TOKEN"
        echo >> "$WEB_TOKEN"
    else
        date +%s | md5sum | awk '{print $1}' > "$WEB_TOKEN"
    fi
    chmod 600 "$WEB_TOKEN" 2>/dev/null || true
fi

cat > "$WEB_INIT" <<INIT
#!/bin/sh

ENABLED=yes
PROCS=vless-go-web
ARGS=""
PREARGS=""
DESC="VLESS Go Web UI"
PATH=/opt/sbin:/opt/bin:/opt/usr/sbin:/opt/usr/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
INIT
chmod +x "$WEB_INIT"

"$WEB_INIT" restart || "$WEB_INIT" start || true

TOKEN="$(sed -n '1p' "$WEB_TOKEN" 2>/dev/null || true)"
LISTEN="$(grep '^LISTEN=' "$WEB_CONF" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"' || echo "$WEB_LISTEN")"

echo ""
echo "vless-go-web installed."
echo "Service: $WEB_INIT"
echo "Config:  $WEB_CONF"
echo "Token:   $WEB_TOKEN"
echo "Listen:  $LISTEN"
echo ""
echo "Open locally or through SSH tunnel:"
echo "  http://$LISTEN/"
echo ""
echo "If exposed beyond localhost, protect access at the network level."
echo "Form token is stored in: $WEB_TOKEN"
