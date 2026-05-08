#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/full/xray_vless_failover.sh"
MODULE="src/full/modules/proxy0.sh"
TMP="$TARGET.tmp"

[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }
[ -f "$MODULE" ] || { echo "Missing: $MODULE" >&2; exit 1; }

awk -v module="$MODULE" '
BEGIN {
    replacing = 0
    inserted = 0
}

function print_module() {
    while ((getline line < module) > 0) {
        print line
    }
    close(module)
    inserted = 1
}

/^configure_proxy0\(\) \{/ {
    print_module()
    replacing = 1
    depth = 1
    next
}

replacing {
    open_count = gsub(/\{/, "{")
    close_count = gsub(/\}/, "}")
    depth += open_count - close_count
    if (depth <= 0) {
        replacing = 0
    }
    next
}

{
    print
}

END {
    if (!inserted) {
        print "ERROR: configure_proxy0() not found" > "/dev/stderr"
        exit 1
    }
}
' "$TARGET" > "$TMP"

mv "$TMP" "$TARGET"
sh -n "$TARGET"

echo "Applied module: $MODULE -> $TARGET"
