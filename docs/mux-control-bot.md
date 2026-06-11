# Mux control через Telegram-бот

Экспериментальная функция для управления Xray Mux/XUDP на роутере через control-bot и router-agent.

## Что меняется

Mux применяется только на стороне роутера, в клиентском Xray outbound из `/opt/etc/xray/config.json`.

Сервер 3x-ui не меняется.

Агент поддерживает действия:

- `mux_status` — показать текущий Mux и последний rollback backup;
- `mux_snapshot` — создать точку отката без изменения конфига;
- `mux_enable` — включить Mux/XUDP с выбранными параметрами;
- `mux_disable` — выключить Mux, удалив блок `mux`;
- `mux_rollback` — восстановить последний backup из `/opt/etc/xray/mux-backups`.

## Безопасность

При изменении Mux агент делает так:

1. Создаёт backup текущего `/opt/etc/xray/config.json` в `/opt/etc/xray/mux-backups`.
2. Меняет только подходящий `outbound`:
   - если указан `outbound_tag`, ищет его;
   - иначе берёт первый `protocol: vless`;
   - иначе первый не `freedom` и не `blackhole`.
3. Выполняет `xray run -test -config /opt/etc/xray/config.json`.
4. Перезапускает Xray через `/opt/etc/init.d/S24xray restart`.
5. Если config test или restart падает — восстанавливает backup и перезапускает Xray снова.

## Порядок теста на одном роутере

1. Обновить control-server на VPS:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-control-server-install.sh | sh -s -- --update-only --yes
```

2. В Telegram-боте открыть один тестовый роутер.
3. Нажать `🔁 Агент`.
4. Дождаться нового `agent_start` с версией `0.2.1-mux-rollback` и capability `mux_config`.
5. Открыть роутер снова, нажать `⚙️ Mux`.
6. Нажать `💾 Точка отката`.
7. Нажать `📍 Статус`.
8. Нажать `✅ ON 8`.
9. Проверить интернет, YouTube/Speedtest и обычный браузинг.
10. Если стало хуже — нажать `↩️ Откат`.

## Раскатка на все роутеры

После успешного теста на одном роутере:

1. В списке роутеров нажать массовое обновление агентов, если оно доступно.
2. Дождаться `agent_start` от каждого роутера.
3. На каждом роутере Mux включать отдельно через `⚙️ Mux`, сначала с `✅ ON 8`.

## Рекомендуемые значения

Для первого теста:

```json
{
  "enabled": true,
  "concurrency": 8,
  "xudpConcurrency": -1,
  "xudpProxyUDP443": "skip"
}
```

Если нужно осторожнее — `ON 4`.

Если много мелких соединений и всё стабильно — можно проверить `ON 16`.

`ON 32` — агрессивный экспериментальный пресет. Использовать только для сравнения на одном роутере, если `ON 8` и `ON 16` уже работают стабильно.

## Экспериментальные XUDP-пресеты

Кнопки `🧪 UDP 4`, `🧪 UDP 8`, `🧪 UDP 16`, `🧪 UDP 32` включают:

```json
{
  "enabled": true,
  "concurrency": 8,
  "xudpConcurrency": 8,
  "xudpProxyUDP443": "skip"
}
```

Число в кнопке меняет только `xudpConcurrency`.

`concurrency` для TCP при XUDP-пресетах фиксируется на `8`.

`xudpProxyUDP443` специально оставлен `skip`, чтобы не mux-ить UDP/443 QUIC/HTTP3 и снизить риск проблем с YouTube, Google, Cloudflare и браузерами.

`🧪 UDP off` возвращает безопасный режим:

```json
{
  "enabled": true,
  "concurrency": 8,
  "xudpConcurrency": -1,
  "xudpProxyUDP443": "skip"
}
```

## Отключение

Кнопка `❌ Выключить` удаляет блок `mux` из outbound и применяет конфиг через тот же безопасный цикл: backup, config test, restart, restore on failure.
