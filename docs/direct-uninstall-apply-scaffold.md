# Direct uninstall apply scaffold

This document records the guarded uninstall apply scaffold for direct-install v2.

## Status

The real removal path is intentionally not enabled yet.

Current behaviour:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-uninstall-experimental --yes
```

The command:

- downloads `scripts/xray-go-direct-uninstall.sh`;
- prints the same uninstall/cleanup plan as dry-run;
- requires explicit `--yes`;
- verifies that manifest `INSTALL_MODE` is `direct`;
- prints a guarded apply scaffold message;
- makes no changes in this build.

## Safety boundary

Even in scaffold apply mode, the helper does not:

- stop services;
- delete files;
- edit cron;
- remove VLESS sources;
- edit `/opt/etc/xray/config.json`;
- remove SOCKS auth config;
- remove logs.

Future real removal must keep `--dry-run` as default and must require an explicit confirmation flag.

## Current user-facing commands

Read-only plan through `xray-go`:

```sh
xray-go uninstall --dry-run
```

Guarded apply scaffold through `install.sh`:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-uninstall-experimental --yes
```
