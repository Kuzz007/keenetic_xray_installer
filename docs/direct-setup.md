# Direct setup planner

`direct setup planner` — первый безопасный шаг к future direct first-run setup.

Он только анализирует текущее состояние и печатает план. Он не создаёт и не меняет runtime-файлы.

## Команда

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-setup-plan
```

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

`--direct-setup-plan` is read-only.

It does not:

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

## Next step

After router validation, the next step can be a guarded scaffold:

```text
install.sh --direct-setup --yes
```

The scaffold should initially only require confirmation and print the same plan without changing files. Real setup apply should be a later step.
