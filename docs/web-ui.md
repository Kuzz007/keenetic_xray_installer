# Опциональный VLESS Go Web UI

`vless-go-web` — опциональный web-dashboard для Full Go/Entware редакции.

Он не устанавливается и не запускается автоматически. Ставь его только если нужен браузерный интерфейс поверх существующих Full Go команд.

## Установка

В новых Full Go установках helper уже доступен как:

```sh
vless-go-web-install
```

Для существующих установок можно поставить напрямую из GitHub raw:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/vless-go-web-install.sh | sh
```

Если нужно добавить сам helper в `/opt/bin`, используй две отдельные команды:

```sh
curl -fsSL -o /opt/bin/vless-go-web-install https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/vless-go-web-install.sh
chmod +x /opt/bin/vless-go-web-install
```

## Открыть в браузере

После установки скрипт напечатает готовый LAN-адрес, например:

```text
Открой в браузере:
  http://192.168.1.1:18088/
```

По умолчанию сервис слушает:

```text
0.0.0.0:18088
```

Используй dashboard только в доверенной локальной сети. Не открывай этот порт в интернет.

## Layout dashboard

Интерфейс использует стиль Operations Console:

```text
Левое меню:
  Обзор
  Источники
  Failover
  Watchdog
  Обновления
  Диагностика
  Логи
  Настройки

Обзор:
  Активный слот
  Статус основного источника
  Статус резервного источника
  Статус watchdog
  Общий health badge

Основные панели:
  Управление failover
  Источники
  Selectors
  Watchdog
  Обновления
  Диагностика и обслуживание
  Логи и история
  Вывод команды
```

Dashboard остаётся одним self-contained Go binary. Ему не нужны Node, React, Python, внешний CSS или внешний JavaScript.

## Запуск и остановка

```sh
/opt/etc/init.d/S27vless-go-web start
/opt/etc/init.d/S27vless-go-web stop
/opt/etc/init.d/S27vless-go-web restart
/opt/etc/init.d/S27vless-go-web status
```

## Изменить адрес прослушивания

Открой конфиг:

```sh
vi /opt/etc/xray/vless-go-web.conf
```

Примеры:

```text
LISTEN="0.0.0.0:18088"
LISTEN="192.168.1.1:18088"
```

Затем перезапусти сервис:

```sh
/opt/etc/init.d/S27vless-go-web restart
```

## Токен

Form token создаётся во время установки и хранится здесь:

```text
/opt/etc/xray/vless-go-web.token
```

Токен используется внутренними формами UI для защиты POST-действий.

## Текущие возможности UI

Web UI открывает эти Full Go операции:

```text
Статус и диагностика:
  - обновить статус
  - статус watchdog
  - doctor

Переключение профилей:
  - переключить на основной
  - переключить на резервный

Управление профилями:
  - задать primary или backup VLESS/subscription URL
  - задать primary и backup selectors

Автоматизация:
  - обновить активный конфиг
  - запустить auto-update сейчас
  - включить/выключить возврат backup -> primary

Обслуживание:
  - перезапустить Xray
  - перезапустить watchdog
  - показать историю переключений
  - предпросмотр очистки
  - обновить Xray-core с backup
```

VLESS/URL источники принимаются формой, но не выводятся обратно на страницу.

UI использует существующие CLI helper’ы из `/opt/bin` и не заменяет их.

## Release assets

Workflow `Publish Go experimental release` публикует эти опциональные web UI binaries:

```text
vless-go-web-linux-arm64
vless-go-web-linux-arm64.sha256
vless-go-web-linux-mipsle
vless-go-web-linux-mipsle.sha256
```

Installer сам выбирает правильный asset из `latest` release по Entware architecture.
