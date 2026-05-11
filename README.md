# Keenetic Xray VLESS Auto Installer

Автоматический установщик Xray/VLESS Failover для роутеров Keenetic с Entware.

## Экспериментальная установка: Auto Latest

> **Экспериментальный скрипт.** Новый auto-установщик использует latest-канал и сам выбирает подходящую Go-линию установки.
>
> - если места в `/opt` достаточно — ставит Full Go/Entware через latest feed;
> - если места мало — ставит Minimal Go без `python3` и без Entware feed package;
> - старые legacy-скрипты остаются доступными ниже и не заменены.

Рекомендуемая экспериментальная команда:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh
```

Принудительно Full Go/Entware:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --go
```

Принудительно Minimal Go для роутеров с малым `/opt`:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh | sh -s -- --minimal-go
```

После установки проверь состояние универсальной командой:

```sh
if command -v vless-go-doctor >/dev/null 2>&1; then
    vless-go-doctor
elif command -v minimal-go-status >/dev/null 2>&1; then
    minimal-go-status
else
    echo "No Go status command found. Check installer output."
fi
```

## Legacy auto-установщик

Главный legacy-скрипт проекта:

```text
xray_vless_failover_auto.sh
```

Он сам проверяет доступное место в `/opt` и предлагает подходящий вариант установки:

| Условие | Что предложит установщик |
| --- | --- |
| Места достаточно | `full`-версию с подписками, failover, обновлением ссылок и служебными командами |
| Места мало | `minimal`-версию для прямых `vless://` ссылок без тяжёлых зависимостей |

В корне репозитория оставлены три публичных legacy-скрипта:

| Скрипт | Назначение |
| --- | --- |
| `xray_vless_failover_auto.sh` | Legacy автоустановщик. Сам выбирает full или minimal по доступной памяти |
| `xray_vless_failover.sh` | Legacy full-установщик, который auto-скрипт использует при достаточном месте |
| `xray_vless_failover_minimal.sh` | Legacy minimal-установщик, который auto-скрипт предлагает при малом объёме `/opt` |

> Обычно вручную запускать `xray_vless_failover.sh` или `xray_vless_failover_minimal.sh` не нужно. Начинай с auto-установщика.

## Возможности auto-установщика

- проверяет Entware и базовые пакеты;
- определяет свободное место в `/opt`;
- выбирает подходящий режим установки;
- предлагает `full`, если памяти достаточно;
- предлагает `minimal`, если памяти мало;
- скачивает нужный installer из GitHub;
- проверяет shell-синтаксис перед запуском;
- запускает выбранный установщик.

## Чем отличаются режимы

### Full

Full-режим подходит для обычной установки на USB/SSD или при достаточном месте во встроенной памяти.

Поддерживает:

- прямые `vless://` ссылки;
- HTTP/HTTPS ссылки подписок;
- выбор профиля из подписки;
- основной и резервный профиль;
- автоматический failover;
- возврат на основной профиль после восстановления;
- обновление VLESS-ссылок;
- обновление подписок;
- автообновление подписок через cron;
- команду обновления установщика;
- меню `failover`;
- расширенный health-check.

### Minimal

Minimal-режим предназначен для роутеров, где мало места в `/opt`.

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

## Установка

Запусти legacy auto-установщик на роутере через SSH:

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL -o /opt/tmp/xray_vless_failover_auto.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto.sh && sh -n /opt/tmp/xray_vless_failover_auto.sh && chmod +x /opt/tmp/xray_vless_failover_auto.sh && /opt/tmp/xray_vless_failover_auto.sh
```

После запуска auto-установщик покажет доступное место и предложит подходящий вариант.

## Как работает failover

Установщик использует два профиля:

| Профиль | Назначение |
| --- | --- |
| Основной | основной VLESS или профиль из подписки в full-режиме |
| Резервный | запасной VLESS или профиль из подписки в full-режиме |

Сценарий работы:

1. Пока основной профиль доступен, используется он.
2. После заданного числа ошибок daemon проверяет резервный профиль.
3. Если резервный профиль доступен, Xray переключается на него.
4. Daemon продолжает проверять основной профиль.
5. После восстановления основной профиль снова становится активным.

## Команды после установки

### Статус

```sh
vless-failover-status
```

или меню:

```sh
failover
```

### Управление Xray

```sh
/opt/etc/init.d/S24xray start
/opt/etc/init.d/S24xray stop
/opt/etc/init.d/S24xray restart
/opt/etc/init.d/S24xray status
```

### Управление failover-daemon

```sh
/opt/etc/init.d/S25xray-failover start
/opt/etc/init.d/S25xray-failover stop
/opt/etc/init.d/S25xray-failover restart
/opt/etc/init.d/S25xray-failover status
```

### Обновить VLESS-ссылки

```sh
vless-failover-update
```

### Обновить подписки

Доступно в full-режиме:

```sh
vless-subscription-update
```

### Обновить установщик

```sh
failover-installer-update
```

Команда обновления установщика использует актуальный full installer:

```text
https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover.sh
```

## Проверка работы

```sh
vless-failover-status
curl -k --socks5-hostname 192.168.1.1:10808 https://www.gstatic.com/generate_204 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n'
```

Нормальный результат:

```text
http_code=204
```

## Логи

```sh
tail -f /opt/var/log/xray-vless-failover.log
```

История переключений:

```sh
cat /opt/var/log/xray-vless-switch-history.log
```

## Если мало места в `/opt`

Проверь свободное место:

```sh
df -h /opt
```

Очисти временные файлы и кэш Entware:

```sh
rm -rf /opt/tmp/* /opt/var/opkg-lists/* /opt/var/cache/*
opkg update
```

После очистки снова запусти auto-установщик. Он предложит full или minimal по текущему состоянию памяти.
