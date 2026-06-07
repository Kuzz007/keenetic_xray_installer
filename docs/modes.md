# Full Go и Minimal Go

Этот документ описывает два основных профиля установки Keenetic Xray Go и их место в v2-архитектуре.

## Коротко

```text
minimal = core + xray + primary/backup + failover + Proxy0/SOCKS5
full    = minimal + subscriptions + cron + watchdog + recovery + doctor + history + cleanup + update-core
```

## Как выбирается режим

Основной вход установки:

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

Сейчас `install.sh` по умолчанию сохраняет совместимость с Auto Latest selector. Auto Latest выбирает профиль по состоянию `/opt` и параметрам запуска.

Явный Full Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --go
```

Явный Minimal Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --minimal-go
```

Проверить выбор без изменений:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --detect-only
```

## Full Go

Full Go — основной профиль для нормальной установки на USB/SSD или при достаточном свободном месте в `/opt`.

Full Go включает:

- Go resolver `/opt/bin/xray-failover-go`;
- shell helpers `/opt/bin/vless-go-*`;
- wrapper `/opt/bin/xray-go`;
- прямые `vless://` links;
- HTTP/HTTPS subscription sources;
- primary/backup profile slots;
- profile selector из подписки;
- failover primary -> backup;
- watchdog daemon;
- quiet recovery;
- hourly recovery cron;
- doctor/support diagnostics;
- switch history;
- cleanup helper;
- Xray-core update helper;
- direct manifest;
- direct update через `xray-go update go`.

Основные команды:

```sh
xray-go status
xray-go doctor --support
xray-go manifest
xray-go recover status
xray-go update go --dry-run
xray-go update go
xray-go uninstall --dry-run
```

## Minimal Go

Minimal Go — лёгкий профиль для роутеров с малым `/opt`.

Цель Minimal Go: сохранить базовый failover без тяжёлых зависимостей.

Minimal Go должен оставаться без:

- `python3`;
- subscription parser layer;
- тяжёлых cron/update helpers;
- Web UI;
- Agent;
- Control Server;
- лишних optional modules.

Minimal Go сохраняет:

- Xray config generation;
- primary/backup direct VLESS profiles;
- failover;
- Proxy0;
- SOCKS5;
- ручной switch между primary/backup.

Типовые команды Minimal Go:

```sh
minimal-go-status
minimal-go-switch primary
minimal-go-switch backup
```

## Direct-install v2 и профили

Direct-install v2 сейчас подтверждён на реальном Keenetic для Full Go direct layer:

```text
direct full dry-run              OK
direct full apply                OK
xray-go update go --dry-run      OK
xray-go update go                OK
xray-go uninstall --dry-run      OK
```

Direct-install v2 для Full Go использует:

```text
scripts/xray-go-direct-install.sh
scripts/xray-go-direct-init.sh
scripts/xray-go-direct-full.sh
scripts/xray-go-direct-uninstall.sh
/opt/etc/xray/xray-go.manifest
```

Minimal Go пока остаётся отдельным лёгким профилем через существующий Minimal Go flow. Цель будущего развития — сделать direct-install общим базовым flow для Full и Minimal, но не утяжелять Minimal.

## Optional modules

Optional modules не должны включаться по умолчанию.

К optional modules относятся:

```text
Web UI
Agent
Control Server
```

Правило:

- Full Go может уметь включать optional modules отдельными командами;
- Minimal Go не должен получать тяжёлые optional modules по умолчанию;
- Web UI должен быть доступен только в доверенной локальной сети;
- Agent/Control Server относятся к расширенной схеме управления, а не к базовой установке роутера.

Будущие команды:

```sh
xray-go module list
xray-go module enable web-ui
xray-go module disable web-ui
xray-go web status
xray-go module enable agent
xray-go module disable agent
xray-go agent status
```

## IPK/feed и профили

Старая IPK/feed схема относится к v1 compatibility mode.

Для новой v2-линии целевой путь:

```text
install.sh
  -> direct-install v2
  -> Full Go / Minimal Go profiles
  -> xray-go management
```

IPK/feed не удаляется сразу, но не является направлением развития v2.

Подробности: `docs/opkg-feed-v1.md`.

## Проверка установленного профиля

```sh
if command -v xray-go >/dev/null 2>&1; then
    xray-go manifest 2>/dev/null || true
    xray-go status
elif command -v minimal-go-status >/dev/null 2>&1; then
    minimal-go-status
else
    echo "Go profile status command not found"
fi
```

Для Full Go direct-mode нормальная проверка:

```sh
xray-go manifest
xray-go recover status
xray-go doctor --support
```

Ожидаемый итог:

```text
Install mode: direct
health: OK
SOCKS health-check OK
FAIL=0
```
