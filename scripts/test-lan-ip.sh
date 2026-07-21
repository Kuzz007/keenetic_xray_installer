#!/bin/sh
# Tests for scripts/vless-go-lan-ip.sh.
#
# ndmc and ip are stubbed through PATH, so this runs anywhere - no router
# needed. The point is the contract: a valid private IPv4 or a clean failure,
# never a silently invented loopback.
set -u

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
LIB="$ROOT_DIR/scripts/vless-go-lan-ip.sh"
FAILURES=0

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT INT TERM
REAL_PATH="$PATH"

ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# shellcheck source=scripts/vless-go-lan-ip.sh
. "$LIB"

expect_valid() {
    if vless_go_lan_ip_valid "$1"; then ok "valid: $1"; else fail "expected valid: $1"; fi
}

expect_invalid() {
    if vless_go_lan_ip_valid "$1"; then fail "expected invalid: $1"; else ok "invalid: $1"; fi
}

# Stub ndmc with a canned "show running-config" / "show interface" response.
make_ndmc_stub() {
    cat > "$STUB_DIR/ndmc" <<STUB
#!/bin/sh
case "\$2" in
    "show running-config") cat <<'CONFIG'
$1
CONFIG
    ;;
    *) exit 1 ;;
esac
STUB
    chmod +x "$STUB_DIR/ndmc"
}

# Stub out the probes entirely, so a real ndmc or an `ip` command on the build
# machine cannot leak a host address into the result.
clear_stubs() {
    rm -f "$STUB_DIR/ndmc" 2>/dev/null || true
    for stub in ndmc ip; do
        printf '#!/bin/sh\nexit 1\n' > "$STUB_DIR/$stub"
        chmod +x "$STUB_DIR/$stub"
    done
}

# The stub dir shadows ndmc/ip but keeps awk, sed and tr reachable.
detect_isolated() (
    PATH="$STUB_DIR:$REAL_PATH"
    export PATH
    detect_router_lan_ip 2>/dev/null
)

echo "== address validation =="
expect_valid 192.168.1.1
expect_valid 10.0.0.1
expect_valid 172.16.0.1
expect_valid 172.31.255.254
expect_invalid 172.32.0.1
expect_invalid 8.8.8.8
expect_invalid 127.0.0.1
expect_invalid ''
expect_invalid 192.168.1.1/24
expect_invalid '192.168.1.1 255.255.255.0'
expect_invalid 192.168.1
expect_invalid 192.168.1.256
expect_invalid 192.168.1.1.1
expect_invalid not.an.ip.addr

echo ""
echo "== detection =="

clear_stubs
make_ndmc_stub "interface Bridge0
    ip address 192.168.7.1 255.255.255.0
interface GigabitEthernet1
    ip address 10.64.2.33 255.255.255.0"
got="$(detect_isolated || true)"
if [ "$got" = "192.168.7.1" ]; then ok "reads Bridge0 from running-config"; else fail "Bridge0 detection returned '$got'"; fi

# A 10.x LAN is legitimate; the old doctor path rejected it and fell back to
# loopback.
clear_stubs
make_ndmc_stub "interface Bridge0
    ip address 10.0.0.1 255.255.255.0"
got="$(detect_isolated || true)"
if [ "$got" = "10.0.0.1" ]; then ok "accepts a 10.x LAN"; else fail "10.x LAN returned '$got'"; fi

# The WAN block must never win, even though its address is private.
clear_stubs
make_ndmc_stub "interface GigabitEthernet1
    ip address 10.64.2.33 255.255.255.0
interface Home
    ip address 192.168.99.1 255.255.255.0"
got="$(detect_isolated || true)"
if [ "$got" = "192.168.99.1" ]; then ok "prefers LAN over a private WAN address"; else fail "WAN-vs-LAN returned '$got'"; fi

echo ""
echo "== failure contract =="

# Nothing to detect from and no store: must fail loudly, print nothing.
clear_stubs
got="$(ROUTER_IP_STORE="$STUB_DIR/missing" detect_isolated || true)"
if [ -z "$got" ]; then ok "prints nothing when detection fails"; else fail "expected no output, got '$got'"; fi
if PATH="$STUB_DIR:$REAL_PATH" ROUTER_IP_STORE="$STUB_DIR/missing" detect_router_lan_ip >/dev/null 2>&1; then
    fail "expected non-zero exit when detection fails"
else
    ok "returns non-zero when detection fails"
fi

# Never invent loopback.
if [ "$got" = "127.0.0.1" ]; then fail "fell back to loopback"; else ok "never falls back to loopback"; fi

echo ""
echo "== stored fallback =="

clear_stubs
printf '192.168.5.1\n' > "$STUB_DIR/store"
got="$(ROUTER_IP_STORE="$STUB_DIR/store" detect_isolated || true)"
if [ "$got" = "192.168.5.1" ]; then ok "uses stored value when probing fails"; else fail "stored fallback returned '$got'"; fi

# A poisoned store must not be trusted.
printf '8.8.8.8\n' > "$STUB_DIR/store"
got="$(ROUTER_IP_STORE="$STUB_DIR/store" detect_isolated || true)"
if [ -z "$got" ]; then ok "rejects a poisoned store"; else fail "poisoned store returned '$got'"; fi

echo ""
echo "== operator override =="

clear_stubs
got="$(PROXY_UPSTREAM_HOST=192.168.42.1 detect_isolated || true)"
if [ "$got" = "192.168.42.1" ]; then ok "honours PROXY_UPSTREAM_HOST"; else fail "override returned '$got'"; fi

echo ""
echo "== upstream read-back =="

clear_stubs
make_ndmc_stub "interface Proxy0
    proxy upstream 192.168.1.1 10808
    proxy protocol socks5"
got="$(PATH="$STUB_DIR:$REAL_PATH" proxy0_current_upstream Proxy0 2>/dev/null || true)"
if [ "$got" = "192.168.1.1" ]; then ok "reads back the applied upstream"; else fail "read-back returned '$got'"; fi

PATH="$REAL_PATH"
echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "== lan-ip tests passed =="
    exit 0
fi
echo "== lan-ip tests failed: $FAILURES =="
exit 1
