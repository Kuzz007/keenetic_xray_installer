# Legacy / old_go archive

Этот документ описывает старые installer-линии, которые сохранены только для совместимости и ручного fallback.

## Статус

`legacy` и `old_go` считаются frozen archive.

Правила:

- не переписывать;
- не оптимизировать;
- не использовать как основной путь новой установки;
- не переносить оттуда логику в v2 без крайней необходимости;
- не ломать старые ссылки, если они ещё используются старыми установками.

## Новая установка

Для новых установок использовать:

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

## Старые публичные entrypoints

Legacy scripts в корне репозитория:

```text
xray_vless_failover_auto.sh
xray_vless_failover.sh
xray_vless_failover_minimal.sh
```

Old Go / old minimal variants остаются архивными и не являются направлением развития.

## Зачем они остаются

Они нужны только для:

- восстановления старых установок;
- ручного fallback;
- сравнения поведения при разборе старых багов.

Новая v2-линия развивается вокруг:

```text
install.sh
xray-go
scripts/xray-go-direct-install.sh
scripts/xray-go-direct-init.sh
scripts/xray-go-direct-full.sh
scripts/xray-go-direct-uninstall.sh
```
