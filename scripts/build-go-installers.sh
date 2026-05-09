#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
GOOS_TARGET="${GOOS_TARGET:-linux}"
GOARCH_TARGET="${GOARCH_TARGET:-arm64}"
BIN_NAME="${BIN_NAME:-xray-failover-go}"

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: go command not found. Install Go before building." >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"

echo "Building $BIN_NAME for $GOOS_TARGET/$GOARCH_TARGET..."
CGO_ENABLED=0 GOOS="$GOOS_TARGET" GOARCH="$GOARCH_TARGET" \
    go build -trimpath -ldflags "-s -w" -o "$OUT_DIR/$BIN_NAME-$GOOS_TARGET-$GOARCH_TARGET" ./cmd/xray-failover-go

chmod +x "$OUT_DIR/$BIN_NAME-$GOOS_TARGET-$GOARCH_TARGET"

echo "Built: $OUT_DIR/$BIN_NAME-$GOOS_TARGET-$GOARCH_TARGET"
