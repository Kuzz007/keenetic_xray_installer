#!/bin/sh
set -eu

# vless-go-privacy-check - read-only checker for support/doctor outputs.
#
# It captures diagnostic commands into temporary files and scans them for common
# secret patterns. It never prints the matching secret value; only the pattern
# category and the command label are reported.

TMP_ROOT="${TMPDIR:-/tmp}/vless-go-privacy-check.$$"
OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

cleanup() {
    rm -rf "$TMP_ROOT" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

ok() {
    echo "[OK] $*"
    OK_COUNT=$((OK_COUNT + 1))
}

warn() {
    echo "[WARN] $*"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
    echo "[FAIL] $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

capture_command() {
    label="$1"
    output="$2"
    shift 2

    if "$@" >"$output" 2>&1; then
        ok "$label captured"
        return 0
    fi

    rc="$?"
    warn "$label exited with rc=$rc; captured output will still be scanned"
    return 0
}

scan_regex() {
    label="$1"
    file="$2"
    pattern_label="$3"
    pattern="$4"

    if grep -Eiq "$pattern" "$file" 2>/dev/null; then
        fail "$label may expose $pattern_label"
        return 1
    fi

    ok "$label does not expose $pattern_label"
    return 0
}

scan_output_file() {
    label="$1"
    file="$2"

    [ -s "$file" ] || { warn "$label output is empty"; return 0; }

    scan_regex "$label" "$file" "raw proxy URL" '(vless|vmess|trojan|ssr?)://'
    scan_regex "$label" "$file" "UUID-like value" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    scan_regex "$label" "$file" "SOCKS password variable" '(XRAY_SOCKS_PASS|SOCKS_PASS|SOCKS_PASSWORD)'
    scan_regex "$label" "$file" "generic secret assignment" '(^|[^A-Za-z0-9_])(password|passwd|token|secret|private_key)[[:space:]]*[:=]'
    scan_regex "$label" "$file" "proxy credentials in URL" '://[^[:space:]/]+:[^[:space:]@]+@'
}

run_checks() {
    mkdir -p "$TMP_ROOT"

    echo "== Privacy check =="
    echo "Temporary directory: $TMP_ROOT"
    echo "This checker does not print captured diagnostic output."
    echo

    if have_cmd xray-go; then
        capture_command "xray-go summary" "$TMP_ROOT/xray-go-summary.out" xray-go summary
        capture_command "xray-go version" "$TMP_ROOT/xray-go-version.out" xray-go version
        capture_command "xray-go doctor --support" "$TMP_ROOT/xray-go-doctor-support.out" xray-go doctor --support
    else
        warn "xray-go command not found; skipping xray-go checks"
    fi

    if have_cmd vless-go-doctor; then
        capture_command "vless-go-doctor" "$TMP_ROOT/vless-go-doctor.out" vless-go-doctor
    else
        warn "vless-go-doctor command not found; skipping direct doctor check"
    fi

    echo
    echo "== Pattern scan =="
    for file in "$TMP_ROOT"/*.out; do
        [ -e "$file" ] || continue
        label="$(basename "$file" .out)"
        scan_output_file "$label" "$file"
    done

    echo
    echo "== Result =="
    echo "OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"

    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo "Privacy check failed. Captured outputs are removed automatically."
        exit 2
    fi

    echo "Privacy check passed. Captured outputs are removed automatically."
}

case "${1:-}" in
    ""|--run|run)
        run_checks
        ;;
    -h|--help|help)
        cat <<'USAGE'
vless-go-privacy-check - read-only support-output privacy scanner

Usage:
  vless-go-privacy-check

Scans captured output from:
  xray-go summary
  xray-go version
  xray-go doctor --support
  vless-go-doctor

It checks for high-risk patterns such as raw VLESS/proxy URLs, UUID-like values,
SOCKS password variables, generic secret assignments, and credentials in URLs.
Captured output is stored only in a temporary directory and removed on exit.
USAGE
        ;;
    *)
        echo "Usage: vless-go-privacy-check" >&2
        exit 2
        ;;
esac
