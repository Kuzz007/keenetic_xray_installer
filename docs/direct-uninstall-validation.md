# Direct uninstall validation

Validated on Keenetic/Entware `aarch64-3.10_kn` after direct full apply and direct-aware `xray-go update go`.

## Dry-run planner

Command:

```sh
xray-go uninstall --dry-run
```

Confirmed behavior:

```text
Manifest is detected as direct.
Current Go resolver sha256 matches manifest sha256.
The planner lists direct code files.
The planner lists service and cron hooks by marker.
The planner lists direct metadata and staging paths.
The planner lists user/runtime data that should be preserved by default.
The planner finishes with "No changes made".
```

User/runtime data preservation confirmed in the plan:

```text
watchdog config
VLESS source pointers and selectors
active Xray config
SOCKS auth config
switch/watchdog/recovery logs
```

This closes the read-only uninstall planner milestone.

## Guarded apply scaffold

Command:

```sh
curl -fsSL -H 'Cache-Control: no-cache' \
  https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/install.sh \
  | sh -s -- --direct-uninstall-experimental --yes
```

Confirmed behavior:

```text
Mode is apply.
Manifest is detected as direct.
Current Go resolver sha256 matches manifest sha256.
The same uninstall plan is printed.
The same preserve-list is printed.
The command requires explicit confirmation via --yes.
The command finishes with "No changes made in this build".
Real removal is intentionally disabled in this scaffold build.
```

Safety boundary confirmed:

```text
dry-run remains the default
user/runtime data would be preserved
no files were deleted
cron was not edited
services were not stopped
VLESS sources were not modified
```

This closes the guarded apply scaffold milestone. A future real apply mode must remain separate from dry-run, require explicit confirmation, preserve user/runtime data by default, and should be validated on a disposable test system before any production use.
