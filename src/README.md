# Source installers

This directory is the editable source area.

Current first-stage layout:

- `src/full/xray_vless_failover.sh`
- `src/minimal/xray_vless_failover_minimal.sh`

Build root installers with:

```sh
sh scripts/build-installers.sh
```

Later these files can be split into smaller modules such as:

- `proxy0.sh`
- `healthcheck.sh`
- `daemon.sh`
- `status.sh`
- `menu.sh`
