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

## Оставшаяся зависимость от архива

`scripts/minimal-go-backend.sh` всё ещё скачивает
`xray_vless_failover_minimal_old_go.sh` с закреплённого коммита
(`PINNED_MINIMAL_GO_REF`, сейчас `26b5e7b5`). Пин на исторический ref означает, что
удаление файлов из `main` эту установку не ломает, но Minimal Go по-прежнему
зависит от архивного shell-монолита.

Полное закрытие legacy-линии требует вендорить backend прямо в `main` — см. `TODO.md`.
