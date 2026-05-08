#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUT="$ROOT_DIR/demo-installer.sh"

cat \
  "$ROOT_DIR/src/00-header.sh" \
  "$ROOT_DIR/src/10-functions.sh" \
  "$ROOT_DIR/src/99-main.sh" \
  > "$OUT"

chmod +x "$OUT"
sh -n "$OUT"

echo "Built: $OUT"
