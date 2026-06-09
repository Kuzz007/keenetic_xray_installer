#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition public entrypoint.
# Keep this filename as the current installer URL, but avoid embedded gzip/base64 payloads.
# Some Keenetic/Entware environments report gzip crc/magic errors with self-extracting wrappers.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
PLAIN_URL="${MINIMAL_GO_PLAIN_URL:-${REPO_BASE}/xray_vless_failover_minimal.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/xray_vless_failover_minimal_go.plain.$$"
PATCHED="$TMP_DIR/xray_vless_failover_minimal_go.xhttp.$$"

cleanup() { rm -f "$OUT" "$PATCHED" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

fetch_plain() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$PLAIN_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL" || wget --no-check-certificate --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL"
        return $?
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

patch_xhttp_support() {
    awk '
        $0 == "if [ \"$TYPE\" != \"tcp\" ]; then" {
            print "case \"$TYPE\" in"
            print "    tcp|xhttp) ;;"
            print "    splithttp) TYPE=\"xhttp\" ;;"
            print "    *)"
            print "        echo \"ERROR: minimal edition currently supports only type=tcp or type=xhttp.\""
            print "        exit 1"
            print "        ;;"
            print "esac"
            skip_type_check=1
            next
        }
        skip_type_check {
            if ($0 == "fi") skip_type_check=0
            next
        }
        /sed .*%2F/ && /%20/ {
            sub("s/%20/ /Ig", "s/%20/ /Ig; s/%7B/{/Ig; s/%7D/}/Ig; s/%22/\\\"/Ig; s/%5B/[/Ig; s/%5D/]/Ig; s/%2C/,/Ig; s/%2B/+/Ig; s/%7C/|/Ig; s/%25/%/Ig", $0)
        }
        $0 == "HEADER_TYPE=\"$(get_param headerType)\"" {
            print
            print "XHTTP_PATH=\"$(get_param path)\""
            print "XHTTP_HOST=\"$(get_param host)\""
            print "XHTTP_MODE=\"$(get_param mode)\""
            print "XHTTP_EXTRA=\"$(get_param extra)\""
            next
        }
        $0 == "[ -n \"$SPX\" ] || SPX=\"%2F\"" {
            print
            print "if [ \"$TYPE\" = \"splithttp\" ]; then TYPE=\"xhttp\"; fi"
            next
        }
        $0 == "HEADER_TYPE_E=\"$(json_escape \"$HEADER_TYPE\")\"" {
            print
            print "XHTTP_PATH_D=\"$(url_decode_light \"$XHTTP_PATH\")\""
            print "XHTTP_HOST_D=\"$(url_decode_light \"$XHTTP_HOST\")\""
            print "XHTTP_EXTRA_D=\"$(url_decode_light \"$XHTTP_EXTRA\")\""
            print "[ -n \"$XHTTP_PATH_D\" ] || XHTTP_PATH_D=\"/\""
            print "[ -n \"$XHTTP_MODE\" ] || XHTTP_MODE=\"auto\""
            print "XHTTP_PATH_E=\"$(json_escape \"$XHTTP_PATH_D\")\""
            print "XHTTP_HOST_E=\"$(json_escape \"$XHTTP_HOST_D\")\""
            print "XHTTP_MODE_E=\"$(json_escape \"$XHTTP_MODE\")\""
            next
        }
        $0 == "if [ -n \"$HEADER_TYPE\" ] && [ \"$HEADER_TYPE\" != \"none\" ]; then" {
            print "if [ \"$TYPE\" = \"xhttp\" ]; then"
            print "cat <<EOF"
            print "        ,"
            print "        \"xhttpSettings\": {"
            print "          \"path\": \"$XHTTP_PATH_E\"$(if [ -n \"$XHTTP_HOST_D\" ]; then printf '\'',\\n          \"host\": \"%s\"'\'' \"$XHTTP_HOST_E\"; fi),"
            print "          \"mode\": \"$XHTTP_MODE_E\"$(if [ -n \"$XHTTP_EXTRA_D\" ]; then printf '\'',\\n          \"extra\": %s'\'' \"$XHTTP_EXTRA_D\"; fi)"
            print "        }"
            print "EOF"
            print "fi"
            print ""
            print "if [ \"$TYPE\" = \"tcp\" ] && [ -n \"$HEADER_TYPE\" ] && [ \"$HEADER_TYPE\" != \"none\" ]; then"
            next
        }
        { print }
    ' "$OUT" > "$PATCHED"

    if ! grep -q '"xhttpSettings"' "$PATCHED"; then
        echo "ERROR: failed to patch Minimal installer with XHTTP support." >&2
        return 1
    fi

    mv "$PATCHED" "$OUT"
}

echo "Downloading Minimal plain installer..."
fetch_plain || { echo "ERROR: failed to download Minimal installer: $PLAIN_URL" >&2; exit 1; }
patch_xhttp_support || exit 1

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal installer does not look like a shell script: $PLAIN_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal installer failed shell syntax check: $PLAIN_URL" >&2
    exit 1
fi

chmod +x "$OUT"
exec sh "$OUT" "$@"
