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

## Remaining router gate

QEMU proves that the binaries execute for each architecture, but its memory
usage is not representative. The native CI RSS measurement is an early budget
signal only. Before AWG is added to MINIMAL, the exact mipsle runtime must be
started on the 40 MB router and measured together with Xray, the Go agent and
the existing watchdog. No bundle inclusion is allowed until that live gate
passes.
