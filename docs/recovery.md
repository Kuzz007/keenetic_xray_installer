# Recovery, watchdog и health-check

Этот документ описывает, как в Full Go/direct-install v2 устроены watchdog, quiet recovery и health-check.

## Коротко

Recovery нужен для ситуаций, когда Xray, Proxy0 или watchdog зависли, но роутер всё ещё доступен и может сам восстановить рабочее состояние.

Основные принципы:

- не делать reboot loop;
- не перезаписывать VLESS sources;
- учитывать SOCKS auth;
- чинить только известные runtime-слои: Proxy0, Xray, watchdog, active config;
- писать действия в лог и history;
- оставлять ручной контроль пользователю.

## Команды

Проверить состояние recovery:

```sh
xray-go recover status
```

Включить hourly recovery:

```sh
xray-go recover enable-hourly
```

Отключить hourly recovery:

```sh
xray-go recover disable-hourly
```

Проверить daemon watchdog:

```sh
/opt/etc/init.d/S26vless-go-watchdog status
vless-go-watchdog status
```

Проверить support diagnostics:

```sh
xray-go doctor --support
```

## Watchdog daemon

Watchdog — это runtime daemon, который регулярно проверяет SOCKS/Xray health и может переключить active slot с primary на backup при повторяющихся ошибках.

Основные файлы:

```text
/opt/bin/vless-go-watchdog
/opt/etc/init.d/S26vless-go-watchdog
/opt/etc/xray/vless-go-watchdog.conf
/opt/var/log/vless-go-watchdog.log
/opt/var/log/vless-go-watchdog-detail.log
```

Типовое поведение daemon:

```text
- checks SOCKS 127.0.0.1:10808;
- требует несколько failed cycles перед failover;
- после switch ждёт post-switch delay;
- backup -> primary auto recovery включён по умолчанию;
- Proxy0 refresh включён по умолчанию;
- router reboot не выполняется автоматически.
```

## Hourly recovery

Hourly recovery — это тихая cron-проверка, которая запускает `vless-go-recover` по расписанию и пытается восстановить runtime-состояние.

Cron marker:

```text
# vless-go-hourly-recover
```

Типовая строка:

```text
7 * * * * /opt/bin/vless-go-recover --quiet --mode full run # vless-go-hourly-recover
```

Direct-init helper управляет только строкой с этим marker и не должен трогать другие cron-задачи.

Проверить cron:

```sh
grep 'vless-go-hourly-recover' /opt/var/spool/cron/crontabs/root
```

## Что recovery может чинить

При failed health-check recovery может выполнять ограниченный набор действий:

```text
1. ensure/refresh Proxy0;
2. restart Xray;
3. restart watchdog daemon;
4. если active=primary и backup настроен — switch primary -> backup;
5. записать результат в log/history.
```

Recovery не должен:

```text
- удалять пользовательские VLESS sources;
- менять primary/backup sources без явного действия;
- удалять selector files;
- очищать config.json без необходимости;
- делать router reboot автоматически;
- включать infinite reboot/restart loop.
```

## SOCKS auth-aware health-check

Если SOCKS auth включён, health-check должен использовать данные из:

```text
/opt/etc/xray/vless-go-socks-auth.conf
```

Ручная проверка:

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

`vless-go-doctor` и `vless-go-recover` в direct helper flow патчатся как SOCKS-auth-aware, чтобы не получать ошибку:

```text
curl: (97) No authentication method was acceptable
```

## Direct-init validation

Direct-init post-check проверяет service/recovery слой:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-post-check
```

Ожидаемый итог:

```text
Direct-init post-check summary: OK=8 WARN=0 FAIL=0
recovery health OK
watchdog init status command works
recovery cron entry present
```

## Direct full validation

Direct full post-check проверяет весь direct code layer и runtime recovery:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --post-check
```

Ожидаемый итог:

```text
Post-check summary: OK=12 WARN=0 FAIL=0
recovery health: OK
manifest install mode: direct
```

## Логи

Recovery log:

```sh
tail -n 80 /opt/var/log/vless-go-recover.log
```

Watchdog log:

```sh
tail -n 80 /opt/var/log/vless-go-watchdog.log
```

Switch history:

```sh
xray-go history
```

Support diagnostics:

```sh
xray-go doctor --support
```

Support mode не должен печатать raw VLESS links, subscription URLs, UUID, passwords или private keys.

## Безопасные настройки

Backup -> primary auto recovery включён по умолчанию. Отключать можно так:

```sh
sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=0/' /opt/etc/xray/vless-go-watchdog.conf
/opt/etc/init.d/S26vless-go-watchdog restart
```

Proxy0 refresh после switch тоже включён по умолчанию. Отключить можно так:

```sh
sed -i 's/^PROXY0_REFRESH=.*/PROXY0_REFRESH=0/' /opt/etc/xray/vless-go-watchdog.conf
/opt/etc/init.d/S26vless-go-watchdog restart
```

## Troubleshooting

Проверить, что watchdog жив:

```sh
/opt/etc/init.d/S26vless-go-watchdog status
```

Проверить recovery:

```sh
xray-go recover status
```

Проверить SOCKS listener:

```sh
ss -lntp | grep ':10808' || netstat -lntp 2>/dev/null | grep ':10808'
```

Проверить doctor:

```sh
xray-go doctor --support
```

Если doctor показывает SOCKS auth error, сначала проверь ручной curl с `--proxy-user`, затем обнови direct helpers:

```sh
xray-go update go
```
