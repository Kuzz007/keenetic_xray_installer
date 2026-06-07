# Direct-aware update

`xray-go update go` выбирает update path по manifest.

## Логика Go edition update

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

## Xray-core update target

`xray-go update xray-core` — отдельный update target для самого Xray-core. Он не обновляет direct-install layer, не меняет manifest direct-mode, не редактирует VLESS sources и не трогает recovery cron.

Read-only проверка без скачивания и без restart:

```sh
xray-go update xray-core --dry-run
```

Dry-run показывает:

```text
current Xray binary
current Xray version
current config validation
Xray init status
updater helper path
example apply commands
scope boundary
```

Примеры применения:

```sh
xray-go update xray-core --channel latest --yes
xray-go update xray-core --channel prerelease --yes --no-restart
xray-go update xray-core --tag vX.Y.Z --yes
```

Старый alias сохранён:

```sh
xray-go update-core --dry-run
xray-go update-core --channel latest --yes
```

Apply path передаёт параметры в низкоуровневый helper:

```text
/opt/bin/vless-go-xray-core-update
```

## Границы безопасности

Direct Go edition update использует уже проверенный full direct orchestrator:

- обновляет Go resolver через staging и sha256 verification, если binary не совпадает с manifest;
- может пропустить Go resolver download, если binary уже совпадает с manifest sha256;
- обновляет shell helpers после `sh -n` проверки;
- пишет direct manifest;
- выполняет direct post-check;
- обновляет watchdog init/service layer;
- включает recovery cron по marker;
- выполняет direct-init post-check.

Go edition update не должен:

- запускать first-run setup;
- редактировать VLESS sources;
- перезаписывать primary/backup sources;
- использовать opkg/IPK как обязательный слой direct-mode.

Xray-core update target не должен:

- менять direct-install manifest;
- менять Go resolver;
- менять `xray-go` helpers;
- редактировать VLESS sources;
- менять watchdog/recovery config;
- менять recovery cron marker.

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

Для Xray-core target:

```sh
xray-go update xray-core --dry-run
```

Ожидаемый результат dry-run:

```text
== Xray-core update dry-run ==
No changes made. No downloads, no service restart, no direct-install files modified.
Xray config valid
Scope boundary: this target updates only Xray-core.
```

## Router validation

Подтверждено на Keenetic / Entware `aarch64-3.10_kn`.

### Go edition dry-run

```text
xray-go update go --dry-run
  -> Refreshing xray-go-direct-full...
  -> Mode: dry-run
  -> manifest install mode: direct
  -> manifest binary sha256 matches target
  -> recovery cron marker present
  -> Direct full dry-run complete. No changes made.
```

### Go edition apply

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

### Go edition binary reuse fallback

```text
xray-go update go
  -> Skipping Go resolver download: installed binary already matches manifest sha256.
  -> shell helpers installed
  -> direct post-check: OK=12 WARN=0 FAIL=0
  -> direct-init post-check: OK=8 WARN=0 FAIL=0
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
