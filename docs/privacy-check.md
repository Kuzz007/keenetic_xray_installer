# Privacy check

`xray-go privacy-check` — read-only проверка diagnostic/support output на случайную утечку чувствительных данных.

## Команда

```sh
xray-go privacy-check
```

Первый запуск обновляет helper:

```text
/opt/bin/vless-go-privacy-check
```

## Что проверяется

Команда запускает диагностические команды во временные файлы и сканирует вывод.

Проверяемые команды:

```text
xray-go summary
xray-go version
xray-go doctor --support
vless-go-doctor
```

Проверяемые категории:

```text
raw proxy/VLESS-like URLs
UUID-like values
SOCKS password variable names
generic secret assignments
credentials in URLs
```

Сами найденные значения не печатаются. Показывается только категория и команда, в которой потенциально найден риск.

## Что не делает

`xray-go privacy-check` не меняет систему:

```text
не редактирует конфиги
не меняет cron
не перезапускает Xray
не перезапускает watchdog
не удаляет файлы
```

Временные файлы удаляются автоматически при выходе.

## Нормальный результат

```text
== Result ==
OK=... WARN=0 FAIL=0
Privacy check passed. Captured outputs are removed automatically.
```

## Если есть FAIL

Если проверка нашла риск:

1. Не отправляй diagnostic/support output публично.
2. Запусти более короткую проверку:

```sh
xray-go summary
```

3. Если нужно, проверяй проблемную команду вручную и редактируй вывод перед отправкой.

## Ограничения

Проверка ищет распространённые опасные паттерны. Она не является криптографической гарантией приватности, но помогает поймать основные ошибки: raw proxy links, UUID-like values, credentials in URLs и явные secret assignments.
