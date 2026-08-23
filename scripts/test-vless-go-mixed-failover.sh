#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/keenetic-mixed-failover.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

XRAY_DIR="$TEST_ROOT/xray"
AWG_SLOT_CMD="$TEST_ROOT/keenetic-awg-slot"
GO_UPDATE_CMD="$TEST_ROOT/vless-go-update"
HISTORY_CMD="$TEST_ROOT/missing-history"
LOCK_HELPER="$TEST_ROOT/missing-lock"
export XRAY_DIR AWG_SLOT_CMD GO_UPDATE_CMD HISTORY_CMD LOCK_HELPER
mkdir -p "$XRAY_DIR" "$XRAY_DIR/awg/profiles"

cat > "$AWG_SLOT_CMD" <<'AWG'
#!/bin/sh
set -eu
command="${1:-status}"
shift || true
slot=single
while [ "$#" -gt 0 ]; do
    case "$1" in
        --slot) slot="$2"; shift 2 ;;
        --input) shift 2 ;;
        *) shift ;;
    esac
done
case "$command" in
    import)
        mkdir -p "$XRAY_DIR/awg/profiles"
        printf '%s\n' test-profile > "$XRAY_DIR/awg/profiles/$slot.conf"
        ;;
    activate)
        if [ "${AWG_ACTIVATE_FAIL_SLOT:-}" = "$slot" ]; then exit 12; fi
        printf '{"profile_slot":"%s"}\n' "$slot" > "$XRAY_DIR/awg/runtime.json"
        ;;
    deactivate) rm -f "$XRAY_DIR/awg/runtime.json" ;;
    status) : ;;
    *) exit 2 ;;
esac
AWG
chmod +x "$AWG_SLOT_CMD"

cat > "$GO_UPDATE_CMD" <<'UPDATE'
#!/bin/sh
[ "${GO_UPDATE_FAIL:-0}" != 1 ] || exit 9
exit 0
UPDATE
chmod +x "$GO_UPDATE_CMD"

VLESS_GO_FAILOVER_LIB_ONLY=1
export VLESS_GO_FAILOVER_LIB_ONLY
# shellcheck source=/dev/null
. "$ROOT_DIR/scripts/vless-go-failover.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_line() {
    expected="$1"
    file="$2"
    actual="$(sed -n '1p' "$file" 2>/dev/null || true)"
    [ "$actual" = "$expected" ] || fail "$file is '$actual', expected '$expected'"
}

printf '%s\n' 'vless://test-primary' > "$PRIMARY_STORE"
printf '%s\n' primary > "$ACTIVE_STORE"
save_slot_type primary vless

set_awg_profile backup --input -
assert_line awg "$XRAY_DIR/vpn-slot.backup.type"
assert_line primary "$ACTIVE_STORE"
[ ! -e "$AWG_RUNTIME_STATE" ] || fail "AWG import changed runtime state"

switch_typed backup
assert_line backup "$ACTIVE_STORE"
[ -s "$AWG_RUNTIME_STATE" ] || fail "AWG switch did not create runtime state"

switch_typed primary
assert_line primary "$ACTIVE_STORE"
[ ! -e "$AWG_RUNTIME_STATE" ] || fail "VLESS switch left AWG runtime state"

switch_typed backup
export GO_UPDATE_FAIL=1
if switch_typed primary; then
    fail "failed VLESS target unexpectedly succeeded"
fi
unset GO_UPDATE_FAIL
assert_line backup "$ACTIVE_STORE"
[ -s "$AWG_RUNTIME_STATE" ] || fail "failed VLESS switch did not roll back to AWG"

export AWG_ACTIVATE_FAIL_SLOT=primary
save_slot_type primary awg
printf '%s\n' test-profile > "$AWG_PROFILE_DIR/primary.conf"
if switch_typed primary; then
    fail "failed AWG target unexpectedly succeeded"
fi
unset AWG_ACTIVATE_FAIL_SLOT
assert_line backup "$ACTIVE_STORE"
[ -s "$AWG_RUNTIME_STATE" ] || fail "failed AWG switch did not restore previous AWG"

echo "mixed failover transaction tests passed"
