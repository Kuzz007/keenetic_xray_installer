# OPKG / IPK feed v1 compatibility

Этот документ фиксирует статус старой Full Go установки через Entware feed и `.ipk`.

## Статус

IPK/feed остаётся v1 compatibility mode для существующих Full Go установок.

Для новой v2-линии целевой путь — direct-install:

```text
install.sh
  -> direct full flow
  -> xray-go update go
  -> manifest
  -> post-check
```

## Что относится к v1 feed

Старая схема использует:

```text
.ipk
Packages
Packages.gz
Entware feed registration
opkg install failover-go
opkg remove failover-go
```

Эта схема не удаляется сразу, чтобы не сломать существующие установки.

## Что относится к v2 direct-install

Direct-install v2 использует:

```text
/opt/bin/xray-failover-go
/opt/bin/xray-go
/opt/bin/vless-go-*
/opt/bin/failover-go
/opt/bin/xray-go-manifest
/opt/bin/xray-go-direct-full
/opt/bin/xray-go-direct-uninstall
/opt/etc/xray/xray-go.manifest
/opt/etc/xray/xray-go.direct-install.plan
/opt/etc/xray/xray-go.direct-init.plan
```

Основные команды:

```sh
xray-go update go --dry-run
xray-go update go
xray-go uninstall --dry-run
```

## Правило развития

- v1 feed поддерживается как совместимость;
- новые улучшения идут в direct-install v2;
- `xray-go update go` выбирает путь по manifest:
  - `INSTALL_MODE=direct` -> direct full update;
  - нет manifest или не direct -> старый совместимый update path.
