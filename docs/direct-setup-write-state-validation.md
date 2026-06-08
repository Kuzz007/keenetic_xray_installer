# Direct setup write-state validation

This document records router validation for direct setup phase-1 `--write-state` guardrails.

## Scope

`--write-state` is the first real apply phase for future fresh installs.

It may write only source/state/selector files after guard checks:

```text
/opt/etc/xray/vless-go.primary
/opt/etc/xray/vless-go.backup
/opt/etc/xray/vless-go.active
/opt/etc/xray/vless-go.primary.selector
/opt/etc/xray/vless-go.backup.selector
/opt/etc/xray/vless-go.source
```

It must not change:

```text
/opt/etc/xray/config.json
/opt/etc/xray/vless-go-socks-auth.conf
Proxy0
cron
init.d
Xray service
watchdog service
```

On an already configured router, `--write-state` must refuse to avoid accidental overwrite.

## Router validation: guarded refusal on configured router

Validated on Keenetic / Entware `aarch64-3.10_kn` with an existing configured direct Full Go runtime.

Command used pinned commit `8e97ebce1c61e01647e73e0b61e5fa7a4c2a44f1`:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/8e97ebce1c61e01647e73e0b61e5fa7a4c2a44f1/scripts/xray-go-direct-setup.sh \
  | sh -s -- --apply --yes --write-state \
      --primary-source 'https://example.invalid/primary-sub' \
      --backup-source 'https://example.invalid/backup-sub' \
      --active primary \
      --primary-selector index:1 \
      --backup-selector index:1 \
      --socks-auth keep

echo "RC=$?"
```

Result:

```text
Version: 0.1.5-direct-setup-write-state
Phase-1 state write requested. Only source/state/selector files may be changed.
Config, Proxy0, cron, init, Xray and watchdog services are not changed.

== Setup input validation ==
[OK] primary source input valid (subscription URL); size=35 bytes
[OK] backup source input valid (subscription URL); size=34 bytes
[OK] active input valid: primary
[OK] primary selector input valid: index:1
[OK] backup selector input valid: index:1
[OK] SOCKS auth policy input valid: keep
State write requested. Inputs are validated before any file write.

== Write-state guard ==
[FAIL] write-state refused: existing state/source/selector files are present; no changes made
This protects configured routers from accidental overwrite. Fresh installs should have no existing state files.
write-state skipped because guard checks failed.

== Write-state phase 1 ==
No changes made. Write-state phase was not authorized by guard checks.

== Result ==
OK=33 WARN=0 FAIL=1
Direct setup write-state phase refused. No changes made.
RC=1
```

## Validation conclusion

The refusal is expected and correct for an already configured router.

Confirmed:

```text
existing state/source/selector files are protected
raw setup input values are not printed
no phase-1 state files were written
config.json was not changed
SOCKS auth config was not changed
Proxy0 was not changed
cron/init/services were not touched
Xray/watchdog were not restarted
```

Next step: validate the successful write path only in an isolated fresh-state sandbox or on a clean test router.
