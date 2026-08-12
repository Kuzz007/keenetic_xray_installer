# AmneziaWG runtime probe

This stage evaluates the upstream AmneziaWG userspace runtime before it is
included in either router bundle. It does not install or start anything on a
router.

## Pinned experimental versions

| Component | Version | Commit | License |
| --- | --- | --- | --- |
| `amneziawg-go` | `v3.0.20260805` | `08d68cdae27762c3e07f36bbb12d2bad32f81926` | MIT |
| `amneziawg-tools` | `v3.0.20260805` | `9f70177d204d5be66c5b043518a57b7d62b3f9d1` | GPL-2.0 |

Both repositories are cloned by exact tag and then checked against the pinned
commit before compilation. A moved or replaced upstream tag fails the build.
The pinned `amneziawg-go` tag embeds the separate upstream runtime version
`0.0.20250522`; the QEMU check verifies that exact `--version` output as well
as the immutable source commit.
The Go daemon is built with `CGO_ENABLED=0`; the small `awg` configurator is
statically linked and is only run during interface setup or diagnostics.
Probe artifacts include both upstream license texts and the exact
`amneziawg-tools` source archive corresponding to the GPL-2.0 binary.

The v3 daemon retains the AWG 1.x/2.x fields and adds AWG 3 fields. The first
router integration will continue to configure the AWG 2 field set currently
exported by stable self-hosted Amnezia clients. AWG 3 remains experimental
until a real router test confirms it.

Upstream sources:

- [`amneziawg-go`](https://github.com/amnezia-vpn/amneziawg-go/tree/v3.0.20260805)
- [`amneziawg-tools`](https://github.com/amnezia-vpn/amneziawg-tools/tree/v3.0.20260805)

## Automated checks

The `AWG runtime probe` workflow:

1. cross-builds the daemon and configurator for Linux `arm64` and `mipsle`;
2. uses `GOMIPS=softfloat` for the constrained MIPS target;
3. executes both cross-built binaries under QEMU and verifies their versions;
4. rejects a dynamically linked configurator;
5. starts a native userspace TUN interface on the CI runner;
6. applies an AWG 2 configuration through the official UAPI tool;
7. reads the configuration back without printing its private keys;
8. records idle RSS, high-water RSS and thread count.

The smoke configuration uses a numeric endpoint. The later router supervisor
must resolve a hostname in Go before invoking the static configurator, avoiding
target-libc/NSS differences on older Entware installations.

Local Windows cross-builds produced stripped `amneziawg-go` sizes of
3,276,962 bytes for arm64 and 3,801,281 bytes for mipsle. CI is authoritative
for the Linux-built artifacts and static configurator.

## Live MIPSLE result

The isolated runner was executed on a real MIPSLE Keenetic on 2026-08-12 while
the existing Xray, Go agent and router services remained online. The router
reported `MemTotal: 124528 kB`, no swap and approximately 25-27 MB available
memory before each run. `/opt` had approximately 18 MB free after the probe
artifacts were copied to it.

| Duration | Runtime RSS | Runtime HWM | Threads | Available before | Available during | Available after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 second | 4388 kB | 4616 kB | 12 | 25812 kB | 21960 kB | 25536 kB |
| 5 seconds | 5412 kB | 5412 kB | 12 | 25348 kB | 22560 kB | 25136 kB |

Both runs completed with matching binary SHA256 values and reported restored
routes, routing rules and managed Xray/active-slot state. `Proxy0` and the
active slot were not touched. No real peer, handshake or traffic was used.

This passes the isolated runtime and cleanup gate for the tested router. It
supports proceeding to the single-slot integration stage with an on-demand
daemon policy. It does not prove that the same runtime is safe on a device
with only 40 MB of physical RAM; that remains a separate target-specific gate
if such a router is put in scope.

## Remaining integration gates

QEMU proves that the binaries execute for each architecture, but its memory
usage is not representative. The native CI RSS measurement is an early budget
signal only. The artifact includes a fail-closed router runner and Russian
instructions in [`amneziawg-live-router-probe.md`](amneziawg-live-router-probe.md).
Its first `preflight` mode is read-only; the explicit live mode creates no
address or route and verifies cleanup before reporting success.

Before AWG is included in a user-facing MINIMAL bundle, the next implementation
must also prove a real self-hosted handshake, Xray outbound binding to the AWG
interface, SOCKS5 health and transactional rollback to the existing VLESS
slot. A true 40 MB physical-RAM target, if required, must repeat the isolated
runtime test on that exact hardware.

The single-slot implementation now packages the pinned runtime in both Dev
bundles and enforces the same 24576 kB available-memory floor before starting
it. Its activation path performs the remaining real handshake, Xray binding,
SOCKS and rollback checks on the target router. See
[`amneziawg-single-slot.md`](amneziawg-single-slot.md). Passing that live test
does not waive the separate requirement for a real 40 MB physical-RAM model.
