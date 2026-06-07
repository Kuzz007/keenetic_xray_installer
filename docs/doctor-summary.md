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

Helper не печатает:

```text
raw vless:// links
subscription URLs
tokens
passwords
private keys
```

SOCKS auth учитывается через:

```text
/opt/etc/xray/vless-go-socks-auth.conf
```

Credentials используются только для health-check и не выводятся в stdout.

## Проверка без установки

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

## Связь с полным doctor

Полный doctor остаётся основной глубокой диагностикой:

```sh
vless-go-doctor
xray-go doctor --support
```

Summary helper полезен как быстрый pre-check перед полным выводом.

Будущий шаг: встроить этот summary в начало `vless-go-doctor` / `xray-go doctor --support`, если формат подтвердится на роутере.
