#!/bin/sh
set -e

WEB_TAG="${WEB_TAG:-latest}"
WEB_BIN="/opt/bin/vless-go-web"
WEB_CONF="/opt/etc/xray/vless-go-web.conf"
WEB_TOKEN="/opt/etc/xray/vless-go-web.token"
WEB_INIT="/opt/etc/init.d/S27vless-go-web"
WEB_LISTEN="${WEB_LISTEN:-0.0.0.0:18088}"
WEB_PORT="${WEB_PORT:-18088}"
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
    command -v "$1" >/dev/null 2>&1 || { echo "ОШИБКА: не найдена обязательная команда: $1" >&2; exit 1; }
}

detect_lan_ip() {
    if command -v ndmc >/dev/null 2>&1; then
        {
            ndmc -c "show interface Home" 2>/dev/null || true
            ndmc -c "show interface Bridge0" 2>/dev/null || true
        } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | awk '$1 ~ /^192\.168\./ || $1 ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ || $1 ~ /^10\./ { print; exit }'
    fi
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show scope link 2>/dev/null | awk '/ src / { for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit } }'
    fi
}

need_cmd curl
mkdir -p /opt/bin /opt/etc/xray "$TMP_DIR"

ARCH="${ENTWARE_ARCH:-$(detect_entware_arch)}"
[ -n "$ARCH" ] || ARCH="$(uname -m 2>/dev/null || echo unknown)"
ASSET="${WEB_ASSET_NAME:-$(asset_name_for_arch "$ARCH")}"
[ -n "$ASSET" ] || { echo "ОШИБКА: неподдерживаемая архитектура для vless-go-web: $ARCH" >&2; exit 1; }
URL="${WEB_BINARY_URL:-https://github.com/Kuzz007/keenetic_xray_installer/releases/download/${WEB_TAG}/${ASSET}}"
TMP_BIN="$TMP_DIR/vless-go-web.$$"

echo "Определена архитектура: $ARCH"
echo "Скачиваю vless-go-web: $URL"
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

LISTEN="$(grep '^LISTEN=' "$WEB_CONF" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"' || echo "$WEB_LISTEN")"
PORT="$(echo "$LISTEN" | awk -F: '{print $NF}')"
[ -n "$PORT" ] || PORT="$WEB_PORT"
LAN_IP="${WEB_LAN_IP:-$(detect_lan_ip | awk 'NF { print; exit }')}"
[ -n "$LAN_IP" ] || LAN_IP="192.168.1.1"

echo ""
echo "vless-go-web установлен."
echo "Сервис:  $WEB_INIT"
echo "Конфиг:  $WEB_CONF"
echo "Токен:   $WEB_TOKEN"
echo "Адрес:   $LISTEN"
echo ""
echo "Открой в браузере:"
echo "  http://$LAN_IP:$PORT/"
echo ""
echo "Используй этот адрес только в доверенной локальной сети. Не открывай порт в интернет."
echo "Form token хранится здесь: $WEB_TOKEN"
