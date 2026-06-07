# Direct safety check

`xray-go safety-check` — read-only проверка safety/rollback границ direct-install слоя.

Цель: подтвердить, что failure scenarios в staging не меняют рабочие direct-install файлы и что установленный binary совпадает с manifest sha256.

## Запуск через `xray-go`

После обновления wrapper:

```sh
xray-go update go
xray-go safety-check
```

`xray-go safety-check` refresh'ит helper `/opt/bin/xray-go-safety-check` из `scripts/xray-go-safety-check.sh` и запускает его.

## Запуск без установки

Standalone fallback:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-safety-check.sh | sh
```

## Что проверяется

Проверка делает snapshot ключевых рабочих файлов:

```text
/opt/bin/xray-failover-go
/opt/bin/xray-go
/opt/bin/vless-go-*
/opt/bin/failover-go
/opt/bin/xray-go-manifest
/opt/bin/xray-go-direct-full
/opt/bin/xray-go-direct-uninstall
/opt/libexec/vless-go-lock.sh
/opt/etc/init.d/S26vless-go-watchdog
/opt/etc/xray/xray-go.manifest
/opt/etc/xray/xray-go.direct-install.plan
/opt/etc/xray/xray-go.direct-init.plan
```

Затем выполняет изолированные failure simulations только в `/tmp`:

- bad download должен завершиться ошибкой до изменения рабочих файлов;
- broken shell helper должен быть отклонён через `sh -n`;
- failed install simulation не должен менять уже существующий target content;
- после simulations повторный snapshot должен совпадать с исходным.

## Что не делает

`xray-go-safety-check` не должен:

- запускать real update;
- скачивать Go resolver release asset;
- устанавливать helper scripts;
- менять manifest;
- менять cron;
- рестартовать Xray/watchdog;
- редактировать VLESS sources/configs.

## Ожидаемый здоровый результат

```text
== Result ==
OK=... WARN=0 FAIL=0
```

Допустимы warning-и только для дополнительных файлов, которые отсутствуют на неполной установке. На подтверждённой direct full установке ожидается `FAIL=0`.

## Router validation

Standalone helper подтверждён на Keenetic `aarch64-3.10_kn` после direct full/update/Xray-core validation:

```text
[OK] manifest present: /opt/etc/xray/xray-go.manifest
[OK] manifest install mode: direct
[OK] manifest binary executable: /opt/bin/xray-failover-go
[OK] manifest binary sha256 matches current binary
[OK] direct-install plan present: /opt/etc/xray/xray-go.direct-install.plan
[OK] direct-init plan present: /opt/etc/xray/xray-go.direct-init.plan
[OK] helper index present: /opt/tmp/xray-go-direct-install/xray-go.helpers.index
[OK] direct full update supports binary reuse fallback
[OK] isolated bad download failed before touching working files
[OK] isolated broken shell helper rejected by sh -n
[OK] isolated failed install leaves previous target content unchanged
[OK] working direct-install files unchanged after failure simulations
OK=12 WARN=0 FAIL=0
```

## Связанные проверки

```sh
xray-go update go --dry-run
xray-go update go
xray-go summary
xray-go privacy-check
xray-go uninstall --dry-run
```
