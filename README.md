# Keenetic Xray VLESS Auto Installer

Автоматический установщик Xray/VLESS Failover для роутеров Keenetic с Entware.

## Рекомендуемая установка: Auto Latest

Если ставишь впервые — используй **Auto Latest**. Он сам выбирает подходящую Go-линию установки:

- если места в `/opt` достаточно — ставит Full Go/Entware через latest feed;
- если места мало — ставит Minimal Go без `python3` и без Entware feed package;
- legacy-скрипты сохранены ниже для старых установок и ручного fallback.

Рекомендуемая команда:

```sh
opkg update && opkg install curl && opkg upgrade && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh
```

Принудительно Full Go/Entware:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --go
```

Принудительно Minimal Go для роутеров с малым `/opt`:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --minimal-go
```

## Что делать после установки

Для Full Go/Entware основной вход — единая команда `xray-go`:

```sh
xray-go status
xray-go doctor
xray-go menu
```

Полезные команды Full Go/Entware:

```sh
xray-go recover status
xray-go recover enable-hourly
xray-go history
xray-go logs watchdog
xray-go update
xray-go update-core
xray-go cleanup --dry-run
```

Низкоуровневые команды также остаются доступны:

```sh
failover-go
vless-go-doctor
vless-go-failover
vless-go-history
vless-go-cleanup
vless-go-recover
vless-go-xray-core-update
xray-go-installer-update
```

Для Minimal Go используются лёгкие команды:

```sh
minimal-go-status
minimal-go-switch primary
minimal-go-switch backup
```

Если неизвестно, какая линия установилась, проверь так:

```sh
if command -v xray-go >/dev/null 2>&1; then
    xray-go status
elif command -v minimal-go-status >/dev/null 2>&1; then
    minimal-go-status
else
    echo "Go-команда статуса не найдена. Проверь вывод установщика."
fi
```

## Тихое восстановление без SSH

Full Go/Entware включает recovery helper для случаев, когда Proxy0, Xray или watchdog зависли, но к роутеру не хочется подключаться по SSH вручную.

Включить ежечасную тихую проверку:

```sh
xray-go recover enable-hourly
```

Проверить статус:

```sh
xray-go recover status
```

Отключить:

```sh
xray-go recover disable-hourly
```

Поведение hourly recovery:

```text
если SOCKS/Xray health OK:
  ничего не делает и не шумит

если health failed:
  1. refresh Proxy0: interface Proxy0 down/up
  2. restart Xray
  3. restart watchdog
  4. если active=primary и backup настроен — switch primary -> backup
  5. если всё равно плохо — пишет в лог, но НЕ ребутит роутер автоматически
```

Лог действий recovery:

```text
/opt/var/log/vless-go-recover.log
```

Router reboot намеренно не выполняется автоматически, чтобы не получить reboot loop при внешней проблеме у провайдера, DNS или upstream-сервера.

## Web-интерфейс выведен из проекта

Опциональный web-интерфейс (`vless-go-web`, порт 18088) удалён. Управление роутером
идёт через локальные команды `xray-go` по SSH и через Telegram control bot.

Если web UI был установлен раньше, он остаётся на роутере как отдельный сервис.
Снять его вручную:

```sh
/opt/etc/init.d/S27vless-go-web stop
rm -f /opt/etc/init.d/S27vless-go-web /opt/bin/vless-go-web /opt/bin/vless-go-web-install
rm -f /opt/etc/xray/vless-go-web.conf /opt/etc/xray/vless-go-web.token
```

## Legacy full/minimal-линия выведена из проекта

Старые shell-монолиты (`xray_vless_failover_auto.sh`, `xray_vless_failover.sh`,
`xray_vless_failover_minimal.sh`), их модульные исходники в `src/` и архив в `legacy/`
удалены из репозитория. Проект развивается только вокруг Go edition.

Для установки используй `install.sh` или `xray_vless_failover_auto_latest.sh`.

> Если понадобится поднять старую линию для разбора бага или восстановления
> древней установки — файлы доступны в истории git до коммита `1978766`.

## Возможности Auto Latest

- проверяет Entware и базовые пакеты;
- определяет свободное место в `/opt`;
- выбирает Full Go/Entware или Minimal Go;
- использует latest channel;
- поддерживает dry-run/check mode;
- показывает storage decision;
- умеет bootstrap `curl`/`ca-bundle` на чистом Entware;
- сохраняет legacy-скрипты доступными.

## Чем отличаются режимы

### Full Go/Entware

Full Go/Entware подходит для обычной установки на USB/SSD или при достаточном месте во встроенной памяти.

Поддерживает:

- прямые `vless://` ссылки;
- HTTP/HTTPS ссылки подписок;
- выбор профиля из подписки;
- основной и резервный профиль;
- автоматический failover;
- возврат на основной профиль после восстановления;
- тихое ежечасное recovery-восстановление Proxy0/Xray/watchdog;
- обновление VLESS-ссылок;
- обновление подписок;
- автообновление подписок через cron;
- watchdog;
- doctor;
- history;
- cleanup;
- обновление Go edition;
- обновление Xray-core;
- меню `failover-go`;
- единый wrapper `xray-go`;
- расширенный health-check.

### Minimal Go

Minimal Go предназначен для роутеров, где мало места в `/opt`.

Особенности:

- меньше зависимостей;
- без `python3`;
- без подписок;
- без cron;
- только прямые `vless://` ссылки;
- основной и резервный профиль сохраняются;
- failover работает;
- Proxy0 и SOCKS5 также настраиваются.

## Требования

- роутер Keenetic;
- установленный Entware;
- компонент KeeneticOS `Proxy client`;
- SSH-доступ к роутеру;
- доступ в интернет с роутера.

## Проверка работы

Для Full Go/Entware:

```sh
xray-go status
xray-go doctor
xray-go recover status
```

Ручной SOCKS-check:

```sh
curl -k --socks5-hostname 192.168.1.1:10808 https://www.gstatic.com/generate_204 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n'
```

Нормальный результат:

```text
http_code=204
```

## Логи и история

Для Full Go/Entware:

```sh
xray-go logs watchdog
xray-go logs watchdog --follow
xray-go history
xray-go history --follow
```

Recovery log:

```sh
tail -n 80 /opt/var/log/vless-go-recover.log
```

History не должен хранить raw VLESS URL, UUID, server address или subscription URL.

## Если мало места в `/opt`

Проверь свободное место:

```sh
df -h /opt
```

Для Full Go/Entware сначала посмотри безопасный preview очистки:

```sh
xray-go cleanup --dry-run
```

Затем выполни очистку:

```sh
xray-go cleanup
```

Для legacy/manual cleanup:

```sh
rm -rf /opt/tmp/* /opt/var/opkg-lists/* /opt/var/cache/*
opkg update
```

После очистки снова запусти Auto Latest. Он выберет Full Go/Entware или Minimal Go по текущему состоянию памяти.
