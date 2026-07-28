#!/bin/sh
set -e

# Regenerates the published installer scripts from their sources under
# scripts/src/ plus the shared helpers in scripts/lib/xray-go-common.sh
# (fetch_url, sha256_file, looks_like_shell_script). Each published script
# stays a single self-contained file - safe to curl and run directly - the
# source split only exists to avoid maintaining N copies of the same
# helpers.
#
#   scripts/src/direct/xray-go-direct-*.sh -> scripts/xray-go-direct-*.sh
#   scripts/src/misc/install.sh            -> install.sh
#   scripts/src/misc/<name>.sh             -> scripts/<name>.sh
#
# Run this after editing anything under scripts/src/ or
# scripts/lib/xray-go-common.sh, then commit the regenerated output
# alongside the source change. CI checks that the committed output matches
# a fresh build.

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
COMMON="$ROOT_DIR/scripts/lib/xray-go-common.sh"

# Splices $COMMON into $src, right after its leading run of shebang/set
# lines, and writes the result to $out. The header length is detected per
# file instead of assumed, since not every script has the same number of
# lines before its first blank line (e.g. some carry no `set` directive).
splice() {
    src="$1"
    out="$2"

    header=0
    while IFS= read -r line; do
        case "$line" in
        '#!'* | 'set '*) header=$((header + 1)) ;;
        *) break ;;
        esac
    done <"$src"

    {
        head -n "$header" "$src"
        echo
        cat "$COMMON"
        tail -n "+$((header + 1))" "$src"
    } >"$out"

    sh -n "$out" || {
        echo "ERROR: syntax check failed for $out" >&2
        exit 1
    }
}

built=0

for src in "$ROOT_DIR"/scripts/src/direct/xray-go-direct-*.sh; do
    name="$(basename "$src")"
    splice "$src" "$ROOT_DIR/scripts/$name"
    built=$((built + 1))
done

for src in "$ROOT_DIR"/scripts/src/misc/*.sh; do
    name="$(basename "$src")"
    if [ "$name" = "install.sh" ]; then
        out="$ROOT_DIR/install.sh"
    else
        out="$ROOT_DIR/scripts/$name"
    fi
    splice "$src" "$out"
    built=$((built + 1))
done

echo "Built $built generated script(s) from scripts/src/ + $(basename "$COMMON")"
