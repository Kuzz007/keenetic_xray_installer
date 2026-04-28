# Keenetic Xray VLESS Auto Installer

Автоматическая установка Xray из Entware на роутер Keenetic.
`Работоспособность проверена на aarch64. На mipsel может потребоваться больше свободного места в /opt для установки xray-core`.

Скрипт:

- устанавливает `xray` / `xray-core` из Entware;
- запрашивает VLESS-ссылку;
- парсит VLESS URI;
- создаёт `/opt/etc/xray/config.json`;
- создаёт Entware init-скрипт `/opt/etc/init.d/S24xray`;
- запускает Xray;
- поднимает локальный SOCKS5 на LAN-IP роутера;
- создаёт Keenetic Proxy interface `Proxy0`;
- включает SOCKS5 UDP;
- сохраняет конфигурацию Keenetic.
- 
 Failover-версия нужна, если есть две VLESS-ссылки:

- `Primary` — основная ссылка;
- `Backup` — резервная ссылка.
- Основной сценарий:
-`Primary работает ->` используется Primary
-`Primary упал ->` проверяется Backup
-`Backup доступен ->` переключение на Backup
-`Primary восстановился -> `возврат на Primary

Скрипт автоматически проверяет активную ссылку и переключает Xray на резервную, если основная перестала работать. Когда основная ссылка снова становится доступной, скрипт возвращает Xray обратно на `Primary`.
  

## Требования

- Keenetic router
- Установленный Entware
- Установленный компонент KeeneticOS: Proxy client
- SSH-доступ к роутеру

## Рекомендация: сторонние DoT DNS

Эта команда в Entware добавляет DNS-over-TLS upstream-серверы сохраняет конфигурацию.

```sh
ndmc -c "dns-proxy tls upstream 9.9.9.9 sni dns.quad9.net" \
&& ndmc -c "dns-proxy tls upstream 8.8.8.8 sni dns.google" \
&& ndmc -c "dns-proxy tls upstream 77.88.8.8 sni common.dot.dns.yandex.net" \
&& ndmc -c "system configuration save"
```
## Установка Xray

```sh
opkg update && opkg install curl ca-bundle && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-vless-auto-install.sh | sh
```
## Установка Xray-Failower

```sh
opkg update && opkg install curl ca-bundle python3 && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-vless-failover-install.sh | sh
```
Логи в реальном времени после настройки для проверки переключений

```sh
tail -f /opt/var/log/xray-vless-failover.log
```

## Управление Xray

```sh
/opt/etc/init.d/S24xray start
/opt/etc/init.d/S24xray stop
/opt/etc/init.d/S24xray restart
/opt/etc/init.d/S24xray status
```

## Управление Xray-Failower

```sh
/opt/etc/init.d/S25xray-failover status
/opt/etc/init.d/S25xray-failover stop
/opt/etc/init.d/S25xray-failover restart
/opt/etc/init.d/S25xray-failover status
```

## Смена Vless-ссылки Xray без переустановки

```sh
vless-update
```
## Смена Vless-ссылки Xray-Failover без переустановки

```sh
vless-failover-update
```

`Прокси подключение` при этом остаётся прежним, меняется только Xray-конфиг.

## Обновление скрипта Xray

```sh
installer-update
```
## Обновление скрипта Xray-Failover

```sh
failover-installer-update
```

При обновлении установщика команда `не просит заново вставлять Vless ссылку`.

