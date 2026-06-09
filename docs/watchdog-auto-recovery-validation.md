# Watchdog auto recovery validation

This document records live validation for primary -> backup -> primary watchdog recovery.

## Observed issue

A configured router switched from primary to backup correctly, but stayed on backup after the primary server came back online.

Manual checks showed:

```text
AUTO_RECOVER_PRIMARY=1
vless-go-watchdog status: active=backup auto_recover_primary=1
command -v xray: /opt/sbin/xray
vless-go-watchdog probe-primary: RC=0
```

This proved the primary was healthy and the selector-aware recovery probe worked.

The daemon log before restart showed repeated backup health checks but no daemon-initiated recovery probe. That means the running daemon process was still using old in-memory helper logic after helper update.

## Live validation after watchdog restart

After:

```sh
/opt/etc/init.d/S26vless-go-watchdog restart
```

The daemon immediately used the updated recovery logic:

```text
Daemon запущен: interval=15s failover_failures_required=2 check_retries=2 auto_recover_primary=1 post_switch_delay=5s proxy0_refresh=0 socks_auth=1
Daemon health OK на backup
Проверка восстановления primary на временном SOCKS порту 18080
Recovery probe primary использует selector: index:1
Recovery probe primary OK: 1/2
Daemon health OK на backup
Проверка восстановления primary на временном SOCKS порту 18080
Recovery probe primary использует selector: index:1
Recovery probe primary OK: 2/2
Достигнут порог recovery; переключение backup -> primary
Переключение на primary
Переключение на primary завершено
Ожидание 5s после переключения
Daemon recovery на primary OK
Daemon health OK на primary
```

`xray-go summary` then confirmed:

```text
Active slot: primary
Xray init: alive
Xray config: valid
SOCKS health: OK
Watchdog init: alive
OK=12 WARN=0 FAIL=0
```

## Fix

`xray-go-direct-full --apply --yes` now restarts the watchdog daemon after helper/init updates and before the final direct-init post-check.

This ensures the daemon uses the freshly installed failover/recovery logic immediately after `xray-go update go`.
