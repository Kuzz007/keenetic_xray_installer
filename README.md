# Keenetic Xray VLESS Installer

Минималистичный установщик Xray/VLESS для роутеров Keenetic с Entware.

> Проверено на `aarch64`. На `mipsel` может потребоваться больше свободного места в `/opt` для установки `xray-core`.

## Возможности

- установка `xray` / `xray-core` из Entware;
- настройка VLESS по готовой ссылке;
- генерация `/opt/etc/xray/config.json`;
- создание init-скрипта `/opt/etc/init.d/S24xray`;
- запуск локального SOCKS5 на LAN-IP роутера;
- создание Keenetic Proxy interface `Proxy0`;
- включение SOCKS5 UDP;
- сохранение конфигурации Keenetic;
- failover между основной и резервной VLESS-ссылкой.

## Требования

- роутер Keenetic;
- установленный Entware;
- компонент KeeneticOS `Proxy client`;
- SSH-доступ к роутеру.

## Быстрый старт

### Обычная установка

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-vless-auto-install.sh | sh
```

### Установка с failover

```sh
opkg update && \
opkg install curl ca-bundle && \
curl -fsSL -o /opt/tmp/xray_vless_failover_auto.sh \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto.sh && \
sh -n /opt/tmp/xray_vless_failover_auto.sh && \
chmod +x /opt/tmp/xray_vless_failover_auto.sh && \
/opt/tmp/xray_vless_failover_auto.sh
```

## Как работает failover

Failover-версия использует две VLESS-ссылки:

| Профиль | Назначение |
| --- | --- |
| `Primary` | основная ссылка |
| `Backup` | резервная ссылка |

Сценарий переключения:

1. `Primary` работает -> используется основной профиль.
2. `Primary` недоступен -> проверяется `Backup`.
3. `Backup` доступен -> Xray переключается на резервный профиль.
4. `Primary` восстановился -> Xray возвращается на основной профиль.

Логи переключений:

```sh
tail -f /opt/var/log/xray-vless-failover.log
```

## Управление

### Xray

```sh
/opt/etc/init.d/S24xray start
/opt/etc/init.d/S24xray stop
/opt/etc/init.d/S24xray restart
/opt/etc/init.d/S24xray status
```

### Xray Failover

```sh
/opt/etc/init.d/S25xray-failover start
/opt/etc/init.d/S25xray-failover stop
/opt/etc/init.d/S25xray-failover restart
/opt/etc/init.d/S25xray-failover status
```

## Смена VLESS-ссылок

Обычный режим:

```sh
vless-update
```

Failover-режим:

```sh
vless-failover-update
```

Proxy-подключение при этом остаётся прежним, меняется только Xray-конфиг.

## Обновления

### Обновить установщик

Обычный режим:

```sh
installer-update
```

Failover-режим:

```sh
failover-installer-update
```

Команда обновления установщика не просит заново вставлять VLESS-ссылку.

### Проверить версию Xray

```sh
/opt/bin/xray version
```

### Обновить Xray-core до stable/latest

```sh
opkg update && opkg install curl ca-bundle unzip && curl -fsSL -o /opt/tmp/xray-core-update.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-core-update.sh && chmod +x /opt/tmp/xray-core-update.sh && /opt/tmp/xray-core-update.sh --stable --no-backup
```

### Обновить Xray-core до pre-release

```sh
opkg update && opkg install curl ca-bundle unzip && curl -fsSL -o /opt/tmp/xray-core-update.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-core-update.sh && chmod +x /opt/tmp/xray-core-update.sh && /opt/tmp/xray-core-update.sh --prerelease --no-backup
```

## DNS-over-TLS

Опционально можно добавить сторонние DoT upstream-серверы и сохранить конфигурацию:

```sh
ndmc -c "dns-proxy tls upstream 9.9.9.9 sni dns.quad9.net" \
&& ndmc -c "dns-proxy tls upstream 8.8.8.8 sni dns.google" \
&& ndmc -c "dns-proxy tls upstream 77.88.8.8 sni common.dot.dns.yandex.net" \
&& ndmc -c "system configuration save"
```

## Маршрутизация доменов

Установка списка доменов через Entware:

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL -o /opt/tmp/xray-keenetic-routes.sh https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-keenetic-routes.sh && chmod +x /opt/tmp/xray-keenetic-routes.sh && /opt/tmp/xray-keenetic-routes.sh install && xray-routes-sync
```

Удаление списка:

```sh
xray-routes-clear
```

## Если мало места в `/opt`

```sh
rm -rf /opt/tmp/* /opt/var/opkg-lists/* /opt/var/cache/* && df -h /opt
```
