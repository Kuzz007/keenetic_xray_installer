# Next installer entrypoints

This document describes the new opt-in installer entrypoints. They are intentionally separate from the existing legacy scripts.

## Legacy scripts removed

The old shell monoliths (`xray_vless_failover_auto.sh`, `xray_vless_failover.sh`,
`xray_vless_failover_minimal.sh`) have been retired and deleted from the repository.
See `docs/legacy.md`.

## Recommended install matrix

```text
Full Go/Entware:
  latest feed, VLESS/self-hosted AWG roadmap, agent/bot, doctor, watchdog, menu, updater

Minimal Go:
  same agent/bot control, primary/backup failover, no python3, target routers around 40 MB RAM

Legacy Minimal:
  old shell backend, kept for compatibility
```

## New binary router bundles (developer preview)

FULL and MINIMAL are now also assembled as self-verifying ELF `.run` files:

```text
keenetic-vpn-full-linux-{arm64|mipsle}.run
keenetic-vpn-minimal-linux-{arm64|mipsle}.run
```

The source remains modular: the bundle contains the two router-side Go
binaries and small shell helpers instead of merging the runtime into one large
process. Both editions include `xray-go-agent`; Minimal does not lose bot
features. See [router-bundles.md](router-bundles.md) for the format, safety
model, channel URLs and current first-install boundary.

## New auto latest entrypoint

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh
```

Behavior:

- checks free space on `/opt`
- if free space is below `THRESHOLD_KB` (default `80000`), selects Minimal Go
- otherwise selects Go/Entware latest edition through `scripts/install-entware-feed.sh`

Forced Go/latest edition:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --go
```

Forced Minimal Go edition:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --minimal-go
```

Forced legacy-compatible Minimal-next edition:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --minimal-next
```

Non-interactive mode:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --yes
```

## New Minimal Go entrypoint

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_minimal_go.sh | sh
```

Current behavior:

- direct `vless://` links only
- stores primary and backup VLESS links separately
- downloads only `xray-failover-go` from the `latest` GitHub Release when missing
- does not install python3
- does not register or install the Entware feed package
- creates `/opt/etc/init.d/S24xray`
- creates/updates `Proxy0`
- installs a lightweight failover daemon
- supports primary -> backup failover and backup -> primary recovery

Installed commands:

```text
minimal-go-status
minimal-go-switch primary|backup
minimal-go-update primary|backup 'vless://...'
/opt/etc/init.d/S25xray-minimal-go-failover restart
```

State files:

```text
/opt/etc/xray/minimal-go-primary.url
/opt/etc/xray/minimal-go-backup.url
/opt/etc/xray/minimal-go-active
/opt/etc/xray/minimal-go-router-lan-ip
/opt/var/log/minimal-go-switch-history.log
```

## Minimal-next entrypoint (removed)

`xray_vless_failover_minimal_next.sh` no longer exists in the repository, and the
legacy minimal backend it wrapped has been retired. Use Minimal Go instead:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_minimal_go.sh | sh
```

Minimal limitations are unchanged:

- direct `vless://` links only
- no subscriptions
- no `python3` requirement
- no cron auto-update

Reuse existing minimal failover state:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_minimal_next.sh | sh -s -- --reuse-failover
```

## Rationale

The new entrypoints allow testing a modern default path without breaking users who already rely on the legacy auto/minimal URLs.

Recommended default for new installs:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh
```
