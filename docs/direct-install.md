# Direct-install v2

Direct-install v2 — целевая схема установки Keenetic Xray Go без обязательного IPK/Entware feed слоя.

## Зачем это нужно

Старая Full Go линия использует Entware feed и пакет `failover-go`. Это рабочая схема совместимости, но она добавляет лишний упаковочный слой:

```text
.ipk
Packages
Packages.gz
opkg feed registration
opkg install failover-go
opkg remove failover-go
```

Для v2 цель другая: пользователь запускает один `install.sh`, а установщик напрямую скачивает нужные файлы, проверяет их и ставит в `/opt`.

## Целевая схема

```text
install.sh
  -> detect arch
  -> detect /opt space
  -> choose full|minimal
  -> download binary and helpers directly
  -> verify sha256 when checksum is available
  -> install /opt/bin helpers
  -> install init.d scripts
  -> configure cron when needed
  -> write /opt/etc/xray/xray-go.manifest
  -> run first setup
  -> print post-install checks
```

## Экспериментальный skeleton

Первый безопасный v2-шаг уже добавлен:

```text
scripts/xray-go-direct-install.sh
```

Он пока не заменяет рабочую установку. Его задача — проверить основу direct-install:

```text
- определить Entware architecture;
- выбрать release asset для Go resolver;
- показать direct-install plan;
- при необходимости скачать Go binary в staging directory;
- проверить sha256;
- опционально установить Go binary в target path;
- установить manifest helper;
- скачать и проверить shell helpers в staging directory;
- опционально установить shell helpers в /opt/bin и /opt/libexec;
- записать informational plan file;
- опционально записать manifest как direct-install.
```

Команды через публичный `install.sh`:

```sh
# Только detection, без изменений
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-detect-only

# Подготовить direct-install plan и установить manifest helper
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --prepare-only

# Скачать Go resolver в staging и проверить sha256, но не заменить рабочий бинарник
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --download-binary

# Скачать, проверить и явно установить Go resolver в /opt/bin/xray-failover-go
# Если старый бинарник уже есть, skeleton сохранит backup рядом: /opt/bin/xray-failover-go.bak.direct
# Важно: first-run setup всё ещё не выполняется.
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --install-binary

# Скачать shell helpers в staging и проверить sh -n, но не ставить их в /opt/bin
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --stage-helpers

# Явно установить shell helpers в /opt/bin и /opt/libexec
# Важно: first-run setup всё ещё не выполняется.
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --install-helpers
```

Файл плана:

```text
/opt/etc/xray/xray-go.direct-install.plan
```

Staging directory по умолчанию:

```text
/opt/tmp/xray-go-direct-install
```

Staged shell helpers:

```text
/opt/tmp/xray-go-direct-install/helpers
/opt/tmp/xray-go-direct-install/xray-go.helpers.index
```

В helper index сохраняются только служебные данные:

```text
mode|target_path|staged_path|sha256|label
```

Сейчас skeleton может установить следующие helper-команды:

```text
/opt/bin/xray-go
/opt/bin/vless-go-update
/opt/bin/vless-go-auto-update
/opt/bin/vless-go-failover
/opt/bin/vless-go-history
/opt/bin/vless-go-cleanup
/opt/bin/vless-go-recover
/opt/bin/vless-go-socks-auth
/opt/bin/failover-go
/opt/bin/vless-go-xray-core-update
/opt/bin/vless-go-doctor
/opt/libexec/vless-go-lock.sh
```

Важно: skeleton не выполняет first-run setup, не перезаписывает primary/backup sources и не заменяет стабильный `auto_latest` путь.

## Что остаётся от старой IPK/feed схемы

IPK/feed не удаляется сразу. Он остаётся v1 compatibility mode для существующих Full Go установок.

Правило:

```text
v1 compatibility:
  Entware feed + failover-go.ipk остаются рабочими

v2 target:
  direct-install становится основным путём развития
```

## Manifest вместо opkg status

После отказа от обязательного IPK нужен собственный manifest:

```text
/opt/etc/xray/xray-go.manifest
```

Он должен хранить безопасные служебные данные:

```text
SCHEMA
INSTALL_MODE=direct|opkg|unknown
EDITION=full|minimal|unknown
VERSION
ARCH
CHANNEL
SOURCE
BINARY_PATH
BINARY_SHA256
MODULES
INSTALLED_AT
LAST_UPDATE_AT
```

Manifest не должен хранить:

```text
raw vless:// links
subscription URLs
tokens
passwords
private keys
```

## Helper

Для manifest добавлен shell helper:

```sh
scripts/xray-go-manifest.sh
```

После установки он должен попадать в:

```text
/opt/bin/xray-go-manifest
```

Примеры:

```sh
xray-go-manifest init \
  --install-mode direct \
  --edition full \
  --version 0.2.0 \
  --arch mipsle \
  --channel main \
  --source main

xray-go-manifest summary
xray-go-manifest set VERSION 0.2.1
xray-go-manifest touch-update
```

## Связь с `xray-go`

`xray-go` уже умеет показывать manifest:

```sh
xray-go manifest
xray-go manifest summary
xray-go manifest show
xray-go manifest path
```

Также `xray-go doctor --support` показывает безопасный manifest summary, если helper доступен.

В дальнейшем `xray-go` должен уметь:

```sh
xray-go version
xray-go update go
xray-go uninstall --dry-run
```

## Безопасность обновления

Direct-install update должен быть атомарным насколько это возможно:

1. скачать файлы во временную директорию;
2. проверить shell syntax для helper-скриптов;
3. проверить sha256 для бинарников, если checksum доступен;
4. не трогать рабочие файлы при ошибке скачивания или проверки;
5. заменять файлы только после успешной проверки;
6. обновлять manifest только после успешной установки.

## Статус

На текущем этапе:

- `install.sh` существует как безопасный wrapper на `auto_latest` по умолчанию;
- `install.sh --direct-experimental` умеет запускать experimental skeleton;
- `install.sh --direct-detect-only` умеет проверять direct-install detection без изменений;
- `scripts/xray-go-direct-install.sh` добавлен;
- `scripts/xray-go-manifest.sh` добавлен;
- skeleton умеет staging download + sha256 verification через `--download-binary`;
- skeleton умеет явно устанавливать Go resolver через `--install-binary`;
- skeleton умеет скачивать и проверять shell helpers через `--stage-helpers`;
- skeleton умеет явно устанавливать shell helpers через `--install-helpers`;
- direct-install flow ещё не заменяет текущую Full Go установку;
- IPK/feed пока остаётся рабочей v1-схемой совместимости.
