# Full Go и Minimal Go

Этот документ описывает два основных профиля установки Keenetic Xray Go и их место в v2-архитектуре.

## Коротко

```text
minimal = xray + Go resolver + primary/backup + subscriptions + selector + Proxy0/SOCKS5
full    = minimal + watchdog + recovery + cron + doctor + history + cleanup + update-core
```

Жёсткий размерный критерий:

```text
Minimal Go target footprint: <= 40 MB
Full Go target footprint:    <= 80 MB постоянного footprint, без временных/stale backup раздуваний
```

Minimal Go не должен терять текущий пользовательский сценарий: он обязан принимать HTTP/HTTPS подписки и bot/sub-link flow так же, как текущая установка.

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
- bot/sub-link flow;
- primary/backup profile slots;
- profile selector из подписки;
- failover primary -> backup;
- watchdog daemon;
- quiet recovery;
- hourly recovery cron;
- doctor/support diagnostics;
- compact summary;
- privacy-check;
- switch history;
- cleanup helper;
- Xray-core update helper;
- direct manifest;
- direct update через `xray-go update go`.

Основные команды:

```sh
xray-go status
xray-go summary
xray-go doctor --support
xray-go privacy-check
xray-go manifest
xray-go recover status
xray-go update go --dry-run
xray-go update go
xray-go uninstall --dry-run
```

## Minimal Go

Minimal Go — лёгкий профиль для роутеров с малым `/opt`.

Цель Minimal Go: сохранить пользовательский сценарий подписок и failover, но убрать тяжёлый service/support/update слой.

Minimal Go target:

```text
<= 40 MB installed footprint
```

Minimal Go обязан сохранять:

- Xray binary;
- Go resolver;
- HTTP/HTTPS subscription sources;
- прямые `vless://` links;
- bot/sub-link flow;
- profile selector из подписки, например `index:1`;
- primary/backup profile slots;
- config generation;
- manual switch primary/backup;
- Proxy0;
- SOCKS5 listener;
- minimal status/check command.

Minimal Go должен оставаться без:

- `python3`;
- Agent;
- Control Server;
- watchdog daemon;
- hourly recovery cron;
- heavy doctor/support diagnostics;
- switch history database/log expansion;
- cleanup helper как отдельного тяжёлого слоя;
- Xray-core update helper;
- large backup retention;
- optional modules.

Типовые команды Minimal Go:

```sh
minimal-go-status
minimal-go-switch primary
minimal-go-switch backup
minimal-go-update-source
```

`minimal-go-update-source` должен принимать тот же источник, который приходит из bot/sub-link flow, и уметь выбрать профиль из подписки без Full Go watchdog/doctor слоя.

## Direct-install v2 и профили

Direct-install v2 сейчас подтверждён на реальном Keenetic для Full Go direct layer:

```text
direct full dry-run              OK
direct full apply                OK
xray-go update go --dry-run      OK
xray-go update go                OK
xray-go uninstall --dry-run      OK
xray-go summary                  OK
xray-go privacy-check            OK
```

Direct-install v2 для Full Go использует:

```text
scripts/xray-go-direct-install.sh
scripts/xray-go-direct-init.sh
scripts/xray-go-direct-full.sh
scripts/xray-go-direct-uninstall.sh
/opt/etc/xray/xray-go.manifest
```

Minimal Go пока остаётся отдельным лёгким профилем через существующий Minimal Go flow. Цель будущего развития — сделать direct-install общим базовым flow для Full и Minimal, но не утяжелять Minimal и не убирать поддержку подписок.

## Out-of-core extras

Agent и Control Server не входят в router core.

Правило:

- на роутере нет web-интерфейса: удалённое управление идёт только через Telegram control bot;
- Agent ставится отдельной ссылкой/сценарием из бота;
- Control Server не смешивается с router installer;
- `xray-go module list` и `xray-go module enable/disable ...` не добавляются в core CLI.

Это сохраняет core компактным: install, update, direct state, subscription parsing, Proxy0/SOCKS5 и failover остаются core; watchdog/recovery/doctor/history/cleanup/update-core относятся к Full Go.

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
xray-go summary
xray-go manifest
xray-go recover status
xray-go doctor --support
xray-go privacy-check
```

Ожидаемый итог:

```text
Install mode: direct
health: OK
SOCKS health-check OK
FAIL=0
```

Для Minimal Go нормальная проверка должна подтверждать:

```text
profile: minimal-go
footprint: <= 40 MB
subscription source: supported
selector: supported
active slot: primary|backup
Proxy0: exists
SOCKS health: OK
```
