#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FAILURES=0

info() { printf '%s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
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

check_executable() {
    path="$1"
    if [ ! -f "$ROOT_DIR/$path" ]; then
        fail "executable check skipped, missing: $path"
        return 0
    fi

    if [ -x "$ROOT_DIR/$path" ]; then
        ok "executable: $path"
    else
        fail "not executable: $path"
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
        check_executable "$path"
    done

info ""
info "== Summary =="
if [ "$FAILURES" -eq 0 ]; then
    ok "smoke test passed"
    exit 0
fi

fail "smoke test failed: $FAILURES issue(s)"
exit 1
