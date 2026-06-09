# Adaptive size policy

This document defines the v2 size and component policy for Keenetic Xray Go.

## Goals

```text
Minimal Go target footprint: <= 40 MB
Full Go target footprint:    <= 80 MB steady-state footprint
```

Minimal Go must keep the current user-facing subscription flow. It is not a manual-only `vless://` mode.

Minimal Go must support:

```text
HTTP/HTTPS subscription sources
bot/sub-link flow
profile selector from subscription, e.g. index:1
primary/backup slots
manual switch primary/backup
Proxy0
SOCKS5 listener
```

## Install strategy

The installer should use an adaptive two-stage flow.

### Stage 1: required core

Install the smallest working core first:

```text
Xray binary
Go resolver
subscription/direct source parser path
primary/backup state
profile selector
config generation
Proxy0/SOCKS5
minimal status/check
```

This stage is the Minimal Go target and should fit within 40 MB installed footprint.

### Stage 2: optional components after space check

After the core is installed and checked, the installer should inspect free space under `/opt`.

If enough space is available, it may add lightweight Full Go components:

```text
watchdog daemon
recovery helper
recovery cron
compact summary
basic doctor/check helpers
privacy-check
safety-check
history with bounded retention
cleanup helper
```

These components should be delivered after the base install, not as a requirement for Minimal Go.

## Components excluded from automatic post-install expansion

`Xray-core update` must not be auto-installed as part of the post-install expansion.

Reason:

```text
Xray-core update may require downloading a second Xray binary
old Xray backup can temporarily double Xray storage
this can break the 40 MB Minimal target and pressure the 80 MB Full target
```

`update-core` remains explicit opt-in:

```sh
xray-go update xray-core --dry-run
xray-go update xray-core --channel latest --yes
```

## Backup retention policy

To preserve the size budget:

```text
keep at most one Xray backup
keep at most one Go resolver backup
remove stale /opt/tmp/xray-go-* staging after successful install/update
bound watchdog/detail/history logs
report reclaimable space before cleanup
```

## Space gate model

Recommended behavior:

```text
1. install Minimal Go core
2. run minimal health checks
3. measure /opt free space and current footprint
4. if budget allows, install optional lightweight Full components
5. never auto-enable Xray-core update helper in the expansion step
6. print final footprint and budget status
```

The final output should clearly show:

```text
profile selected: minimal|full-lite|full
current footprint
free /opt space
components installed
components skipped due to size policy
80 MB / 40 MB budget status
```

## Practical profile split

```text
minimal:
  xray + go resolver + subscriptions + selector + primary/backup + Proxy0/SOCKS5

full-lite auto expansion:
  minimal + watchdog + recovery + summary + basic doctor + privacy/safety checks + bounded history/cleanup

manual-only:
  Xray-core update helper and large binary backup workflows
```

This keeps Minimal Go useful for bot/subscription users while avoiding uncontrolled footprint growth.
