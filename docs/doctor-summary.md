# Doctor summary

`vless-go-doctor-summary.sh` — компактный read-only summary helper для быстрой диагностики direct-mode установки.

Он не заменяет полный `vless-go-doctor`, а даёт короткий верхнеуровневый снимок состояния.

## Что показывает

```text
Install mode
Edition
Version
Architecture
Modules
Active slot
Xray init
Xray config
Proxy0
SOCKS listener
SOCKS health
Watchdog init
Recovery cron
Auto-update cron
Manifest sha256
OK/WARN/FAIL
```

## Безопасность

Helper не выводит raw VLESS/subscription values и использует SOCKS auth config только для health-check.

SOCKS auth config:

```text
/opt/etc/xray/vless-go-socks-auth.conf
```

## Команды

После обновления direct-mode установки helper доступен через `xray-go`:

```sh
xray-go summary
xray-go doctor --summary
```

Эти команды refresh'ят `/opt/bin/vless-go-doctor-summary` из репозитория перед запуском, если доступен `curl`.

Проверка без установки wrapper'а:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/vless-go-doctor-summary.sh | sh
```

## Ожидаемый здоровый direct-mode итог

```text
Install mode: direct
Edition: full
Active slot: primary|backup
Xray init: alive
Xray config: valid
Proxy0: exists
SOCKS listener: 127.0.0.1:10808 listening
SOCKS health: OK
Watchdog init: alive
Recovery cron: enabled
Manifest sha256: match
OK=... WARN=... FAIL=0
```

## Router validation

Подтверждено на Keenetic `aarch64-3.10_kn` через прямой helper:

```text
Install mode: direct
Edition: full
Version: 0.1.0-direct-skeleton
Architecture: aarch64-3.10_kn
Modules: manifest,direct-experimental,binary-present
Active slot: backup
Xray init: alive
Xray config: valid
Proxy0: exists
SOCKS listener: 127.0.0.1:10808 listening
SOCKS health: OK
Watchdog init: alive
Recovery cron: enabled
Auto-update cron: enabled
Manifest sha256: match
OK=12 WARN=0 FAIL=0
```

Подтверждено через CLI path после `xray-go update go`:

```text
xray-go summary              OK=12 WARN=0 FAIL=0
xray-go doctor --summary     OK=12 WARN=0 FAIL=0
xray-go version              helper path OK: /opt/bin/vless-go-doctor-summary
```

Validation notes:

- helper работает без установки через `curl | sh`;
- `xray-go summary` refresh'ит helper перед запуском;
- `xray-go doctor --summary` использует тот же helper;
- `xray-go version` показывает summary helper в списке helper paths;
- SOCKS auth health-check проходит;
- manifest sha256 совпадает с текущим Go resolver binary;
- sensitive connection values не выводятся.

## Связь с полным doctor

Полный doctor остаётся основной глубокой диагностикой:

```sh
vless-go-doctor
xray-go doctor --support
```

Summary helper полезен как быстрый pre-check перед полным выводом.

Текущий CLI path:

```text
xray-go summary
xray-go doctor --summary
```

Будущий шаг: при желании встроить summary прямо в начало полного `vless-go-doctor` / `xray-go doctor --support`, если компактный CLI path стабилен на роутере.
