# Install guide

Пошаговая установка и проверка Keenetic Xray Go v2.

## 1. Требования

Нужно:

- Keenetic router;
- установленный Entware;
- компонент KeeneticOS `Proxy client`;
- SSH-доступ;
- доступ роутера в интернет.

Проверить `/opt`:

```sh
df -h /opt
```

Проверить `curl`:

```sh
command -v curl >/dev/null 2>&1 || opkg update && opkg install curl
```

## 2. Рекомендуемый вход

Основная команда установки:

```sh
opkg update && opkg install curl && curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh
```

Пока `install.sh` по умолчанию сохраняет совместимость с Auto Latest selector. Старый entrypoint `xray_vless_failover_auto_latest.sh` остаётся рабочим, но новая документация ведёт через `install.sh`.

Проверить выбор installer без изменений:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --detect-only
```

Принудительно Full Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --go
```

Принудительно Minimal Go:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --minimal-go
```

## 3. Direct-install v2 preview

Direct-install v2 — новая целевая схема без обязательного IPK/feed слоя.

Сначала безопасный dry-run полного direct flow:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-full-dry-run
```

Ожидаемый финал:

```text
Direct full dry-run complete. No changes made.
```

Dry-run ничего не скачивает в target paths, не меняет cron, не запускает first-run setup и не редактирует VLESS sources.

## 4. Direct-install v2 apply

Явный full direct apply:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-full-experimental --yes
```

Что делает apply:

```text
1. detect architecture
2. download Go resolver into staging
3. verify sha256
4. install Go resolver
5. stage shell helpers
6. run sh -n checks
7. install shell helpers
8. write direct manifest
9. run direct post-check
10. install/update watchdog init layer
11. enable recovery cron marker
12. run direct-init post-check
```

Что apply не делает:

```text
- не выполняет first-run setup;
- не редактирует VLESS sources;
- не перезаписывает primary/backup sources;
- не меняет subscription URLs;
- не запускает real uninstall.
```

## 5. Проверка после установки

Базовая проверка:

```sh
xray-go version
xray-go manifest
xray-go recover status
xray-go doctor --support
vless-go-doctor
```

Ожидаемый результат:

```text
Install mode: direct
health: OK
SOCKS health-check OK
FAIL=0
```

`xray-go version` показывает manifest summary, Go resolver version/sha256 и helper paths. `vless-go-doctor` также читает direct manifest напрямую и проверяет соответствие sha256 binary без raw VLESS/subscription data.

Ожидаемая секция в прямом `vless-go-doctor`:

```text
== Manifest ==
[OK] manifest найден: /opt/etc/xray/xray-go.manifest
[OK] manifest install mode: direct
[OK] manifest edition: full
[OK] manifest arch: aarch64-3.10_kn
[OK] manifest binary executable: /opt/bin/xray-failover-go
[OK] manifest binary sha256 matches target
```

Подтверждено на Keenetic `aarch64-3.10_kn`: после `xray-go update go` прямой `vless-go-doctor` показал manifest section, проверил sha256 и завершился `OK=57 WARN=2 FAIL=0`.

Проверка direct code layer:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-experimental --post-check
```

Ожидаемый финал:

```text
Post-check summary: OK=12 WARN=0 FAIL=0
```

Проверка init/service/cron layer:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-init-post-check
```

Ожидаемый финал:

```text
Direct-init post-check summary: OK=8 WARN=0 FAIL=0
```

## 6. Обновление

Для direct-mode установки:

```sh
xray-go update go --dry-run
xray-go update go
```

`xray-go update go --dry-run` должен показать direct full plan и завершиться без изменений.

`xray-go update go` должен определить `INSTALL_MODE=direct` в manifest и выполнить direct full apply.

После обновления:

```sh
xray-go version
xray-go manifest
xray-go recover status
xray-go doctor --support
vless-go-doctor
```

## 7. Recovery и watchdog

Статус recovery:

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

Проверить watchdog init:

```sh
/opt/etc/init.d/S26vless-go-watchdog status
```

Аккуратный restart watchdog daemon:

```sh
/opt/etc/init.d/S26vless-go-watchdog restart
xray-go recover status
```

Подробности по recovery/watchdog/health-check: `docs/recovery.md`.

## 8. SOCKS health-check

Без SOCKS auth:

```sh
curl -k --socks5-hostname 192.168.1.1:10808 https://www.gstatic.com/generate_204 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}\n'
```

С SOCKS auth:

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

## 9. Safe uninstall preview

Посмотреть, что относится к direct-install слою:

```sh
xray-go uninstall --dry-run
```

Dry-run ничего не удаляет. Он только показывает:

```text
- direct code files;
- watchdog init hook;
- recovery cron marker;
- direct manifest/plans;
- staging directory;
- preserve-by-default user/runtime data.
```

Guarded apply scaffold через installer существует только как safety-boundary проверка и сейчас не удаляет файлы:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-uninstall-experimental --yes
```

Ожидаемый финал:

```text
No changes made in this build. Real removal is intentionally disabled.
```

## 10. Troubleshooting

Если direct helper не обновился из-за cache:

```sh
curl -fsSL -H 'Cache-Control: no-cache' https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh | sh -s -- --direct-full-dry-run
```

Если нужно проверить direct state без изменений:

```sh
xray-go update go --dry-run
xray-go uninstall --dry-run
```

Если doctor показывает SOCKS auth error, проверить вручную:

```sh
. /opt/etc/xray/vless-go-socks-auth.conf
curl -fsS --socks5-hostname 127.0.0.1:10808 --proxy-user "$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS" http://cp.cloudflare.com/generate_204 -o /dev/null && echo OK
```

## 11. Related docs

- `docs/modes.md`
- `docs/direct-install.md`
- `docs/direct-update.md`
- `docs/direct-uninstall.md`
- `docs/direct-uninstall-validation.md`
- `docs/recovery.md`
- `docs/opkg-feed-v1.md`
- `docs/legacy.md`
