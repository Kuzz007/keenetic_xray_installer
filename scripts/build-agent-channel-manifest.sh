#!/bin/sh
set -eu

CHANNEL="${CHANNEL:-}"
VERSION="${VERSION:-}"
COMMIT="${COMMIT:-}"
PUBLISHED_AT="${PUBLISHED_AT:-}"
ASSET_DIR="${ASSET_DIR:-dist}"
OUT="${OUT:-$ASSET_DIR/agent-channel.json}"

case "$CHANNEL" in
    latest|dev) ;;
    *) echo "ERROR: CHANNEL must be latest or dev" >&2; exit 2 ;;
esac

case "$VERSION" in
    ''|*[!A-Za-z0-9._+-]*) echo "ERROR: VERSION contains unsupported characters" >&2; exit 2 ;;
esac

case "$COMMIT" in
    ''|*[!0-9A-Fa-f]*) echo "ERROR: COMMIT must be a hexadecimal git commit" >&2; exit 2 ;;
esac

if [ "${#COMMIT}" -lt 7 ] || [ "${#COMMIT}" -gt 64 ]; then
    echo "ERROR: COMMIT length must be between 7 and 64" >&2
    exit 2
fi

case "$PUBLISHED_AT" in
    ''|*[!0-9TZ:+.-]*) echo "ERROR: PUBLISHED_AT must be an RFC3339-like UTC timestamp" >&2; exit 2 ;;
esac

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
        return
    fi
    echo "ERROR: sha256sum or shasum is required" >&2
    exit 1
}

artifact_json() {
    arch="$1"
    suffix="$2"
    asset="xray-go-agent-linux-$suffix"
    path="$ASSET_DIR/$asset"
    [ -f "$path" ] || { echo "ERROR: missing agent artifact: $path" >&2; exit 1; }
    sha="$(sha256_file "$path")"
    size="$(wc -c <"$path" | tr -d '[:space:]')"
    printf '    "%s": {"asset": "%s", "sha256": "%s", "size": %s}' "$arch" "$asset" "$sha" "$size"
}

mkdir -p "$(dirname "$OUT")"
tmp="$OUT.$$"
{
    echo '{'
    echo '  "schema": "keenetic-vpn.agent-channel.v1",'
    printf '  "channel": "%s",\n' "$CHANNEL"
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "commit": "%s",\n' "$COMMIT"
    printf '  "published_at": "%s",\n' "$PUBLISHED_AT"
    echo '  "artifacts": {'
    artifact_json arm64 arm64
    echo ','
    artifact_json mipsle mipsle
    echo ','
    artifact_json mips mips
    echo
    echo '  }'
    echo '}'
} >"$tmp"
mv "$tmp" "$OUT"

echo "Built agent channel manifest: $OUT"
