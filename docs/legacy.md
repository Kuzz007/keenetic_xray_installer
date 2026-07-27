# Legacy line: retired

Старая shell-линия full/minimal выведена из проекта и больше не поддерживается.

## Что удалено

```text
xray_vless_failover_auto.sh
xray_vless_failover.sh
xray_vless_failover_minimal.sh
src/full/, src/minimal/     — модульные исходники этих монолитов
legacy/monolith/            — архивные копии
patches/                    — патчи к legacy-исходникам
scripts/build-installers.sh — сборка корневых артефактов из src/
scripts/{apply,fix,insert}-*.sh — одноразовые патч-скрипты legacy-линии
```

Файлы остаются доступными в истории git (до коммита `1978766`), если понадобится
разобрать старый баг или восстановить древнюю установку.

## Актуальная линия

Новая установка:

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

Проект развивается вокруг:

```text
install.sh
xray-go
scripts/xray-go-direct-install.sh
scripts/xray-go-direct-init.sh
scripts/xray-go-direct-full.sh
scripts/xray-go-direct-uninstall.sh
```

## Зависимость от архива закрыта

`scripts/minimal-go-backend.sh` раньше скачивал `xray_vless_failover_minimal_old_go.sh`
с закреплённого исторического коммита (`PINNED_MINIMAL_GO_REF`). Реализация
теперь вендорена напрямую в `main`: `minimal-go-backend.sh` больше не делает
второй сетевой запрос и не зависит от того, что старый ref останется доступным
под тем же именем репозитория.
