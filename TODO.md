# TODO: Keenetic Xray Go v2

Цель: сделать проект компактнее и понятнее без потери функций.

Главные решения:

- `legacy` и `old_go` остаются архивной линией и не трогаются.
- v2 строится вокруг `install.sh`, `auto_latest`, Full Go, Minimal Go и `xray-go`.
- Для v2 целевой путь — direct-install без обязательного `.ipk`/Entware feed.
- IPK/feed остаётся только как v1 compatibility mode для существующих установок.

---

## 0. Legacy / old_go frozen

- [ ] Не переписывать legacy/old_go.
- [ ] Не переносить оттуда логику в v2 без крайней необходимости.
- [ ] Описать в README: `legacy/old_go` frozen.
- [ ] Подробности вынести в `docs/legacy.md`.

---

## 1. Единый вход `install.sh`

- [x] Создать `install.sh`.
- [x] Сделать первый безопасный wrapper на `xray_vless_failover_auto_latest.sh`.
- [x] Сохранить pass-through текущих опций `auto_latest`.
- [x] Добавить скрытый `--direct-experimental`.
- [x] Добавить безопасный `--direct-detect-only`.
- [x] Добавить `--direct-init-experimental`.
- [x] Добавить `--direct-init-post-check`.
- [x] Добавить `--direct-full-dry-run`.
- [x] Добавить `--direct-full-experimental --yes`.
- [x] Добавить `--direct-uninstall-dry-run`.
- [x] Добавить guarded scaffold `--direct-uninstall-experimental --yes` без реального удаления.
- [ ] Позже перенести полноценную v2-логику direct-install в основной путь.
- [ ] После проверки на реальном роутере сделать direct-install не скрытым режимом.
- [ ] Позже сделать `xray_vless_failover_auto_latest.sh` тонким wrapper на `install.sh`.

---

## 2. Direct-install без обязательного IPK/feed

- [x] Принять direct-install как целевую v2-схему.
- [x] Добавить `scripts/xray-go-direct-install.sh`.
- [x] Detect Entware architecture.
- [x] Выбрать Go resolver release asset.
- [x] Скачать Go resolver в staging directory.
- [x] Проверить sha256 staged binary.
- [x] Установить Go resolver binary в target path через явный `--install-binary`.
- [x] Сохранять backup старого Go resolver binary.
- [x] Установить manifest helper.
- [x] Записать informational plan file.
- [x] Добавить `--stage-helpers`.
- [x] Скачать shell helpers в staging directory.
- [x] Проверить shell helpers через `sh -n`.
- [x] Создать helper index с target path и sha256.
- [x] Добавить явный `--install-helpers`.
- [x] Устанавливать shell helpers в `/opt/bin` и `/opt/libexec` только при явном `--install-helpers`.
- [x] Патчить staged doctor/recovery helpers для SOCKS auth-aware health-check.
- [x] Добавить read-only `--post-check`.
- [x] Добавить direct full dry-run orchestrator.
- [x] Подтвердить на роутере: direct full dry-run показывает готовый state и `No changes made`.
- [x] Добавить explicit direct full apply orchestrator, требующий `--yes`.
- [x] Подтвердить на роутере: direct full apply завершается успешно.
- [x] Подтвердить на роутере: direct full apply сохраняет `Post-check summary: OK=12 WARN=0 FAIL=0`.
- [x] Подтвердить на роутере: direct full apply сохраняет `Direct-init post-check summary: OK=8 WARN=0 FAIL=0`.
- [x] Подтвердить на роутере: `xray-go recover status` показывает `health: OK` после full apply.
- [x] Подтвердить на роутере: `xray-go doctor --support` показывает `SOCKS health-check OK` и `FAIL=0` после full apply.
- [x] Подтвердить на роутере: direct post-check показывает `OK=12 WARN=0 FAIL=0`.
- [x] Добавить отдельный direct-init helper для service/init слоя.
- [x] Добавить direct-init read-only post-check.
- [x] Настроить recovery cron через direct-init helper.
- [x] Подтвердить на роутере: direct-init post-check показывает `OK=8 WARN=0 FAIL=0`.
- [x] Установить/обновить watchdog init layer через `--install-watchdog-init -y`.
- [x] Подтвердить на роутере: watchdog restart после direct-init сохраняет recovery `health: OK`.
- [x] Подготовить direct-update через `xray-go update go`.
- [x] Подтвердить на роутере: `xray-go update go --dry-run` запускает direct full dry-run и не меняет систему.
- [x] Подтвердить на роутере: `xray-go update go` запускает direct full apply и завершается успешно.
- [x] Подтвердить на роутере: после `xray-go update go` manifest direct, recovery `health: OK`, doctor `FAIL=0`.
- [x] Добавить direct-uninstall dry-run planner.
- [x] Добавить `xray-go uninstall --dry-run` для direct manifest.
- [x] Подтвердить на роутере: `xray-go uninstall --dry-run` печатает план и не меняет систему.
- [x] Добавить guarded uninstall apply scaffold, который требует `--yes`, но пока не удаляет файлы.
- [x] Подтвердить на роутере: guarded uninstall apply scaffold принимает `--yes` и завершает `No changes made`.
- [ ] Выполнить first-run setup.
- [ ] Показать финальные post-install checks после полного direct-install как default flow.
- [ ] Подготовить реальный direct-uninstall/cleanup apply без `opkg remove failover-go`.

---

## 3. Manifest direct-install системы

- [x] Добавить `scripts/xray-go-manifest.sh`.
- [x] Устанавливать helper как `/opt/bin/xray-go-manifest`.
- [x] Добавить `/opt/etc/xray/xray-go.manifest`.
- [x] Добавить experimental `--write-manifest`.
- [x] Добавить `xray-go manifest`.
- [x] Добавить manifest summary в `xray-go doctor --support`.
- [x] Обновлять manifest при `xray-go update go` / Full Go repair.
- [x] Подтвердить manifest на роутере в direct mode.
- [x] Создавать manifest во время full direct apply.
- [ ] Научить `vless-go-doctor` читать manifest напрямую.
- [ ] Научить `xray-go version` показывать manifest summary.

Manifest не должен хранить приватные источники, токены, пароли или ключи.

---

## 4. `xray-go` как главный интерфейс

Уже есть:

- [x] `xray-go status`
- [x] `xray-go doctor`
- [x] `xray-go menu`
- [x] `xray-go history`
- [x] `xray-go logs`
- [x] `xray-go recover`
- [x] `xray-go update`
- [x] `xray-go update go --dry-run`
- [x] `xray-go update go` direct-aware path для direct manifest.
- [x] `xray-go update-core`
- [x] `xray-go switch`
- [x] `xray-go cleanup`
- [x] `xray-go version`
- [x] `xray-go manifest`
- [x] `xray-go uninstall --dry-run`

Нужно добавить:

- [ ] `xray-go module list`
- [ ] `xray-go module enable web-ui`
- [ ] `xray-go module disable web-ui`
- [ ] `xray-go module enable agent`
- [ ] `xray-go module disable agent`
- [ ] `xray-go agent status`
- [ ] `xray-go web status`

---

## 5. Full Go и Minimal Go как профили

```text
minimal = core + xray + primary/backup + failover + Proxy0/SOCKS5
full    = minimal + subscriptions + cron + watchdog + recovery + doctor + history + cleanup + update-core
```

- [ ] Описать Full Go и Minimal Go как профили.
- [ ] Не добавлять тяжёлые зависимости в Minimal Go.
- [ ] Сохранить автоматический выбор режима по свободному месту в `/opt`.
- [ ] Сохранить ручной выбор через `--go` и `--minimal-go`.
- [ ] Сделать direct-install общим базовым flow для Full и Minimal.

---

## 6. State/config слой

Целевая структура:

```text
/opt/etc/xray/xray-go.conf
/opt/etc/xray/xray-go.state
/opt/etc/xray/xray-go.manifest
```

- [ ] Проверить active slot.
- [ ] Проверить primary/backup profiles.
- [ ] Проверить Minimal Go state.
- [ ] Проверить recovery/watchdog state.
- [ ] Проверить agent/web/control-server state.
- [ ] Связать manifest с config/state.

---

## 7. Optional modules

Web UI:

- [ ] Не включать по умолчанию.
- [ ] Управлять через `xray-go module`.
- [ ] Добавить `xray-go web status`.
- [ ] Документировать доступ только из доверенной локальной сети.

Agent / Control Server:

- [ ] Не включать по умолчанию.
- [ ] Описать как расширенный режим.
- [ ] Добавить `xray-go agent status`.
- [ ] Не смешивать router installer и внешний control-server.

---

## 8. Doctor / Support mode

- [ ] Сохранить `xray-go doctor`.
- [ ] Сохранить `xray-go doctor --support`.
- [ ] Сохранить `xray-go doctor --json`.
- [x] Добавить manifest summary в support output.
- [x] Сделать SOCKS auth-aware health-check для doctor через direct staged helper patch.
- [x] Подтвердить support output: `SOCKS health-check OK`, `FAIL=0`.
- [ ] Добавить summary: OK/WARN/FAIL, active slot, install mode, edition, version, recovery, watchdog, Proxy0, Xray, cron.
- [ ] Проверить, что support output не раскрывает приватные данные.

---

## 9. Updates

- [ ] Разделить update targets:
  - [x] Go edition direct-install files.
  - [ ] Xray-core.
  - [ ] Web UI.
  - [ ] Agent.
  - [ ] Control Server.
- [x] Добавить direct-aware `xray-go update go`.
- [x] Добавить `xray-go update go --dry-run`.
- [x] Подтвердить на роутере: `xray-go update go --dry-run` работает через direct full dry-run.
- [x] Подтвердить на роутере: `xray-go update go` работает через direct full apply.
- [ ] Добавить:
  - [ ] `xray-go update xray-core`.
  - [ ] `xray-go update web-ui`.
  - [ ] `xray-go update agent`.
- [x] Не менять пользовательские профили при safe update direct path.
- [x] Не перезаписывать primary/backup sources при direct update.
- [x] Обновлять manifest после успешного `xray-go update go`.

---

## 10. Документация

- [ ] Обновить README под `install.sh`.
- [x] Добавить `docs/direct-install.md`.
- [x] Добавить `docs/direct-update.md`.
- [x] Добавить `docs/direct-uninstall.md`.
- [x] Добавить `docs/direct-uninstall-validation.md`.
- [x] Описать direct full dry-run/apply orchestrator.
- [x] Описать direct-aware `xray-go update go`.
- [x] Описать direct uninstall dry-run planner.
- [x] Описать guarded uninstall apply scaffold.
- [x] Описать `--stage-helpers` и `--install-helpers`.
- [x] Описать direct-init helper и recovery cron management.
- [x] Зафиксировать router validation для full direct apply.
- [x] Зафиксировать router validation для direct-aware update.
- [x] Зафиксировать router validation для direct uninstall dry-run.
- [x] Зафиксировать router validation для guarded uninstall apply scaffold.
- [ ] Добавить `docs/install.md`.
- [ ] Добавить `docs/modes.md`.
- [ ] Добавить `docs/recovery.md`.
- [ ] Добавить `docs/legacy.md`.
- [ ] Добавить `docs/opkg-feed-v1.md`.

---

## 11. Безопасность и rollback

- [x] Staging download не заменяет рабочий бинарник.
- [x] Shell helpers не устанавливаются без явного `--install-helpers`.
- [x] Go resolver binary не устанавливается без явного `--install-binary`.
- [x] Direct full apply требует явный `--yes`.
- [x] Direct uninstall dry-run не меняет систему.
- [x] Guarded uninstall apply scaffold требует явный `--yes`, но пока не удаляет файлы.
- [x] Guarded uninstall apply scaffold подтверждён на роутере как `No changes made`.
- [x] При установке Go resolver сохраняется backup.
- [x] Recovery health-check с SOCKS auth подтверждён как OK.
- [x] Direct-init post-check подтверждает watchdog/recovery/cron без ошибок.
- [x] Watchdog init reinstall подтверждён без поломки recovery health.
- [x] Full direct apply подтверждён без редактирования VLESS sources и без first-run setup.
- [x] Direct-aware `xray-go update go` подтверждён без редактирования VLESS sources и без first-run setup.
- [ ] При ошибке скачивания или проверки рабочие файлы не должны меняться.
- [ ] Direct-install update не должен оставлять систему в полуобновлённом состоянии.
- [ ] Реальный uninstall apply должен сохранять user/runtime data по умолчанию.
- [ ] Recovery не должен создавать reboot loop.
- [ ] Xray restart не должен затирать конфиг.

---

## 12. Финальная цель v2

Установка:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

Управление:

```sh
xray-go status
xray-go doctor
xray-go menu
xray-go switch primary
xray-go switch backup
xray-go recover status
xray-go update go
xray-go uninstall --dry-run
```

Пользователь не должен выбирать между множеством старых скриптов. Основной путь — `install.sh` для установки и `xray-go` для управления.
