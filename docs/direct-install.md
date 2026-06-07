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

В дальнейшем `xray-go` должен уметь:

```sh
xray-go manifest
xray-go version
xray-go doctor --support
xray-go update go
```

и показывать manifest summary без приватных данных.

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

- `install.sh` существует как безопасный wrapper на `auto_latest`;
- `scripts/xray-go-manifest.sh` добавлен;
- direct-install flow ещё не заменяет текущую Full Go установку;
- IPK/feed пока остаётся рабочей v1-схемой совместимости.
