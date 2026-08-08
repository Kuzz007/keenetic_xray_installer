#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 AMNEZIAWG_GO AWG_TOOLS" >&2
    exit 2
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: runtime smoke test must run as root" >&2
    exit 1
fi

runtime="$1"
tools="$2"
interface="awgprobe0"

for path in "$runtime" "$tools"; do
    if [ ! -x "$path" ]; then
        echo "ERROR: executable not found: $path" >&2
        exit 1
    fi
done
for command_name in ip awk grep; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    fi
done
if ip link show "$interface" >/dev/null 2>&1; then
    echo "ERROR: probe interface already exists: $interface" >&2
    exit 1
fi

probe_tmp="$(mktemp -d "${TMPDIR:-/tmp}/keenetic-awg-smoke.XXXXXX")"
runtime_pid=""
cleanup() {
    if [ -n "$runtime_pid" ]; then
        kill "$runtime_pid" >/dev/null 2>&1 || true
        wait "$runtime_pid" >/dev/null 2>&1 || true
    fi
    ip link delete "$interface" >/dev/null 2>&1 || true
    rm -rf "$probe_tmp"
}
trap cleanup 0 1 2 15

LOG_LEVEL=error "$runtime" -f "$interface" >"$probe_tmp/runtime.log" 2>&1 &
runtime_pid=$!

attempt=0
while [ ! -S "/var/run/amneziawg/$interface.sock" ]; do
    if ! kill -0 "$runtime_pid" >/dev/null 2>&1; then
        echo "ERROR: amneziawg-go exited before opening UAPI" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        echo "ERROR: timed out waiting for amneziawg-go UAPI" >&2
        exit 1
    fi
    sleep 0.1
done

umask 077
private_key="$("$tools" genkey)"
public_key="$(printf '%s\n' "$private_key" | "$tools" pubkey)"
cat >"$probe_tmp/awg.conf" <<EOF
[Interface]
PrivateKey = $private_key
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
PublicKey = $public_key
AllowedIPs = 10.255.255.1/32
Endpoint = 127.0.0.1:9
EOF

"$tools" setconf "$interface" "$probe_tmp/awg.conf"
"$tools" showconf "$interface" >"$probe_tmp/show.conf"
grep -q '^Jc = 4$' "$probe_tmp/show.conf"
grep -q '^S4 = 48$' "$probe_tmp/show.conf"
grep -q '^H4 = 1300-1399$' "$probe_tmp/show.conf"

sleep 1
rss_kb="$(awk '/^VmRSS:/ { print $2 }' "/proc/$runtime_pid/status")"
hwm_kb="$(awk '/^VmHWM:/ { print $2 }' "/proc/$runtime_pid/status")"
threads="$(awk '/^Threads:/ { print $2 }' "/proc/$runtime_pid/status")"
if [ -z "$rss_kb" ] || [ -z "$hwm_kb" ] || [ -z "$threads" ]; then
    echo "ERROR: failed to read runtime memory metrics" >&2
    exit 1
fi

printf 'AWG_PROBE_RSS_KB=%s\n' "$rss_kb"
printf 'AWG_PROBE_HWM_KB=%s\n' "$hwm_kb"
printf 'AWG_PROBE_THREADS=%s\n' "$threads"
printf 'AWG_PROBE_CONFIG=awg2-ok\n'

cleanup
runtime_pid=""
trap - 0 1 2 15
