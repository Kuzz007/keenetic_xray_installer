#!/bin/sh
set -eu

PROBE_INTERFACE="${AWG_PROBE_INTERFACE:-awgprobe0}"
PROBE_SECONDS=5
PROBE_MIN_AVAILABLE_KB=24576
RUNTIME_PATH=""
TOOLS_PATH=""
CONFIRMED=no
PROBE_ARCH=""
PROBE_TMP=""
RUNTIME_PID=""
CLEANUP_ARMED=no
PROBE_SOCKET="/var/run/amneziawg/$PROBE_INTERFACE.sock"

usage() {
    cat <<'EOF'
Keenetic AmneziaWG live memory probe

Usage:
  keenetic-awg-live-probe.sh preflight
  keenetic-awg-live-probe.sh run --yes \
    --runtime PATH_TO_AMNEZIAWG_GO \
    --tools PATH_TO_AWG_TOOLS \
    [--seconds 1..30] [--min-available-kb 16384..1048576]

preflight is read-only. run creates only the isolated awgprobe0 interface with
no address and no route, measures it, then removes it. Proxy0, Xray, active
primary/backup state and stored VPN profiles are not changed.
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

available_memory_kb() {
    awk '
        /^MemAvailable:/ { available = $2 }
        /^MemFree:/ { free = $2 }
        /^Buffers:/ { buffers = $2 }
        /^Cached:/ { cached = $2 }
        END {
            if (available > 0) print available
            else print free + buffers + cached
        }
    ' /proc/meminfo
}

detect_probe_arch() {
    probe_uname_arch="$(uname -m 2>/dev/null || echo unknown)"
    case "$probe_uname_arch" in
    x86_64|amd64) PROBE_ARCH=amd64 ;;
    aarch64|arm64) PROBE_ARCH=arm64 ;;
    mips|mipsel|mipsle|mipselsf|mipsel-*|mipselsf-*) PROBE_ARCH=mipsle ;;
    *) PROBE_ARCH=unsupported ;;
    esac
    printf 'AWG_PROBE_UNAME_ARCH=%s\n' "$probe_uname_arch"
    printf 'AWG_PROBE_ARCH=%s\n' "$PROBE_ARCH"
}

run_preflight() {
    preflight_failures=0
    detect_probe_arch

    if [ "$PROBE_ARCH" = unsupported ]; then
        printf 'AWG_PROBE_ARCH_SUPPORTED=no\n'
        preflight_failures=$((preflight_failures + 1))
    else
        printf 'AWG_PROBE_ARCH_SUPPORTED=yes\n'
    fi

    for probe_command in id uname awk grep tr ip mktemp sha256sum cmp cat df rm sleep; do
        if command -v "$probe_command" >/dev/null 2>&1; then
            :
        else
            printf 'AWG_PROBE_MISSING_COMMAND=%s\n' "$probe_command"
            preflight_failures=$((preflight_failures + 1))
        fi
    done

    probe_uid="$(id -u 2>/dev/null || echo unknown)"
    printf 'AWG_PROBE_UID=%s\n' "$probe_uid"
    if [ "$probe_uid" != 0 ]; then
        preflight_failures=$((preflight_failures + 1))
    fi

    if [ -c /dev/net/tun ] || [ -e /dev/net/tun ]; then
        printf 'AWG_PROBE_TUN=present\n'
    else
        printf 'AWG_PROBE_TUN=missing\n'
        preflight_failures=$((preflight_failures + 1))
    fi

    if command -v ip >/dev/null 2>&1; then
        if ip link show "$PROBE_INTERFACE" >/dev/null 2>&1; then
            printf 'AWG_PROBE_INTERFACE_AVAILABLE=no\n'
            preflight_failures=$((preflight_failures + 1))
        else
            printf 'AWG_PROBE_INTERFACE_AVAILABLE=yes\n'
        fi
    fi

    if [ -e "$PROBE_SOCKET" ] || [ -L "$PROBE_SOCKET" ]; then
        printf 'AWG_PROBE_SOCKET_AVAILABLE=no\n'
        preflight_failures=$((preflight_failures + 1))
    else
        printf 'AWG_PROBE_SOCKET_AVAILABLE=yes\n'
    fi

    if [ -r /proc/meminfo ]; then
        probe_available_kb="$(available_memory_kb)"
        case "$probe_available_kb" in
        ''|*[!0-9]*)
            printf 'AWG_PROBE_MEM_AVAILABLE_KB=unknown\n'
            preflight_failures=$((preflight_failures + 1))
            ;;
        *) printf 'AWG_PROBE_MEM_AVAILABLE_KB=%s\n' "$probe_available_kb" ;;
        esac
    else
        printf 'AWG_PROBE_MEM_AVAILABLE_KB=unknown\n'
        preflight_failures=$((preflight_failures + 1))
    fi

    if command -v df >/dev/null 2>&1 && [ -d /opt ]; then
        probe_opt_available_kb="$(df -Pk /opt 2>/dev/null | awk 'NR == 2 { print $4 }')"
        [ -n "$probe_opt_available_kb" ] || probe_opt_available_kb=unknown
        printf 'AWG_PROBE_OPT_AVAILABLE_KB=%s\n' "$probe_opt_available_kb"
    else
        printf 'AWG_PROBE_OPT_AVAILABLE_KB=unknown\n'
    fi

    if [ "$preflight_failures" -ne 0 ]; then
        printf 'AWG_PROBE_PREFLIGHT=fail\n'
        return 1
    fi
    printf 'AWG_PROBE_PREFLIGHT=pass\n'
}

verify_binary() {
    verify_path="$1"
    verify_label="$2"
    [ -f "$verify_path" ] || fail "$verify_label binary not found: $verify_path"
    [ -x "$verify_path" ] || fail "$verify_label binary is not executable: $verify_path"
    [ -f "$verify_path.sha256" ] || fail "$verify_label SHA256 sidecar not found: $verify_path.sha256"

    case "$verify_path" in
    *"linux-$PROBE_ARCH") ;;
    *) fail "$verify_label filename does not match detected architecture $PROBE_ARCH" ;;
    esac

    verify_expected="$(tr -d '[:space:]' <"$verify_path.sha256")"
    case "$verify_expected" in
    ''|*[!0-9A-Fa-f]*) fail "$verify_label SHA256 sidecar is invalid" ;;
    esac
    [ "${#verify_expected}" -eq 64 ] || fail "$verify_label SHA256 sidecar must contain 64 hex characters"
    verify_actual="$(sha256sum "$verify_path" | awk '{ print $1 }')"
    [ "$verify_actual" = "$verify_expected" ] || fail "$verify_label SHA256 mismatch"
    printf 'AWG_PROBE_%s_SHA256=ok\n' "$verify_label"
}

snapshot_routes() {
    snapshot_route_file="$1"
    snapshot_rule_file="$2"
    if ! ip route show table all >"$snapshot_route_file" 2>/dev/null; then
        ip route show >"$snapshot_route_file"
    fi
    if ! ip rule show >"$snapshot_rule_file" 2>/dev/null; then
        : >"$snapshot_rule_file"
    fi
}

managed_state_paths() {
    printf '%s\n' \
        /opt/etc/xray/config.json \
        /opt/etc/xray/minimal-go-active \
        /opt/etc/xray/vless-go.active
}

snapshot_managed_state() {
    state_index=0
    for state_path in $(managed_state_paths); do
        state_index=$((state_index + 1))
        if [ -e "$state_path" ]; then
            printf 'present\n' >"$PROBE_TMP/state.$state_index.marker"
            sha256sum "$state_path" | awk '{ print $1 }' >"$PROBE_TMP/state.$state_index.sha256"
        else
            printf 'absent\n' >"$PROBE_TMP/state.$state_index.marker"
        fi
    done
}

verify_managed_state() {
    state_index=0
    for state_path in $(managed_state_paths); do
        state_index=$((state_index + 1))
        state_marker="$(cat "$PROBE_TMP/state.$state_index.marker")"
        if [ "$state_marker" = present ]; then
            [ -e "$state_path" ] || return 1
            state_expected="$(cat "$PROBE_TMP/state.$state_index.sha256")"
            state_actual="$(sha256sum "$state_path" | awk '{ print $1 }')"
            [ "$state_actual" = "$state_expected" ] || return 1
        else
            [ ! -e "$state_path" ] || return 1
        fi
    done
}

stop_probe() {
    stop_failed=0
    if [ -n "$RUNTIME_PID" ]; then
        kill "$RUNTIME_PID" >/dev/null 2>&1 || true
        stop_attempt=0
        while kill -0 "$RUNTIME_PID" >/dev/null 2>&1; do
            stop_attempt=$((stop_attempt + 1))
            if [ "$stop_attempt" -ge 5 ]; then
                kill -9 "$RUNTIME_PID" >/dev/null 2>&1 || true
                break
            fi
            sleep 1
        done
        wait "$RUNTIME_PID" >/dev/null 2>&1 || true
        RUNTIME_PID=""
    fi

    ip link delete "$PROBE_INTERFACE" >/dev/null 2>&1 || true
    rm -f "$PROBE_SOCKET"

    if ip link show "$PROBE_INTERFACE" >/dev/null 2>&1; then
        printf 'ERROR: failed to remove probe interface %s\n' "$PROBE_INTERFACE" >&2
        stop_failed=1
    fi
    if [ -e "$PROBE_SOCKET" ] || [ -L "$PROBE_SOCKET" ]; then
        printf 'ERROR: failed to remove probe socket %s\n' "$PROBE_SOCKET" >&2
        stop_failed=1
    fi
    [ "$stop_failed" -eq 0 ]
}

cleanup() {
    cleanup_status=0
    if [ "$CLEANUP_ARMED" = yes ]; then
        stop_probe || cleanup_status=1
    fi
    if [ -n "$PROBE_TMP" ] && [ -d "$PROBE_TMP" ]; then
        case "$PROBE_TMP" in
        */keenetic-awg-live.*) rm -rf "$PROBE_TMP" ;;
        *)
            printf 'ERROR: refusing to remove unexpected probe temp path %s\n' "$PROBE_TMP" >&2
            cleanup_status=1
            ;;
        esac
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        trap - 0
        exit 1
    fi
}

run_probe() {
    run_preflight || fail "preflight failed; no interface was created"
    [ "$CONFIRMED" = yes ] || fail "run requires explicit --yes"
    verify_binary "$RUNTIME_PATH" RUNTIME
    verify_binary "$TOOLS_PATH" TOOLS

    probe_runtime_version="$("$RUNTIME_PATH" --version 2>/dev/null)" || fail "amneziawg-go cannot execute"
    printf '%s\n' "$probe_runtime_version" | grep -F "linux-$PROBE_ARCH" >/dev/null || \
        fail "amneziawg-go output does not match detected architecture $PROBE_ARCH"
    probe_tools_version="$("$TOOLS_PATH" --version 2>/dev/null)" || fail "awg tools cannot execute"
    printf '%s\n' "$probe_tools_version" | grep -F 'amneziawg-tools v3.' >/dev/null || \
        fail "unexpected awg tools version"
    printf 'AWG_PROBE_EXEC=ok\n'

    probe_available_before="$(available_memory_kb)"
    if [ "$probe_available_before" -lt "$PROBE_MIN_AVAILABLE_KB" ]; then
        fail "available memory ${probe_available_before} KB is below safety floor ${PROBE_MIN_AVAILABLE_KB} KB"
    fi

    umask 077
    PROBE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/keenetic-awg-live.XXXXXX")"
    case "$PROBE_TMP" in
    */keenetic-awg-live.*) ;;
    *) fail "mktemp returned an unexpected path" ;;
    esac
    snapshot_routes "$PROBE_TMP/routes.before" "$PROBE_TMP/rules.before"
    snapshot_managed_state
    CLEANUP_ARMED=yes
    trap cleanup 0
    trap 'exit 130' 1 2 15

    LOG_LEVEL=error "$RUNTIME_PATH" -f "$PROBE_INTERFACE" >"$PROBE_TMP/runtime.log" 2>&1 &
    RUNTIME_PID=$!

    probe_attempt=0
    while [ ! -S "$PROBE_SOCKET" ]; do
        if ! kill -0 "$RUNTIME_PID" >/dev/null 2>&1; then
            fail "amneziawg-go exited before opening UAPI"
        fi
        probe_attempt=$((probe_attempt + 1))
        [ "$probe_attempt" -lt 15 ] || fail "timed out waiting for amneziawg-go UAPI"
        sleep 1
    done
    ip link show "$PROBE_INTERFACE" >/dev/null 2>&1 || fail "probe interface was not created"

    probe_private_key="$("$TOOLS_PATH" genkey)"
    probe_public_key="$(printf '%s\n' "$probe_private_key" | "$TOOLS_PATH" pubkey)"
    cat >"$PROBE_TMP/awg.conf" <<EOF
[Interface]
PrivateKey = $probe_private_key
Jc = 4
Jmin = 40
Jmax = 70
S1 = 12
S2 = 24
S3 = 36
S4 = 48
H1 = 1000-1099
H2 = 1100-1199
H3 = 1200-1299
H4 = 1300-1399

[Peer]
PublicKey = $probe_public_key
AllowedIPs = 10.255.255.1/32
Endpoint = 127.0.0.1:9
EOF

    "$TOOLS_PATH" setconf "$PROBE_INTERFACE" "$PROBE_TMP/awg.conf"
    ip link set dev "$PROBE_INTERFACE" up
    "$TOOLS_PATH" showconf "$PROBE_INTERFACE" >"$PROBE_TMP/show.conf"
    grep -q '^Jc = 4$' "$PROBE_TMP/show.conf"
    grep -q '^S4 = 48$' "$PROBE_TMP/show.conf"
    grep -q '^H4 = 1300-1399$' "$PROBE_TMP/show.conf"

    sleep "$PROBE_SECONDS"
    probe_runtime_rss="$(awk '/^VmRSS:/ { print $2 }' "/proc/$RUNTIME_PID/status")"
    probe_runtime_hwm="$(awk '/^VmHWM:/ { print $2 }' "/proc/$RUNTIME_PID/status")"
    probe_runtime_threads="$(awk '/^Threads:/ { print $2 }' "/proc/$RUNTIME_PID/status")"
    probe_available_during="$(available_memory_kb)"
    [ -n "$probe_runtime_rss" ] || fail "runtime RSS is unavailable"
    [ -n "$probe_runtime_hwm" ] || fail "runtime HWM is unavailable"
    [ -n "$probe_runtime_threads" ] || fail "runtime thread count is unavailable"

    stop_probe || fail "probe cleanup failed"
    snapshot_routes "$PROBE_TMP/routes.after" "$PROBE_TMP/rules.after"
    cmp -s "$PROBE_TMP/routes.before" "$PROBE_TMP/routes.after" || fail "route table changed during isolated probe"
    cmp -s "$PROBE_TMP/rules.before" "$PROBE_TMP/rules.after" || fail "routing rules changed during isolated probe"
    verify_managed_state || fail "managed Xray/active-slot state changed during probe"
    probe_available_after="$(available_memory_kb)"
    probe_available_delta=$((probe_available_before - probe_available_during))

    printf 'AWG_PROBE_SECONDS=%s\n' "$PROBE_SECONDS"
    printf 'AWG_PROBE_MIN_AVAILABLE_KB=%s\n' "$PROBE_MIN_AVAILABLE_KB"
    printf 'AWG_PROBE_MEM_AVAILABLE_BEFORE_KB=%s\n' "$probe_available_before"
    printf 'AWG_PROBE_MEM_AVAILABLE_DURING_KB=%s\n' "$probe_available_during"
    printf 'AWG_PROBE_MEM_AVAILABLE_AFTER_KB=%s\n' "$probe_available_after"
    printf 'AWG_PROBE_MEM_AVAILABLE_DELTA_KB=%s\n' "$probe_available_delta"
    printf 'AWG_PROBE_RUNTIME_RSS_KB=%s\n' "$probe_runtime_rss"
    printf 'AWG_PROBE_RUNTIME_HWM_KB=%s\n' "$probe_runtime_hwm"
    printf 'AWG_PROBE_RUNTIME_THREADS=%s\n' "$probe_runtime_threads"
    printf 'AWG_PROBE_ROUTE_RESTORED=yes\n'
    printf 'AWG_PROBE_RULES_RESTORED=yes\n'
    printf 'AWG_PROBE_MANAGED_STATE_RESTORED=yes\n'
    printf 'AWG_PROBE_PROXY0_TOUCHED=no\n'
    printf 'AWG_PROBE_ACTIVE_SLOT_TOUCHED=no\n'
    printf 'AWG_PROBE_HANDSHAKE=not-requested\n'
    printf 'AWG_PROBE_RESULT=pass\n'

    CLEANUP_ARMED=no
    case "$PROBE_TMP" in
    */keenetic-awg-live.*) rm -rf "$PROBE_TMP" ;;
    *) fail "refusing to remove unexpected probe temp path" ;;
    esac
    PROBE_TMP=""
    trap - 0 1 2 15
}

case "$PROBE_INTERFACE" in
''|*[!A-Za-z0-9_.-]*) fail "AWG_PROBE_INTERFACE contains unsupported characters" ;;
esac
[ "${#PROBE_INTERFACE}" -le 15 ] || fail "AWG_PROBE_INTERFACE must not exceed 15 characters"

mode="${1:-}"
[ -n "$mode" ] || { usage >&2; exit 2; }
shift

case "$mode" in
preflight)
    [ "$#" -eq 0 ] || { usage >&2; exit 2; }
    run_preflight
    ;;
run)
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --yes)
            CONFIRMED=yes
            shift
            ;;
        --runtime)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            RUNTIME_PATH="$2"
            shift 2
            ;;
        --tools)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            TOOLS_PATH="$2"
            shift 2
            ;;
        --seconds)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PROBE_SECONDS="$2"
            shift 2
            ;;
        --min-available-kb)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            PROBE_MIN_AVAILABLE_KB="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
        esac
    done
    [ -n "$RUNTIME_PATH" ] || fail "--runtime is required"
    [ -n "$TOOLS_PATH" ] || fail "--tools is required"
    case "$PROBE_SECONDS" in ''|*[!0-9]*) fail "--seconds must be an integer" ;; esac
    [ "$PROBE_SECONDS" -ge 1 ] && [ "$PROBE_SECONDS" -le 30 ] || fail "--seconds must be between 1 and 30"
    case "$PROBE_MIN_AVAILABLE_KB" in ''|*[!0-9]*) fail "--min-available-kb must be an integer" ;; esac
    [ "$PROBE_MIN_AVAILABLE_KB" -ge 16384 ] && [ "$PROBE_MIN_AVAILABLE_KB" -le 1048576 ] || \
        fail "--min-available-kb must be between 16384 and 1048576"
    run_probe
    ;;
-h|--help|help)
    usage
    ;;
*)
    usage >&2
    exit 2
    ;;
esac
