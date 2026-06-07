#!/bin/sh
set -u

# xray-go-safety-check - read-only safety/rollback boundary checker.
#
# This helper does not update, delete, restart, or rewrite working files. It
# snapshots important direct-install files, runs isolated failure simulations in
# /tmp, then confirms the working files did not change.

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
MANIFEST_FILE="${MANIFEST_FILE:-$XRAY_DIR/xray-go.manifest}"
DIRECT_INSTALL_PLAN="${DIRECT_INSTALL_PLAN:-$XRAY_DIR/xray-go.direct-install.plan}"
DIRECT_INIT_PLAN="${DIRECT_INIT_PLAN:-$XRAY_DIR/xray-go.direct-init.plan}"
STAGE_DIR="${XRAY_GO_DIRECT_STAGE_DIR:-/opt/tmp/xray-go-direct-install}"
HELPER_INDEX="${HELPER_INDEX:-$STAGE_DIR/xray-go.helpers.index}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main}"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMP_DIR="/tmp/xray-go-safety-check.$$"
SNAP_BEFORE="$TMP_DIR/snapshot.before"
SNAP_AFTER="$TMP_DIR/snapshot.after"

cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ok() {
    OK_COUNT=$((OK_COUNT + 1))
    echo "[OK] $*"
}

warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo "[WARN] $*"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] $*"
}

sha256_file() {
    file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

manifest_value() {
    key="$1"
    sed -n 's/^'"$key"'="\(.*\)"$/\1/p' "$MANIFEST_FILE" 2>/dev/null | tail -n 1
}

file_stamp() {
    file="$1"
    if [ ! -e "$file" ]; then
        echo "missing"
        return 0
    fi
    if stat -c '%s:%Y' "$file" >/dev/null 2>&1; then
        stat -c '%s:%Y' "$file" 2>/dev/null
    else
        ls -ln "$file" 2>/dev/null | awk '{print $5":"$6":"$7":"$8}'
    fi
}

snapshot_paths() {
    out="$1"
    : > "$out"
    for path in \
        /opt/bin/xray-failover-go \
        /opt/bin/xray-failover-go.bak.direct \
        /opt/bin/xray-go \
        /opt/bin/xray-go-manifest \
        /opt/bin/xray-go-direct-full \
        /opt/bin/xray-go-direct-uninstall \
        /opt/bin/vless-go-update \
        /opt/bin/vless-go-auto-update \
        /opt/bin/vless-go-failover \
        /opt/bin/vless-go-history \
        /opt/bin/vless-go-cleanup \
        /opt/bin/vless-go-recover \
        /opt/bin/vless-go-socks-auth \
        /opt/bin/vless-go-doctor \
        /opt/bin/vless-go-doctor-summary \
        /opt/bin/vless-go-privacy-check \
        /opt/bin/vless-go-xray-core-update \
        /opt/bin/vless-go-watchdog \
        /opt/bin/failover-go \
        /opt/libexec/vless-go-lock.sh \
        /opt/etc/init.d/S26vless-go-watchdog \
        "$MANIFEST_FILE" \
        "$DIRECT_INSTALL_PLAN" \
        "$DIRECT_INIT_PLAN"; do
        if [ -e "$path" ]; then
            printf '%s|exists|%s|%s\n' "$path" "$(sha256_file "$path")" "$(file_stamp "$path")" >> "$out"
        else
            printf '%s|missing||missing\n' "$path" >> "$out"
        fi
    done
}

compare_snapshots() {
    if cmp -s "$SNAP_BEFORE" "$SNAP_AFTER"; then
        ok "working direct-install files unchanged after failure simulations"
        return 0
    fi

    fail "working direct-install files changed during safety-check simulation"
    echo "Changed paths:"
    awk -F'|' 'NR==FNR { before[$1]=$0; next } before[$1] != $0 { print "  " $1 }' "$SNAP_BEFORE" "$SNAP_AFTER" 2>/dev/null || true
    return 1
}

fetch_url() {
    url="$1"
    output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$output" "$url"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
        return $?
    fi
    return 127
}

run_isolated_bad_download_test() {
    bad_url="$RAW_BASE/__safety_check_missing__/no-such-file.$$"
    bad_out="$TMP_DIR/bad-download.out"

    if fetch_url "$bad_url" "$bad_out" >/dev/null 2>&1; then
        fail "isolated bad download unexpectedly succeeded"
        return 1
    fi

    ok "isolated bad download failed before touching working files"
    return 0
}

run_isolated_shell_syntax_test() {
    broken="$TMP_DIR/broken-helper.sh"
    cat > "$broken" <<'BROKEN'
#!/bin/sh
if [ "x" = "x" ]; then
echo broken
BROKEN

    if sh -n "$broken" >/dev/null 2>&1; then
        fail "isolated broken shell helper unexpectedly passed sh -n"
        return 1
    fi

    ok "isolated broken shell helper rejected by sh -n"
    return 0
}

run_atomic_tmp_install_test() {
    target="$TMP_DIR/target-file"
    tmp="$TMP_DIR/target-file.$$"
    printf 'old\n' > "$target"
    old_sha="$(sha256_file "$target")"

    printf 'new\n' > "$tmp"
    if ! sh -n "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" 2>/dev/null || true
    fi

    new_sha="$(sha256_file "$target")"
    if [ "$old_sha" = "$new_sha" ]; then
        ok "isolated failed install leaves previous target content unchanged"
    else
        fail "isolated failed install changed previous target content"
    fi
}

check_manifest_binary_match() {
    manifest_mode="$(manifest_value INSTALL_MODE)"
    manifest_binary="$(manifest_value BINARY_PATH)"
    manifest_sha="$(manifest_value BINARY_SHA256)"

    if [ ! -s "$MANIFEST_FILE" ]; then
        fail "manifest missing: $MANIFEST_FILE"
        return 1
    fi
    ok "manifest present: $MANIFEST_FILE"

    if [ "$manifest_mode" = "direct" ]; then
        ok "manifest install mode: direct"
    else
        warn "manifest install mode is not direct: ${manifest_mode:-unknown}"
    fi

    if [ -n "$manifest_binary" ] && [ -x "$manifest_binary" ]; then
        ok "manifest binary executable: $manifest_binary"
    else
        fail "manifest binary missing or not executable: ${manifest_binary:-unknown}"
        return 1
    fi

    current_sha="$(sha256_file "$manifest_binary")"
    if [ -n "$manifest_sha" ] && [ "$current_sha" = "$manifest_sha" ]; then
        ok "manifest binary sha256 matches current binary"
    else
        fail "manifest binary sha256 mismatch"
    fi
}

check_safety_markers() {
    if [ -s "$DIRECT_INSTALL_PLAN" ]; then
        ok "direct-install plan present: $DIRECT_INSTALL_PLAN"
    else
        warn "direct-install plan missing: $DIRECT_INSTALL_PLAN"
    fi

    if [ -s "$DIRECT_INIT_PLAN" ]; then
        ok "direct-init plan present: $DIRECT_INIT_PLAN"
    else
        warn "direct-init plan missing: $DIRECT_INIT_PLAN"
    fi

    if [ -s "$HELPER_INDEX" ]; then
        ok "helper index present: $HELPER_INDEX"
    else
        warn "helper index missing: $HELPER_INDEX"
    fi

    if [ -x /opt/bin/xray-go-direct-full ] && grep -q 'Skipping Go resolver download' /opt/bin/xray-go-direct-full 2>/dev/null; then
        ok "direct full update supports binary reuse fallback"
    else
        warn "direct full update binary reuse fallback not detected"
    fi
}

mkdir -p "$TMP_DIR" || { echo "ERROR: cannot create $TMP_DIR" >&2; exit 1; }

cat <<EOF
== Direct safety check ==
This check is read-only for working files.
Temporary directory: $TMP_DIR
EOF

echo
snapshot_paths "$SNAP_BEFORE"
check_manifest_binary_match
check_safety_markers

echo
echo "== Failure simulations =="
run_isolated_bad_download_test
run_isolated_shell_syntax_test
run_atomic_tmp_install_test
snapshot_paths "$SNAP_AFTER"
compare_snapshots

echo
echo "== Result =="
echo "OK=$OK_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
