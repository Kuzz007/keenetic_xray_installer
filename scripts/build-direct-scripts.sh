#!/bin/sh
set -e

# Regenerates scripts/xray-go-direct-*.sh from scripts/src/direct/*.sh plus the
# shared helpers in scripts/lib/xray-go-direct-common.sh (fetch_url, sha256_file,
# looks_like_shell_script). Each published script stays a single self-contained
# file - safe to curl and run directly - the source split only exists to avoid
# maintaining N copies of the same helpers.
#
# Run this after editing anything under scripts/src/direct/ or
# scripts/lib/xray-go-direct-common.sh, then commit the regenerated
# scripts/xray-go-direct-*.sh alongside the source change. CI checks that the
# committed output matches a fresh build.

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT_DIR/scripts/lib/xray-go-direct-common.sh"
SRC_DIR="$ROOT_DIR/scripts/src/direct"
OUT_DIR="$ROOT_DIR/scripts"

built=0
for src in "$SRC_DIR"/xray-go-direct-*.sh; do
    name="$(basename "$src")"
    out="$OUT_DIR/$name"

    {
        head -n 2 "$src"
        echo
        cat "$COMMON"
        tail -n +3 "$src"
    } >"$out"

    sh -n "$out" || {
        echo "ERROR: syntax check failed for $out" >&2
        exit 1
    }
    built=$((built + 1))
done

echo "Built $built direct-*.sh script(s) from scripts/src/direct/ + $(basename "$COMMON")"
