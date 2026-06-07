# TODO: Keenetic Xray Go v2

Цель: переосмыслить проект так, чтобы он стал компактнее, понятнее и удобнее, но не потерял текущий функционал.

Главный принцип: новая архитектура строится вокруг `install.sh`, `auto_latest`, `Full Go`, `Minimal Go` и единой команды `xray-go`.

Новое архитектурное решение: для v2 целевая установка должна идти через direct-install без обязательного IPK/Entware feed слоя. IPK/feed остаются как старая v1-схема совместимости, но не являются направлением развития v2.

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

## 1. Зафиксировать активную и замороженную линии проекта

Активная линия — это всё, что относится к текущей и будущей Go-архитектуре.

### Активные компоненты

- [x] `install.sh`
- [ ] `xray_vless_failover_auto_latest.sh`
- [ ] `xray_vless_failover_go.sh`
- [ ] `xray_vless_failover_minimal_go.sh`
- [x] `scripts/xray-go.sh`
- [ ] Full Go edition
- [ ] Minimal Go edition
- [x] direct-install v2
- [ ] recovery
- [ ] watchdog
- [ ] doctor
- [ ] history
- [ ] cleanup
- [ ] Xray-core update
- [ ] Web UI
- [ ] Agent
- [ ] Control Server

### Замороженные компоненты

- [ ] legacy installers
- [ ] old_go installers
- [ ] старая IPK/feed v1-схема после появления direct-install v2

### Описание

Все новые улучшения должны идти только в активную линию. Это уменьшает хаос и не даёт расползаться функционалу по нескольким старым установщикам. Legacy/old_go и старая IPK/feed схема остаются для совместимости, но не должны определять архитектуру v2.

---

## 2. Добавить единый будущий вход `install.sh`

Сейчас основной вход — `xray_vless_failover_auto_latest.sh`. В будущем нужен более простой и понятный публичный вход: `install.sh`.

### Нужно сделать

- [x] Создать `install.sh` в корне репозитория.
- [x] На первом этапе сделать `install.sh` безопасным wrapper на текущий `auto_latest`.
- [x] Добавить скрытый экспериментальный direct-install запуск `--direct-experimental`.
- [x] Добавить безопасный direct-install detection запуск `--direct-detect-only`.
- [ ] На втором этапе перенести в `install.sh` полноценную v2-логику direct-install.
- [ ] После проверки на реальном роутере сделать direct-install не скрытым режимом.
- [x] Сохранить совместимость со старой командой `xray_vless_failover_auto_latest.sh`.
- [ ] Позже сделать `xray_vless_failover_auto_latest.sh` тонким wrapper на `install.sh`.
- [x] Поддержать текущие параметры через pass-through в `auto_latest`:
  - [x] `--auto`
  - [x] `--go`
  - [x] `--minimal-go`
  - [x] `--detect-only`
  - [x] `--doctor`
  - [x] `--update-only`
  - [x] `--no-cron`
  - [x] `--no-restart`

### Будущая команда установки

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

### Описание

Пользователь должен видеть одну понятную команду установки. Старое имя остаётся рабочим для совместимости, но новая документация должна вести на `install.sh`.

---

## 3. Перейти к direct-install без обязательного IPK/feed

Для v2 целевой путь установки должен быть проще: без обязательного `.ipk`, без `Packages`, без `Packages.gz` и без отдельного Entware feed для `failover-go`.

### Нужно сделать

- [x] Считать direct-install целевой схемой v2.
- [x] Добавить experimental skeleton `scripts/xray-go-direct-install.sh`.
- [ ] Оставить IPK/feed как v1 compatibility mode, но не развивать его как основную архитектуру.
- [ ] Не удалять текущую IPK/feed-схему сразу, чтобы не сломать старые Full Go установки.
- [ ] Подготовить direct-install flow:
  - [x] определить архитектуру роутера;
  - [x] выбрать нужный Go binary release asset;
  - [x] скачать нужный Go binary в staging directory;
  - [x] проверить sha256 staged binary;
  - [ ] установить shell helpers полностью;
  - [ ] установить init.d scripts;
  - [ ] настроить cron при необходимости;
  - [x] создать/обновить manifest helper;
  - [x] записать informational direct-install plan;
  - [ ] выполнить first-run setup;
  - [ ] показать post-install checks.
- [ ] Подготовить direct-update flow через `xray-go update go`.
- [ ] Подготовить direct-uninstall/cleanup flow без `opkg remove failover-go`.

### Целевая схема

```text
install.sh
  -> detect arch
  -> detect /opt space
  -> choose full/minimal
  -> download binary/helpers directly
  -> install init.d/cron/config
  -> write manifest
  -> run first setup
```

### Что больше не должно быть обязательным для v2

```text
.ipk
Packages
Packages.gz
Entware feed registration
opkg install failover-go
opkg remove failover-go
```

### Описание

Direct-install убирает лишний упаковочный слой. Функционал остаётся, но установка и обновление становятся понятнее: всем управляет `install.sh` и `xray-go`, а не отдельный feed/opkg-пакет.

---

## 4. Добавить manifest установленной direct-install системы

Если отказаться от IPK как основного слоя, нужен собственный manifest, который заменит `opkg status failover-go` для v2.

### Нужно сделать

- [x] Добавить helper `scripts/xray-go-manifest.sh`.
- [x] Устанавливать helper как `/opt/bin/xray-go-manifest` при `xray-go update go` / repair Full Go линии.
- [x] Создавать manifest-файл на роутере при `xray-go update go` / repair Full Go линии:

```text
/opt/etc/xray/xray-go.manifest
```

- [x] Добавить experimental `--write-manifest` в direct-install skeleton.
- [ ] Создавать manifest-файл на роутере во время будущего полноценного direct-install.
- [x] Определить безопасный формат manifest без raw VLESS/subscription secrets.
- [ ] Хранить в manifest:
  - [x] install mode: `direct` или `opkg`;
  - [x] edition: `full` или `minimal`;
  - [x] version;
  - [x] architecture;
  - [x] installed_at;
  - [x] source commit/tag/channel;
  - [x] binary path;
  - [x] binary sha256;
  - [x] enabled modules;
  - [x] last update time.
- [x] Добавить `xray-go manifest`.
- [x] Добавить manifest summary в `xray-go doctor --support`.
- [ ] Научить `vless-go-doctor` читать manifest напрямую.
- [ ] Научить `xray-go version` показывать manifest summary.
- [x] Научить `xray-go update go` обновлять manifest через `xray-go-installer-update`.

### Описание

Manifest нужен, чтобы direct-install оставался управляемым: можно понять, что установлено, откуда, какой версии и какие файлы принадлежат проекту.

---

## 5. Упростить README

README должен быть коротким входом для пользователя, а не полным архивом всех старых вариантов.

### Нужно сделать

- [ ] В начало README поставить только рекомендуемую установку через `install.sh`.
- [ ] Основной сценарий описывать через `install.sh`.
- [ ] Упомянуть `auto_latest` как совместимый старый вход текущей Go-линии.
- [ ] Убрать перегруз legacy-инструкциями из основной части.
- [ ] Создать отдельный документ `docs/legacy.md`.
- [ ] Перенести подробности по legacy/old_go в `docs/legacy.md`.
- [x] Добавить отдельный документ `docs/direct-install.md`.
- [x] Описать experimental direct-install skeleton в `docs/direct-install.md`.
- [ ] Добавить короткую архитектурную схему:

```text
install.sh
  -> direct-install v2
  -> Full Go
  -> Minimal Go
  -> xray-go
```

### Описание

README должен помогать быстро установить и проверить работу. Всё старое и редкое лучше держать в отдельных документах.

---

## 6. Сделать `xray-go` главным интерфейсом управления

`xray-go` должен стать единой командой для пользователя.

### Уже есть

- [x] `xray-go status`
- [x] `xray-go doctor`
- [x] `xray-go menu`
- [x] `xray-go history`
- [x] `xray-go logs`
- [x] `xray-go recover`
- [x] `xray-go update`
- [x] `xray-go update-core`
- [x] `xray-go switch`
- [x] `xray-go cleanup`
- [x] `xray-go version`
- [x] `xray-go manifest`

### Нужно добавить или улучшить

- [ ] `xray-go module list`
- [ ] `xray-go module enable web-ui`
- [ ] `xray-go module disable web-ui`
- [ ] `xray-go module enable agent`
- [ ] `xray-go module disable agent`
- [ ] `xray-go agent status`
- [ ] `xray-go web status`
- [ ] `xray-go uninstall --dry-run`

### Описание

Низкоуровневые команды можно оставить, но пользователь должен чаще всего работать только через `xray-go`.

---

## 7. Привести Full Go и Minimal Go к общей логике

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
- [ ] Сделать direct-install общим базовым flow для Full и Minimal.

### Описание

Minimal должен оставаться лёгким и надёжным. Full должен быть расширенным вариантом с подписками, watchdog, recovery и диагностикой.

---

## 8. Спроектировать единый state/config слой

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
- [ ] Как manifest должен связываться с config/state.

### Целевая структура

```text
/opt/etc/xray/xray-go.conf
/opt/etc/xray/xray-go.state
/opt/etc/xray/xray-go.manifest
```

### Описание

Doctor, watchdog, recovery, agent и Web UI должны читать одну и ту же правду. Это упростит диагностику и уменьшит количество edge-case ошибок.

---

## 9. Web UI оставить опциональным модулем

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

## 10. Agent и Control Server оставить опциональными

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

## 11. Улучшить Doctor и Support mode

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
Install mode:
Edition:
Version:
Recovery:
Watchdog:
Proxy0:
Xray:
Cron:
```

- [ ] Проверить, что в support output не попадают raw VLESS links.
- [ ] Проверить, что в support output не попадают subscription URLs.
- [ ] Проверить, что JSON summary стабилен для Web UI / Agent / Control Server.
- [x] Добавить manifest summary без приватных данных в `xray-go doctor --support`.

### Описание

Doctor должен быстро показывать проблему, а support mode должен быть безопасным для копирования в чат или issue.

---

## 12. Сделать обновления предсказуемыми

Обновление разных частей проекта должно быть явно разделено.

### Нужно сделать

- [ ] Разделить update targets:
  - [ ] Go edition direct-install files
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
- [x] Обновлять manifest после успешного `xray-go update go` / Full Go repair.
- [ ] Для старых opkg/IPK установок показывать совместимый upgrade path.

### Описание

Обновление должно быть безопасным: код можно обновить, но пользовательские настройки нельзя случайно потерять.

---

## 13. Минимизировать количество публичных скриптов в корне

Корень репозитория должен быть понятным.

### Нужно сделать

- [ ] В корне оставить основные публичные входы:
  - [ ] `README.md`
  - [ ] `TODO.md`
  - [x] `install.sh`
  - [ ] `xray_vless_failover_auto_latest.sh`
  - [ ] текущие Full/Minimal Go installers, пока они нужны для совместимости
- [ ] Всё вспомогательное держать в:
  - [ ] `scripts/`
  - [ ] `cmd/`
  - [ ] `docs/`
  - [ ] `packaging/`
- [ ] Не трогать legacy/old_go в рамках этого пункта.
- [ ] Не делать IPK/feed обязательным публичным путём v2.

### Описание

Чем меньше файлов пользователь видит в корне, тем проще понять проект. Старые совместимые входы можно оставить, но новые инструкции должны вести по одному пути.

---

## 14. Проверить безопасность и восстановление

Проект управляет сетевой связностью роутера, поэтому recovery и rollback важнее красоты кода.

### Нужно проверить

- [ ] Recovery не создаёт reboot loop.
- [ ] Watchdog не ломает ручной switch.
- [ ] Failover корректно переключает primary -> backup.
- [ ] Возврат на primary работает только когда primary реально восстановился.
- [ ] Proxy0 refresh безопасен.
- [ ] Xray restart не затирает конфиг.
- [ ] `xray-go doctor --support` не раскрывает приватные данные.
- [x] Direct-install skeleton не заменяет рабочий бинарник при staging download.
- [ ] direct-install update не оставляет систему в полуобновлённом состоянии.
- [ ] При ошибке скачивания/sha256 direct-install должен откатываться или не трогать рабочие файлы.

### Описание

Любое упрощение не должно ухудшить надёжность. Сначала стабильность, потом компактность.

---

## 15. Документация по режимам

Нужно понятно объяснить, чем отличаются Full Go, Minimal Go и optional-модули.

### Нужно сделать

- [ ] `docs/install.md` — установка и первый запуск.
- [x] `docs/direct-install.md` — новая v2-схема без обязательного IPK/feed.
- [ ] `docs/modes.md` — Full Go vs Minimal Go.
- [ ] `docs/recovery.md` — recovery/watchdog/failover.
- [ ] `docs/web-ui.md` — Web UI.
- [ ] `docs/agent.md` — Agent.
- [ ] `docs/control-server.md` — Control Server.
- [ ] `docs/legacy.md` — legacy/old_go frozen archive.
- [ ] `docs/opkg-feed-v1.md` — старая IPK/feed схема совместимости.

### Описание

README должен быть коротким. Подробности должны жить в `docs/`.

---

## 16. Финальная цель v2

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

В финальной v2 пользователь не должен выбирать между множеством старых скриптов. Основной путь — `install.sh` для установки и `xray-go` для управления.
