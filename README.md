# Keenetic Xray VLESS Installer

Минималистичный набор установщиков Xray/VLESS для роутеров Keenetic с Entware.

Проект оставляет в корне только основные публичные скрипты установки:

| Скрипт | Назначение |
| --- | --- |
| `xray_vless_failover.sh` | Полная версия с failover, подписками, обновлением ссылок и служебными командами |
| `xray_vless_failover_auto.sh` | Автоматический запуск установки failover-версии |
| `xray_vless_failover_minimal.sh` | Облегчённая версия для роутеров с малым объёмом `/opt` |

> Проверено на Keenetic + Entware. На устройствах с ограниченной встроенной памятью лучше начинать с minimal-версии.

## Возможности full-версии

- установка `xray` / `xray-core` из Entware;
- поддержка прямых `vless://` ссылок;
- поддержка HTTP/HTTPS ссылок подписок;
- генерация `/opt/etc/xray/config.json`;
- создание init-скрипта Xray;
- создание failover-daemon;
- автоматическое переключение между основным и резервным профилем;
- возврат на основной профиль после восстановления;
- настройка Keenetic `Proxy0`;
- SOCKS5 на `192.168.1.1:10808` или другом LAN-IP роутера;
- health-check через несколько `generate_204` endpoint-ов;
- команды статуса, обновления ссылок, подписок и установщика.

## Требования

- роутер Keenetic;
- установленный Entware;
- компонент KeeneticOS `Proxy client`;
- SSH-доступ к роутеру;
- доступ в интернет с роутера.

## Быстрый старт

### Рекомендуемая установка с failover

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL -o /opt/tmp/xray_vless_failover.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover.sh && sh -n /opt/tmp/xray_vless_failover.sh && chmod +x /opt/tmp/xray_vless_failover.sh && /opt/tmp/xray_vless_failover.sh
```

### Автоматическая установка

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL -o /opt/tmp/xray_vless_failover_auto.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto.sh && sh -n /opt/tmp/xray_vless_failover_auto.sh && chmod +x /opt/tmp/xray_vless_failover_auto.sh && /opt/tmp/xray_vless_failover_auto.sh
```

### Minimal-версия

Используй, если на роутере мало места в `/opt` или не нужен разбор подписок.

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL -o /opt/tmp/xray_vless_failover_minimal.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_minimal.sh && sh -n /opt/tmp/xray_vless_failover_minimal.sh && chmod +x /opt/tmp/xray_vless_failover_minimal.sh && /opt/tmp/xray_vless_failover_minimal.sh
```

## Как работает failover

Установщик использует два профиля:

| Профиль | Назначение |
| --- | --- |
| Основной | основной VLESS или профиль из подписки |
| Резервный | запасной VLESS или профиль из подписки |

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

```sh
vless-subscription-update
```

### Обновить установщик

```sh
failover-installer-update
```

Команда обновления установщика использует актуальный файл:

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

После этого запускай minimal-версию.

## Релизы

Текущая стабильная точка: `v005`.

Следующие изменения лучше выпускать отдельными релизами: `v006`, `v007` и дальше.
