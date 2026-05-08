#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="src/full/xray_vless_failover.sh"
MODULE="src/full/modules/healthcheck.sh"

[ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }
[ -f "$MODULE" ] || { echo "Missing: $MODULE" >&2; exit 1; }

TMP1="$TARGET.tmp1"
TMP2="$TARGET.tmp2"
TMP3="$TARGET.tmp3"

cleanup() {
    rm -f "$TMP1" "$TMP2" "$TMP3" "$TARGET.tmp"
}

trap cleanup EXIT INT TERM

replace_function() {
    FUNC_NAME="$1"
    INPUT_FILE="$2"
    OUTPUT_FILE="$3"

    awk -v module="$MODULE" -v func_name="$FUNC_NAME" '
    BEGIN {
        replacing = 0
        inserted = 0
        pattern = "^" func_name "\\(\\) \\{"
    }

    function print_module_func() {
        in_module_func = 0
        module_depth = 0
        found_in_module = 0

        while ((getline line < module) > 0) {
            if (!in_module_func && line ~ pattern) {
                in_module_func = 1
                found_in_module = 1
            }

            if (in_module_func) {
                print line
                module_open_count = gsub(/\{/, "{", line)
                module_close_count = gsub(/\}/, "}", line)
                module_depth += module_open_count - module_close_count
                if (module_depth <= 0) {
                    break
                }
            }
        }

        close(module)

        if (!found_in_module) {
            print "ERROR: function not found in module: " func_name > "/dev/stderr"
            exit 1
        }

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
            print "ERROR: function not found in target: " func_name > "/dev/stderr"
            exit 1
        }
    }
    ' "$INPUT_FILE" > "$OUTPUT_FILE"
}

replace_function "profile_external_ip" "$TARGET" "$TMP1"
replace_function "test_https_healthcheck_through_socks" "$TMP1" "$TMP2"
replace_function "test_socks_endpoint" "$TMP2" "$TMP3"

mv "$TMP3" "$TARGET"
rm -f "$TMP1" "$TMP2"
trap - EXIT INT TERM

sh -n "$TARGET"

echo "Applied module: $MODULE -> $TARGET"
