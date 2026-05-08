#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/full/xray_vless_failover.sh"
MODULE="src/full/modules/healthcheck.sh"
TMP="$TARGET.tmp"

[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }
[ -f "$MODULE" ] || { echo "Missing: $MODULE" >&2; exit 1; }

replace_function() {
    FUNC_NAME="$1"
    INPUT_FILE="$2"
    OUTPUT_FILE="$3"

    awk -v module="$MODULE" -v func="$FUNC_NAME" '
    BEGIN {
        replacing = 0
        inserted = 0
        pattern = "^" func "\\(\\) \\{"
    }

    function print_module_func() {
        in_func = 0
        depth_m = 0
        while ((getline line < module) > 0) {
            if (!in_func && line ~ pattern) {
                in_func = 1
            }
            if (in_func) {
                print line
                open_count_m = gsub(/\{/, "{", line)
                close_count_m = gsub(/\}/, "}", line)
                depth_m += open_count_m - close_count_m
                if (depth_m <= 0) {
                    break
                }
            }
        }
        close(module)
        inserted = 1
    }

    $0 ~ pattern {
        print_module_func()
        replacing = 1
        depth = 0
        open_count = gsub(/\{/, "{")
        close_count = gsub(/\}/, "}")
        depth += open_count - close_count
        if (depth <= 0) {
            replacing = 0
        }
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
            print "ERROR: function not found: " func > "/dev/stderr"
            exit 1
        }
    }
    ' "$INPUT_FILE" > "$OUTPUT_FILE"
}

TMP1="$TARGET.tmp1"
TMP2="$TARGET.tmp2"
TMP3="$TARGET.tmp3"

replace_function "profile_external_ip" "$TARGET" "$TMP1"
replace_function "test_https_healthcheck_through_socks" "$TMP1" "$TMP2"
replace_function "test_socks_endpoint" "$TMP2" "$TMP3"

mv "$TMP3" "$TARGET"
rm -f "$TMP1" "$TMP2" "$TMP"

sh -n "$TARGET"

echo "Applied module: $MODULE -> $TARGET"
