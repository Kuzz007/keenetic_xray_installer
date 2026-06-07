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

## Binary reuse fallback

Direct full update может пропустить скачивание Go resolver release asset, если установленный binary уже совпадает с manifest sha256.

Это нужно для ситуаций, когда `raw.githubusercontent.com` доступен, а `github.com/releases` временно не резолвится или недоступен. В таком случае update может продолжить обновление shell helpers, wrapper, manifest и init/cron layer без повторного скачивания уже актуального binary.

Ожидаемая строка:

```text
Skipping Go resolver download: installed binary already matches manifest sha256.
```

Если sha256 не совпадает или manifest sha256 отсутствует, direct full update по-прежнему пытается скачать и проверить release binary.

## Границы безопасности

Direct update использует уже проверенный full direct orchestrator:

- обновляет Go resolver через staging и sha256 verification, если binary не совпадает с manifest;
- может пропустить Go resolver download, если binary уже совпадает с manifest sha256;
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

Подтверждено на Keenetic / Entware `aarch64-3.10_kn`.

### Dry-run

```text
xray-go update go --dry-run
  -> Refreshing xray-go-direct-full...
  -> Mode: dry-run
  -> manifest install mode: direct
  -> manifest binary sha256 matches target
  -> recovery cron marker present
  -> Direct full dry-run complete. No changes made.
```

### Apply

```text
xray-go update go
  -> Refreshing xray-go-direct-full...
  -> Direct install mode detected. Running direct full update.
  -> direct post-check: OK=12 WARN=0 FAIL=0
  -> direct-init post-check: OK=8 WARN=0 FAIL=0
  -> Direct full apply complete.
  -> No first-run setup was executed.
  -> VLESS sources were not edited.
```

Финальная проверка после apply:

```text
xray-go manifest
  -> Install mode: direct
  -> Modules: manifest,direct-experimental,binary-present

xray-go recover status
  -> health: OK

xray-go doctor --support
  -> SOCKS health-check OK
  -> OK=50 WARN=2 FAIL=0
```

Также подтверждено до этого:

```text
--direct-full-experimental --yes
  -> direct post-check: OK=12 WARN=0 FAIL=0
  -> direct-init post-check: OK=8 WARN=0 FAIL=0
  -> No first-run setup was executed
  -> VLESS sources were not edited
```
