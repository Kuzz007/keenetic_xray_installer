# TODO: Keenetic Xray Go v2

Цель: переосмыслить проект так, чтобы он стал компактнее, понятнее и удобнее, но не потерял текущий функционал.

Главный принцип: новая архитектура строится вокруг `auto_latest`, `Full Go`, `Minimal Go` и единой команды `xray-go`.

---

## 0. Правило по legacy и old_go

`legacy` и `old_go` считаются архивной линией.

### Нужно сделать

- [ ] Не переписывать `legacy` и `old_go`.
- [ ] Не переносить из них логику в новую архитектуру без крайней необходимости.
- [ ] Не оптимизировать старые installer-ветки.
- [ ] Оставить их как страховку для старых установок и ручного fallback.
- [ ] Явно написать в README: `legacy/old_go` frozen.

### Описание

Старые ветки не должны мешать развитию новой Go-линии. Они остаются в репозитории, но не участвуют в проектировании v2.

---

## 1. Зафиксировать активную линию проекта

Активная линия — это всё, что относится к текущей Go-архитектуре.

### Активные компоненты

- [ ] `xray_vless_failover_auto_latest.sh`
- [ ] `xray_vless_failover_go.sh`
- [ ] `xray_vless_failover_minimal_go.sh`
- [ ] `scripts/xray-go.sh`
- [ ] Full Go/Entware edition
- [ ] Minimal Go edition
- [ ] recovery
- [ ] watchdog
- [ ] doctor
- [ ] history
- [ ] cleanup
- [ ] Xray-core update
- [ ] Web UI
- [ ] Agent
- [ ] Control Server

### Описание

Все новые улучшения должны идти только в эту линию. Это уменьшает хаос и не даёт расползаться функционалу по нескольким старым установщикам.

---

## 2. Добавить единый будущий вход `install.sh`

Сейчас основной вход — `xray_vless_failover_auto_latest.sh`. В будущем нужен более простой и понятный публичный вход: `install.sh`.

### Нужно сделать

- [ ] Создать `install.sh` в корне репозитория.
- [ ] Перенести или переиспользовать внутри него логику `auto_latest`.
- [ ] Сохранить совместимость со старой командой `xray_vless_failover_auto_latest.sh`.
- [ ] Позже сделать `xray_vless_failover_auto_latest.sh` тонким wrapper на `install.sh`.
- [ ] Поддержать текущие параметры:
  - [ ] `--auto`
  - [ ] `--go`
  - [ ] `--minimal-go`
  - [ ] `--detect-only`
  - [ ] `--doctor`
  - [ ] `--update-only`
  - [ ] `--no-cron`
  - [ ] `--no-restart`

### Будущая команда установки

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

### Описание

Пользователь должен видеть одну понятную команду установки. Старое имя остаётся рабочим для совместимости, но новая документация должна вести на `install.sh`.

---

## 3. Упростить README

README должен быть коротким входом для пользователя, а не полным архивом всех старых вариантов.

### Нужно сделать

- [ ] В начало README поставить только рекомендуемую установку.
- [ ] Основной сценарий описывать через `install.sh` или `auto_latest`.
- [ ] Убрать перегруз legacy-инструкциями из основной части.
- [ ] Создать отдельный документ `docs/legacy.md`.
- [ ] Перенести подробности по legacy/old_go в `docs/legacy.md`.
- [ ] Добавить короткую архитектурную схему:

```text
install.sh / auto_latest
  -> Full Go
  -> Minimal Go
  -> xray-go
```

### Описание

README должен помогать быстро установить и проверить работу. Всё старое и редкое лучше держать в отдельных документах.

---

## 4. Сделать `xray-go` главным интерфейсом управления

`xray-go` должен стать единой командой для пользователя.

### Уже есть

- [ ] `xray-go status`
- [ ] `xray-go doctor`
- [ ] `xray-go menu`
- [ ] `xray-go history`
- [ ] `xray-go logs`
- [ ] `xray-go recover`
- [ ] `xray-go update`
- [ ] `xray-go update-core`
- [ ] `xray-go switch`
- [ ] `xray-go cleanup`
- [ ] `xray-go version`

### Нужно добавить или улучшить

- [ ] `xray-go module list`
- [ ] `xray-go module enable web-ui`
- [ ] `xray-go module disable web-ui`
- [ ] `xray-go module enable agent`
- [ ] `xray-go module disable agent`
- [ ] `xray-go agent status`
- [ ] `xray-go web status`

### Описание

Низкоуровневые команды можно оставить, но пользователь должен чаще всего работать только через `xray-go`.

---

## 5. Привести Full Go и Minimal Go к общей логике

Full Go и Minimal Go должны восприниматься как два профиля одной системы, а не как два разных проекта.

### Профили

```text
minimal = core + xray + primary/backup + failover + Proxy0/SOCKS5
full    = minimal + subscriptions + cron + watchdog + recovery + doctor + history + cleanup + update-core
```

### Нужно сделать

- [ ] Описать Full Go и Minimal Go как профили установки.
- [ ] Проверить, какие функции Full Go можно безопасно делать optional-модулями.
- [ ] Не добавлять тяжёлые зависимости в Minimal Go.
- [ ] Сохранить автоматический выбор режима по свободному месту в `/opt`.
- [ ] Сохранить ручной выбор через `--go` и `--minimal-go`.

### Описание

Minimal должен оставаться лёгким и надёжным. Full должен быть расширенным вариантом с подписками, watchdog, recovery и диагностикой.

---

## 6. Спроектировать единый state/config слой

Сейчас состояние может храниться в разных местах. Нужно постепенно привести это к единой модели.

### Нужно проверить

- [ ] Где хранится active slot.
- [ ] Где хранятся primary/backup profiles.
- [ ] Где хранится состояние Minimal Go.
- [ ] Где хранится состояние recovery.
- [ ] Где хранится состояние watchdog.
- [ ] Где хранится состояние agent.
- [ ] Что читает Web UI.
- [ ] Что читает Control Server.

### Целевая структура

```text
/opt/etc/xray/xray-go.conf
/opt/etc/xray/xray-go.state
```

### Описание

Doctor, watchdog, recovery, agent и Web UI должны читать одну и ту же правду. Это упростит диагностику и уменьшит количество edge-case ошибок.

---

## 7. Web UI оставить опциональным модулем

Web UI полезен, но он не должен быть частью минимальной базовой установки.

### Нужно сделать

- [ ] Не включать Web UI по умолчанию.
- [ ] Устанавливать Web UI отдельной командой.
- [ ] Добавить управление через `xray-go module`.
- [ ] Добавить статус Web UI в `xray-go status` или `xray-go web status`.
- [ ] В документации указать: Web UI должен быть доступен только в доверенной локальной сети.

### Команды

```sh
xray-go module enable web-ui
xray-go module disable web-ui
xray-go web status
```

### Описание

Базовая установка должна оставаться лёгкой. Web UI — удобное расширение для тех, кому оно нужно.

---

## 8. Agent и Control Server оставить опциональными

Agent и Control Server относятся к расширенному управлению и не должны смешиваться с базовой установкой роутера.

### Нужно сделать

- [ ] Не включать agent по умолчанию.
- [ ] Не включать control-server по умолчанию.
- [ ] Описать agent как optional-модуль.
- [ ] Описать control-server отдельно от router installer.
- [ ] Добавить команды управления agent через `xray-go`.

### Команды

```sh
xray-go module enable agent
xray-go module disable agent
xray-go agent status
```

### Описание

Обычному пользователю нужен installer и `xray-go`. Agent/control-server нужны только для расширенной схемы управления.

---

## 9. Улучшить Doctor и Support mode

Диагностика должна быть безопасной для отправки в поддержку.

### Нужно сохранить

- [ ] `xray-go doctor`
- [ ] `xray-go doctor --support`
- [ ] `xray-go doctor --json`

### Нужно улучшить

- [ ] Добавить понятный summary:

```text
OK:
WARN:
FAIL:
Active slot:
Recovery:
Watchdog:
Proxy0:
Xray:
Cron:
```

- [ ] Проверить, что в support output не попадают raw VLESS links.
- [ ] Проверить, что в support output не попадают subscription URLs.
- [ ] Проверить, что JSON summary стабилен для Web UI / Agent / Control Server.

### Описание

Doctor должен быстро показывать проблему, а support mode должен быть безопасным для копирования в чат или issue.

---

## 10. Сделать обновления предсказуемыми

Обновление разных частей проекта должно быть явно разделено.

### Нужно сделать

- [ ] Разделить update targets:
  - [ ] Go edition
  - [ ] Xray-core
  - [ ] Web UI
  - [ ] Agent
  - [ ] Control Server
- [ ] Добавить понятные команды:

```sh
xray-go update go
xray-go update xray-core
xray-go update web-ui
xray-go update agent
```

- [ ] Не менять пользовательские профили при safe update.
- [ ] Не перезаписывать primary/backup sources без явного действия пользователя.
- [ ] Сохранить `--no-cron` и `--no-restart` для аккуратного обновления.

### Описание

Обновление должно быть безопасным: код можно обновить, но пользовательские настройки нельзя случайно потерять.

---

## 11. Минимизировать количество публичных скриптов в корне

Корень репозитория должен быть понятным.

### Нужно сделать

- [ ] В корне оставить основные публичные входы:
  - [ ] `README.md`
  - [ ] `TODO.md`
  - [ ] `install.sh`
  - [ ] `xray_vless_failover_auto_latest.sh`
  - [ ] текущие Full/Minimal Go installers, пока они нужны для совместимости
- [ ] Всё вспомогательное держать в:
  - [ ] `scripts/`
  - [ ] `cmd/`
  - [ ] `docs/`
  - [ ] `packaging/`
- [ ] Не трогать legacy/old_go в рамках этого пункта.

### Описание

Чем меньше файлов пользователь видит в корне, тем проще понять проект. Старые совместимые входы можно оставить, но новые инструкции должны вести по одному пути.

---

## 12. Проверить безопасность и восстановление

Проект управляет сетевой связностью роутера, поэтому recovery и rollback важнее красоты кода.

### Нужно проверить

- [ ] Recovery не создаёт reboot loop.
- [ ] Watchdog не ломает ручной switch.
- [ ] Failover корректно переключает primary -> backup.
- [ ] Возврат на primary работает только когда primary реально восстановился.
- [ ] Proxy0 refresh безопасен.
- [ ] Xray restart не затирает конфиг.
- [ ] `xray-go doctor --support` не раскрывает приватные данные.

### Описание

Любое упрощение не должно ухудшить надёжность. Сначала стабильность, потом компактность.

---

## 13. Документация по режимам

Нужно понятно объяснить, чем отличаются Full Go, Minimal Go и optional-модули.

### Нужно сделать

- [ ] `docs/install.md` — установка и первый запуск.
- [ ] `docs/modes.md` — Full Go vs Minimal Go.
- [ ] `docs/recovery.md` — recovery/watchdog/failover.
- [ ] `docs/web-ui.md` — Web UI.
- [ ] `docs/agent.md` — Agent.
- [ ] `docs/control-server.md` — Control Server.
- [ ] `docs/legacy.md` — legacy/old_go frozen archive.

### Описание

README должен быть коротким. Подробности должны жить в `docs/`.

---

## 14. Финальная цель v2

Пользовательский путь должен стать максимально простым.

### Установка

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

### Управление

```sh
xray-go status
xray-go doctor
xray-go menu
xray-go switch primary
xray-go switch backup
xray-go recover status
xray-go update
```

### Описание

Пользователь не должен выбирать между множеством старых скриптов. Проект должен оставаться мощным, но выглядеть компактно и понятно.
