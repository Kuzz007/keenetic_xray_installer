# Direct-aware update

`xray-go update go` выбирает update path по manifest.

## Логика

```text
/opt/etc/xray/xray-go.manifest
  INSTALL_MODE="direct" -> direct full update
  другое/нет manifest     -> opkg-compatible update
```

Для direct-mode используется:

```text
scripts/xray-go-direct-full.sh --apply --yes --no-commands
```

Для проверки без изменений:

```sh
xray-go update go --dry-run
```

Для применения:

```sh
xray-go update go
```

## Границы безопасности

Direct update использует уже проверенный full direct orchestrator:

- обновляет Go resolver через staging и sha256 verification;
- обновляет shell helpers после `sh -n` проверки;
- пишет direct manifest;
- выполняет direct post-check;
- обновляет watchdog init/service layer;
- включает recovery cron по marker;
- выполняет direct-init post-check.

Он не должен:

- запускать first-run setup;
- редактировать VLESS sources;
- перезаписывать primary/backup sources;
- использовать opkg/IPK как обязательный слой direct-mode.

## Проверка на роутере

```sh
xray-go update go --dry-run
xray-go update go
xray-go manifest
xray-go recover status
xray-go doctor --support
```

Ожидаемый результат после direct update:

```text
manifest install mode: direct
recovery health: OK
doctor --support: FAIL=0
```

## Router validation

Подтверждено на Keenetic / Entware `aarch64-3.10_kn`:

```text
xray-go update go --dry-run
  -> Refreshing xray-go-direct-full...
  -> Mode: dry-run
  -> manifest install mode: direct
  -> manifest binary sha256 matches target
  -> recovery cron marker present
  -> Direct full dry-run complete. No changes made.
```

Также подтверждено до этого:

```text
--direct-full-experimental --yes
  -> direct post-check: OK=12 WARN=0 FAIL=0
  -> direct-init post-check: OK=8 WARN=0 FAIL=0
  -> No first-run setup was executed
  -> VLESS sources were not edited
```
