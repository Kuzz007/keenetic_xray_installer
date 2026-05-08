#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

FULL_SRC="src/full/xray_vless_failover.sh"
MINIMAL_SRC="src/minimal/xray_vless_failover_minimal.sh"
FULL_OUT="xray_vless_failover.sh"
MINIMAL_OUT="xray_vless_failover_minimal.sh"

[ -f "$FULL_SRC" ] || { echo "Missing: $FULL_SRC" >&2; exit 1; }
[ -f "$MINIMAL_SRC" ] || { echo "Missing: $MINIMAL_SRC" >&2; exit 1; }

cp "$FULL_SRC" "$FULL_OUT"
cp "$MINIMAL_SRC" "$MINIMAL_OUT"

chmod +x "$FULL_OUT" "$MINIMAL_OUT"
sh -n "$FULL_OUT"
sh -n "$MINIMAL_OUT"

echo "Built: $FULL_OUT"
echo "Built: $MINIMAL_OUT"
