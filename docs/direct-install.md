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

## Direct full orchestrator

Для сборки всех уже проверенных direct-install шагов в один понятный поток добавлен оркестратор:

```text
scripts/xray-go-direct-full.sh
```

Read-only dry-run:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-full-dry-run
```

Apply mode:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-full-experimental --yes
```

Apply mode требует явный `--yes`. Это защита от случайного запуска полного direct sequence.

В apply mode оркестратор запускает уже проверенные маленькие helpers в таком порядке:

```text
1. direct-install detect-only
2. install Go resolver binary from GitHub release asset with sha256 verification
3. install shell helpers after staging + sh -n verification
4. write direct manifest
5. run direct post-check
6. stage/install watchdog init/service layer
7. enable hourly recovery cron by marker
8. run direct-init post-check
9. print final xray-go commands for user validation
```

Важно: apply mode не выполняет first-run setup, не редактирует VLESS sources и не рестартует сервисы сам по себе.

## Experimental direct-install skeleton

Основной skeleton:

```text
scripts/xray-go-direct-install.sh
```

Он отвечает за binary/helper/manifest слой:

```text
- определить Entware architecture;
- выбрать release asset для Go resolver;
- показать direct-install plan;
- скачать Go binary в staging directory;
- проверить sha256;
- явно установить Go binary в target path;
- установить manifest helper;
- скачать и проверить shell helpers в staging directory;
- явно установить shell helpers в /opt/bin и /opt/libexec;
- записать informational plan file;
- записать manifest как direct-install;
- выполнить read-only post-check.
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

# Записать direct manifest
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --write-manifest -y

# Read-only проверка установленного direct слоя
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --post-check
```

## Direct init/service helper

Для init.d/service части добавлен отдельный helper:

```text
scripts/xray-go-direct-init.sh
```

Он отвечает только за service/init.d/cron слой. Он не переписывает VLESS sources, не запускает first-run setup и не рестартует сервисы сам по себе.

Команды:

```sh
# Скачать watchdog installer в staging и проверить sh -n, без установки
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --stage-watchdog-init

# Явно установить/обновить watchdog helper, init.d script и config
# Важно: VLESS sources и first-run setup не трогаются.
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --install-watchdog-init -y

# Включить hourly recovery cron через marker vless-go-hourly-recover
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --enable-recovery-cron --schedule '7 * * * *' -y

# Отключить hourly recovery cron, удалив только строку с marker vless-go-hourly-recover
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-experimental --disable-recovery-cron -y

# Read-only проверка service/init.d/cron слоя
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-post-check
```

Файл init-плана:

```text
/opt/etc/xray/xray-go.direct-init.plan
```

Staging directory для init:

```text
/opt/tmp/xray-go-direct-install/init
```

## Проверенные результаты на роутере

На реальном Keenetic с архитектурой `aarch64-3.10_kn` подтверждено:

```text
--direct-detect-only                          OK
--direct-experimental --stage-helpers         OK
--direct-experimental --install-binary        OK
--direct-experimental --write-manifest -y     OK
--direct-experimental --install-helpers       OK
--direct-experimental --post-check            OK=12 WARN=0 FAIL=0
--direct-init-experimental --stage-watchdog-init OK
--direct-init-experimental --install-watchdog-init -y OK
--direct-init-post-check                      OK=8 WARN=0 FAIL=0
--direct-init-experimental --enable-recovery-cron --schedule '7 * * * *' -y OK
--direct-full-dry-run                         OK, No changes made
watchdog restart after direct-init            OK
```

Также подтверждено:

```text
xray-go manifest                              OK
xray-go recover status                        health: OK
xray-go doctor --support                      SOCKS health-check OK, FAIL=0
```

## Файлы direct-install

Файл основного плана:

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
