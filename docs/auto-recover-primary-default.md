# AUTO_RECOVER_PRIMARY default

`AUTO_RECOVER_PRIMARY` controls automatic recovery from `backup` back to `primary` in the watchdog daemon.

## Decision

Default behavior is now:

```text
AUTO_RECOVER_PRIMARY=1
```

Rationale:

```text
primary -> backup failover should be paired with automatic backup -> primary recovery;
recovery probe is selector-aware;
backup -> primary recovery has rollback back to backup if post-switch health-check fails;
watchdog uses success threshold and cooldown before switching back.
```

## Updated paths

Runtime fallback default:

```text
scripts/vless-go-watchdog.sh
AUTO_RECOVER_PRIMARY="${AUTO_RECOVER_PRIMARY:-1}"
```

Watchdog installer config:

```text
xray_vless_go_watchdog_install.sh
AUTO_RECOVER_PRIMARY=1
```

Go public entrypoint first-run config:

```text
xray_vless_failover_go.sh
AUTO_RECOVER_PRIMARY="1"
```

Entware package postinst already creates and normalizes watchdog config with:

```text
AUTO_RECOVER_PRIMARY="1"
```

## Existing installations

Install/update flows should normalize existing watchdog config to enabled by default.

Manual one-liner for an already installed router:

```sh
sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' /opt/etc/xray/vless-go-watchdog.conf
/opt/etc/init.d/S26vless-go-watchdog restart
```

Check runtime status:

```sh
vless-go-watchdog status
```

Expected:

```text
auto_recover_primary=1
```

## Disable if needed

For manual-only recovery behavior:

```sh
sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=0/' /opt/etc/xray/vless-go-watchdog.conf
/opt/etc/init.d/S26vless-go-watchdog restart
```
