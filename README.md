# Keenetic Xray Go

Компактный installer и набор helper-команд для Xray/VLESS failover на роутерах Keenetic с Entware.

Главная цель v2: один понятный вход установки (`install.sh`) и одна основная команда управления (`xray-go`), без обязательного IPK/feed слоя для новой direct-install линии.

---

## Рекомендуемая установка

Новая рекомендуемая точка входа:

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

Пока `install.sh` по умолчанию сохраняет совместимость с текущим Auto Latest selector. Direct-install v2 уже доступен отдельными явными командами и постепенно становится основным путём развития.

Проверить выбор installer без изменений:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --detect-only
```

Принудительно Full Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --go
```

Принудительно Minimal Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --minimal-go
```

Старый вход `xray_vless_failover_auto_latest.sh` остаётся рабочим для совместимости, но новая документация ведёт через `install.sh`.

---

## Direct-install v2

Direct-install v2 ставит Go resolver, shell helpers, manifest, watchdog init и recovery cron напрямую, без обязательного `.ipk`, `Packages`, `Packages.gz` и Entware feed для `failover-go`.

Безопасный preview полного direct-сценария:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-full-dry-run
```

Явный full direct apply:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-full-experimental --yes
```

Direct full apply не выполняет first-run setup и не редактирует VLESS sources. Он обновляет direct code layer и проверяет результат через post-check.

Проверки direct-install слоя:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --post-check
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-post-check
```

Подробности: `docs/direct-install.md`, `docs/direct-update.md`, `docs/direct-uninstall.md`, `docs/direct-uninstall-validation.md`.

---

## Управление через `xray-go`

Основной интерфейс управления:

```sh
xray-go status
xray-go doctor
xray-go doctor --support
xray-go menu
xray-go manifest
```

Обновление direct-mode установки:

```sh
xray-go update go --dry-run
xray-go update go
```

Recovery и watchdog:

```sh
xray-go recover status
xray-go recover enable-hourly
xray-go recover disable-hourly
xray-go logs watchdog
xray-go history
```

Обновление Xray-core и очистка:

```sh
xray-go update-core
xray-go cleanup --dry-run
xray-go cleanup
```

Безопасный preview удаления direct-install слоя:

```sh
xray-go uninstall --dry-run
```

`xray-go uninstall --dry-run` ничего не удаляет: он показывает, какие direct code files, metadata, staging, cron marker и init hook были бы затронуты, а пользовательские VLESS/config/log data остаются preserve-by-default.

---

## Что установлено в Full Go

Full Go подходит для обычной установки на USB/SSD или при достаточном месте во встроенной памяти.

Поддерживает:

- прямые `vless://` ссылки;
- HTTP/HTTPS subscription sources;
- выбор профиля из подписки;
- основной и резервный профиль;
- automatic failover;
- watchdog;
- quiet recovery для Proxy0/Xray/watchdog;
- history;
- cleanup;
- doctor/support diagnostics;
- update Go edition;
- update Xray-core;
- menu helper `failover-go`;
- единый wrapper `xray-go`.

Minimal Go остаётся лёгким профилем для роутеров с малым `/opt`: без тяжёлых зависимостей, без `python3`, без подписок и без cron, но с primary/backup, failover, Proxy0 и SOCKS5.

---

## Проверка работы

Базовая проверка:

```sh
xray-go manifest
xray-go recover status
xray-go doctor --support
```

Нормально, если итог doctor выглядит примерно так:

```text
FAIL=0
SOCKS health-check OK
Recovery health: OK
Install mode: direct
```

Ручной SOCKS-check без авторизации:

```sh
curl -k --socks5-hostname 192.168.1.1:10808 https://www.gstatic.com/generate_204 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n'
```

Если SOCKS auth включён, используй данные из `/opt/etc/xray/vless-go-socks-auth.conf`:

```sh
. /opt/etc/xray/vless-go-socks-auth.conf
curl -fsS \
  --socks5-hostname 127.0.0.1:10808 \
  --proxy-user "$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS" \
  --connect-timeout 5 \
  --max-time 10 \
  http://cp.cloudflare.com/generate_204 \
  -o /dev/null && echo "SOCKS auth health OK"
```

---

## Optional Web UI

Web UI не входит в базовую установку и ставится отдельно:

```sh
vless-go-web-install
```

Для существующих установок:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/vless-go-web-install.sh | sh
```

Web UI должен быть доступен только в доверенной локальной сети. Подробности: `docs/web-ui.md`.

---

## Совместимость v1: IPK/feed и legacy

IPK/feed остаётся v1 compatibility mode для существующих Full Go установок. Новая v2-линия развивается вокруг direct-install.

Legacy и old_go считаются frozen archive:

- не переписываются;
- не оптимизируются;
- не являются основным путём новой установки;
- остаются как fallback для старых систем.

Подробности:

- `docs/opkg-feed-v1.md`
- `docs/legacy.md`

---

## Требования

- роутер Keenetic;
- установленный Entware;
- компонент KeeneticOS `Proxy client`;
- SSH-доступ к роутеру;
- доступ в интернет с роутера.

---

## Логи и история

```sh
xray-go logs watchdog
xray-go logs watchdog --follow
xray-go history
xray-go history --follow
tail -n 80 /opt/var/log/vless-go-recover.log
```

History и support diagnostics не должны хранить raw VLESS URL, UUID, server address или subscription URL.

---

## Если мало места в `/opt`

Проверь свободное место:

```sh
df -h /opt
```

Безопасный preview очистки:

```sh
xray-go cleanup --dry-run
```

Очистка:

```sh
xray-go cleanup
```

После очистки можно снова запустить installer через `install.sh`. Auto Latest выберет Full Go или Minimal Go по текущему состоянию `/opt`.
