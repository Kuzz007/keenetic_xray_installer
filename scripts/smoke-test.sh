#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FAILURES=0
WARNINGS=0

info() { printf '%s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

check_file_exists() {
    path="$1"
    if [ -f "$ROOT_DIR/$path" ]; then
        ok "exists: $path"
    else
        fail "missing: $path"
    fi
}

check_syntax() {
    path="$1"
    if [ ! -f "$ROOT_DIR/$path" ]; then
        fail "syntax skipped, missing: $path"
        return 0
    fi

    if sh -n "$ROOT_DIR/$path"; then
        ok "sh -n: $path"
    else
        fail "sh -n failed: $path"
    fi
}

check_contains() {
    path="$1"
    pattern="$2"
    label="$3"
    if grep -q "$pattern" "$ROOT_DIR/$path" 2>/dev/null; then
        ok "$label"
    else
        fail "$label"
    fi
}

check_not_contains() {
    path="$1"
    pattern="$2"
    label="$3"
    if grep -q "$pattern" "$ROOT_DIR/$path" 2>/dev/null; then
        fail "$label"
    else
        ok "$label"
    fi
}

check_executable_hint() {
    path="$1"
    if [ ! -f "$ROOT_DIR/$path" ]; then
        warn "executable check skipped, missing: $path"
        return 0
    fi

    if [ -x "$ROOT_DIR/$path" ]; then
        ok "executable in checkout: $path"
    else
        warn "not executable in checkout: $path"
    fi
}

info "== Required top-level installers =="
for path in \
    xray_vless_failover_auto_latest.sh \
    xray_vless_failover_go.sh \
    xray_vless_failover_minimal_go.sh \
    xray_vless_failover_auto.sh \
    xray_vless_failover.sh \
    xray_vless_failover_minimal.sh \
    xray_vless_go_watchdog_install.sh
    do
        check_file_exists "$path"
        check_syntax "$path"
    done

info ""
info "== Architecture guardrails =="
check_contains xray_vless_failover_go.sh 'detect_entware_arch' "Full Go installer detects Entware architecture"
check_contains xray_vless_failover_go.sh 'asset_name_for_arch' "Full Go installer maps architecture to Go asset"
check_contains xray_vless_failover_go.sh 'xray-failover-go-linux-mipsle' "Full Go installer supports mipsle resolver asset"
check_not_contains xray_vless_failover_go.sh 'GO_BINARY_URL="\${GO_BINARY_URL:-https://github.com/.*/xray-failover-go-linux-arm64}' "Full Go installer does not default to arm64-only resolver URL"
check_contains scripts/xray-go-installer-update.sh 'asset_name_for_arch' "Go updater maps architecture to Go asset"
check_contains xray_vless_failover_minimal_go.sh 'asset_name_for_arch' "Minimal Go installer maps architecture to Go asset"

info ""
info "== Helper scripts syntax =="
for file in "$ROOT_DIR"/scripts/*.sh; do
    [ -e "$file" ] || continue
    rel="scripts/$(basename "$file")"
    check_syntax "$rel"
done

info ""
info "== Packaging maintainer scripts syntax =="
for path in \
    packaging/entware/failover-go/postinst \
    packaging/entware/failover-go/prerm
    do
        check_file_exists "$path"
        check_syntax "$path"
    done

info ""
info "== Runtime helper executable bits =="
info "Executable bits are warnings because install/update/package flows chmod helpers during deployment."
for path in \
    scripts/xray-go.sh \
    scripts/xray-go-installer-update.sh \
    scripts/failover-go.sh \
    scripts/vless-go-update.sh \
    scripts/vless-go-failover.sh \
    scripts/vless-go-auto-update.sh \
    scripts/vless-go-watchdog.sh \
    scripts/vless-go-history.sh \
    scripts/vless-go-cleanup.sh \
    scripts/vless-go-recover.sh \
    scripts/vless-go-doctor.sh \
    scripts/vless-go-xray-core-update.sh \
    scripts/vless-go-web-install.sh \
    scripts/build-entware-ipk.sh
    do
        check_executable_hint "$path"
    done

info ""
info "== Summary =="
if [ "$FAILURES" -eq 0 ]; then
    ok "smoke test passed with $WARNINGS warning(s)"
    exit 0
fi

fail "smoke test failed: $FAILURES issue(s), $WARNINGS warning(s)"
exit 1
