# Keenetic Xray VLESS Auto Installer

Автоматическая установка Xray из Entware на роутер Keenetic.

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

## Смена VLESS-ссылки без переустановки

```sh
vless-update
```

### Проверить после обновления

```sh
xray run -test -config /opt/etc/xray/config.json
```

```sh
/opt/etc/init.d/S24xray status
```

```sh
netstat -lntp | grep 10808
```

`Прокси подключение` при этом остаётся прежним, потому что меняется только Xray-конфиг.
