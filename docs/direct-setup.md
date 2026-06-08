# Direct setup planner

`direct setup planner` — первый безопасный шаг к future direct first-run setup.

Он анализирует текущее состояние и печатает план. В текущей реализации есть два режима:

```text
plan   — read-only анализ;
apply  — guarded scaffold, требует --yes, но всё ещё ничего не меняет.
```

## Команды

Read-only setup plan:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan
```

Guarded setup scaffold:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan --apply --yes
```

Validation-only setup inputs:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan --apply --yes \
      --primary-source 'https://example.invalid/primary-sub' \
      --backup-source 'https://example.invalid/backup-sub' \
      --active primary \
      --primary-selector index:1 \
      --backup-selector index:1 \
      --socks-auth auto
```

`--direct-setup-plan --apply --yes` is a temporary public route through the existing setup planner alias. A shorter `--direct-setup --yes` alias can be added later.

## Validation-only setup inputs

Supported input flags:

```text
--primary-source SRC
--backup-source SRC
--active primary|backup
--primary-selector first|index:N
--backup-selector first|index:N
--socks-auth auto|keep|disable
```

In this build these inputs are validated only. They are not written to `/opt/etc/xray`, and they are not used to restart services.

Validation rules:

```text
source: one line, starts with vless://, http:// or https://
active: primary or backup
selector: first or index:N, where N >= 1
SOCKS auth policy: auto, keep or disable
```

The planner prints only safe metadata for input sources:

```text
primary source input valid (subscription URL); size=N bytes
backup source input valid (direct vless link); size=N bytes
```

It must not print the full source value.

## Что проверяется

Direct layer:

```text
/opt/etc/xray/xray-go.manifest
/opt/bin/xray-failover-go
/opt/etc/xray/xray-go.direct-install.plan
/opt/etc/xray/xray-go.direct-init.plan
/opt/bin/vless-go-*
/opt/bin/xray-go
```

Runtime state:

```text
/opt/etc/xray/config.json
/opt/sbin/xray
/opt/etc/init.d/*xray*
/opt/etc/init.d/S26vless-go-watchdog
Proxy0
```

Source/config inputs:

```text
/opt/etc/xray/vless-go.source
/opt/etc/xray/vless-go.primary
/opt/etc/xray/vless-go.backup
/opt/etc/xray/vless-go.active
/opt/etc/xray/vless-go.primary.selector
/opt/etc/xray/vless-go.backup.selector
/opt/etc/xray/vless-go-socks-auth.conf
/opt/etc/xray/vless-go-watchdog.conf
```

## Privacy boundary

Raw VLESS links and subscription values are not printed.

The planner may print only safe metadata:

```text
configured / missing
source type: subscription URL or direct vless link
line count
file size
selector value
active slot
```

It must not print the full source value.

## Classification

For an already configured direct Full Go runtime, the expected classification is:

```text
existing configured Full Go/direct runtime detected
Plan: direct first-run setup would be a no-op unless a future --force/repair mode is requested.
```

For a fresh or incomplete installation, it prints future requirements:

```text
install direct code layer first
require primary source input
require backup source input or explicit single-source mode
select active slot
create and validate config.json
configure SOCKS auth policy
ensure Proxy0
start/restart Xray and watchdog only after config validation
run summary, doctor, privacy-check and safety-check
```

## Safety boundary

Plan and guarded scaffold are read-only in this build.

They do not:

```text
write VLESS sources
write selectors
write config.json
write SOCKS auth config
change Proxy0
change cron
change init.d
start or stop services
restart Xray
restart watchdog
```

## Router validation: plan

Validated on Keenetic / Entware `aarch64-3.10_kn` with an existing configured direct Full Go runtime.

Command:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan
```

Result:

```text
Version: 0.1.1-direct-setup-plan
[OK] manifest install mode: direct
[OK] manifest edition: full
[OK] Go resolver sha256 matches manifest
[OK] Xray config validates
[OK] Xray init found
[OK] watchdog init found
[OK] Proxy0 interface exists
[OK] current source configured (subscription URL)
[OK] primary source configured (subscription URL)
[OK] backup source configured (subscription URL)
[OK] active slot valid: backup
[OK] primary selector valid: index:1
[OK] backup selector valid: index:1
[OK] existing configured Full Go/direct runtime detected
OK=27 WARN=0 FAIL=0
Direct setup plan complete. No changes made.
```

Notes:

- manifest values are normalized before comparison, including quoted values;
- `install.sh --direct-setup-plan` downloads the setup planner with cache-bust query to avoid stale raw GitHub content;
- raw VLESS/subscription values were not printed.

## Router validation: guarded scaffold

Validated on Keenetic / Entware `aarch64-3.10_kn` with an existing configured direct Full Go runtime.

Command:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan --apply --yes
```

Result:

```text
Mode: apply
Version: 0.1.2-direct-setup-guarded
Guarded setup apply scaffold. Confirmation accepted: --apply --yes
[OK] manifest install mode: direct
[OK] manifest edition: full
[OK] Go resolver sha256 matches manifest
[OK] Xray config validates
[OK] Xray init found
[OK] watchdog init found
[OK] Proxy0 interface exists
[OK] current source configured (subscription URL)
[OK] primary source configured (subscription URL)
[OK] backup source configured (subscription URL)
[OK] active slot valid
[OK] primary selector valid: index:1
[OK] backup selector valid: index:1
[OK] existing configured Full Go/direct runtime detected
Confirmation accepted: --apply --yes
No changes made in this build. Real setup apply is intentionally disabled.
Validated safety boundary: sources/config/Proxy0/cron/init/services were not changed.
OK=27 WARN=0 FAIL=0
Direct setup guarded scaffold complete. No changes made.
```

## Router validation: validation-only inputs

Validated on Keenetic / Entware `aarch64-3.10_kn` with non-secret test input URLs.

Command:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan --apply --yes \
      --primary-source 'https://example.invalid/primary-sub' \
      --backup-source 'https://example.invalid/backup-sub' \
      --active primary \
      --primary-selector index:1 \
      --backup-selector index:1 \
      --socks-auth auto
```

Result:

```text
Mode: apply
Version: 0.1.3-direct-setup-inputs
== Setup input validation ==
Raw setup input values are not printed.
[OK] primary source input valid (subscription URL); size=35 bytes
[OK] backup source input valid (subscription URL); size=34 bytes
[OK] active input valid: primary
[OK] primary selector input valid: index:1
[OK] backup selector input valid: index:1
[OK] SOCKS auth policy input valid: auto
Input validation only. No files are written in this build.
No changes made in this build. Real setup apply is intentionally disabled.
Validated safety boundary: sources/config/Proxy0/cron/init/services were not changed.
OK=33 WARN=0 FAIL=0
Direct setup guarded scaffold complete. No changes made.
```

Real setup apply should be a later step.
