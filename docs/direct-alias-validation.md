# Public direct aliases validation

Этот документ фиксирует проверку публичных direct-install aliases на реальном Keenetic.

## Проверенная система

```text
Architecture: aarch64-3.10_kn
Install mode: direct
Edition: full
Active slot: backup
Recovery cron marker: vless-go-hourly-recover
```

## Проверенные команды

### `--direct-plan`

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-plan
```

Результат:

```text
Current direct state: OK
Go resolver sha256: OK
Manifest install mode: direct
Manifest binary sha256 matches target
Watchdog init/config: OK
Recovery helper: OK
Recovery cron marker present
Direct full dry-run complete. No changes made.
```

### `--direct-check`

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-check
```

Результат:

```text
Post-check summary: OK=12 WARN=0 FAIL=0
```

Подтверждено:

```text
Go resolver exists/version/sha256 OK
Shell helpers installed
Doctor/recovery helpers are SOCKS-auth aware
Manifest present
Manifest install mode: direct
Manifest binary sha256 matches target
Recovery health: OK
```

### `--direct-init-check`

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-init-check
```

Результат:

```text
Direct-init post-check summary: OK=8 WARN=0 FAIL=0
```

Подтверждено:

```text
watchdog helper executable
watchdog init executable
watchdog config present
recovery helper executable
cron file present
recovery cron entry present
watchdog init status works
recovery health OK
```

## Вывод

Публичные aliases работают и дают тот же результат, что ранее проверенные compatibility/experimental flags:

```text
--direct-plan        OK, no changes made
--direct-check       OK=12 WARN=0 FAIL=0
--direct-init-check  OK=8 WARN=0 FAIL=0
```

Default `install.sh | sh` пока остаётся совместимым Auto Latest path. Direct-install v2 продвинут в публичный интерфейс через aliases, но ещё не сделан default path.
