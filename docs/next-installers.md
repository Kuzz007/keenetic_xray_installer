# Next installer entrypoints

This document describes the new opt-in installer entrypoints. They are intentionally separate from the existing legacy scripts.

## Existing legacy scripts remain unchanged

```text
xray_vless_failover_auto.sh
xray_vless_failover_minimal.sh
```

These files keep their current behavior and URLs.

## Recommended install matrix

```text
Full Go/Entware:
  latest feed, subscriptions, doctor, watchdog, menu, updater

Minimal Go:
  direct vless://, primary/backup failover, no python3, target low-storage routers around 40 MB free

Legacy Minimal:
  old shell backend, kept for compatibility
```

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

## New Minimal-next legacy-compatible entrypoint

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_minimal_next.sh | sh
```

Current behavior:

- performs preflight checks
- installs `curl`/`ca-bundle` if needed
- downloads the legacy `xray_vless_failover_minimal.sh` backend
- runs the legacy minimal backend unchanged

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
