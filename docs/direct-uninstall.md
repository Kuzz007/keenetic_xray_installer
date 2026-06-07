# Direct uninstall / cleanup dry-run

Direct-install v2 больше не опирается на `opkg remove failover-go`, поэтому для него нужен собственный безопасный uninstall/cleanup flow.

Первый этап — только read-only planner:

```sh
xray-go uninstall --dry-run
```

или через публичный installer entrypoint:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-uninstall-dry-run
```

## Что делает dry-run

Dry-run ничего не удаляет и не меняет. Он только показывает план:

```text
- direct code files, которые были бы удалены;
- watchdog init.d hook, который был бы удалён;
- recovery cron marker, который был бы удалён;
- direct manifest/plan/staging, которые были бы удалены;
- user/runtime data, которые должны быть сохранены по умолчанию.
```

## Что должно сохраняться по умолчанию

Даже будущий explicit uninstall не должен молча удалять пользовательские данные:

```text
/opt/etc/xray/current_vless
/opt/etc/xray/primary_vless
/opt/etc/xray/backup_vless
/opt/etc/xray/vless-primary.selector
/opt/etc/xray/vless-backup.selector
/opt/etc/xray/config.json
/opt/etc/xray/vless-go-socks-auth.conf
/opt/etc/xray/vless-go-watchdog.conf
/opt/var/log/vless-go-switch-history.log
/opt/var/log/vless-go-watchdog.log
/opt/var/log/vless-go-recover.log
```

Если когда-нибудь появится purge-режим, он должен быть отдельным явным режимом и требовать подтверждение.

## Safety boundary

На текущем этапе helper:

```text
не удаляет файлы;
не редактирует cron;
не останавливает сервисы;
не меняет VLESS sources;
не трогает Xray config;
не чистит логи.
```

Future apply mode должен требовать `--yes`, а `--dry-run` должен остаться default.
