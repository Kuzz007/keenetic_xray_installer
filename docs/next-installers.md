# Next installer entrypoints

This document describes the new opt-in installer entrypoints. They are intentionally separate from the existing legacy scripts.

## Existing legacy scripts remain unchanged

```text
xray_vless_failover_auto.sh
xray_vless_failover_minimal.sh
```

These files keep their current behavior and URLs.

## New auto latest entrypoint

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh
```

Behavior:

- checks free space on `/opt`
- if free space is below `THRESHOLD_KB` (default `80000`), selects Minimal-next
- otherwise selects Go/Entware latest edition through `scripts/install-entware-feed.sh`

Forced Go/latest edition:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --go
```

Forced Minimal-next edition:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --minimal
```

Non-interactive mode:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --yes
```

## New Minimal-next entrypoint

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
