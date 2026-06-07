# Direct uninstall dry-run validation

Validated on Keenetic/Entware `aarch64-3.10_kn` after direct full apply and direct-aware `xray-go update go`.

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

This closes the read-only uninstall planner milestone. Any future apply mode must stay separate from dry-run and require an explicit confirmation flag.
