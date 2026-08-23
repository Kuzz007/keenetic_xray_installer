# Mixed VLESS and AmneziaWG failover

Phase 4A introduces typed `primary` and `backup` profiles while preserving the
existing VLESS state files and the experimental `single` AWG profile. It is a
manual Dev-validation milestone, not the final automatic failover release.

## Supported in phase 4A

- either slot can be typed as VLESS or AWG;
- an AWG guest link is imported directly into an inactive named slot without
  putting the link in process arguments;
- `xray-go switch primary|backup` and `vless-go-failover switch
  primary|backup` select the adapter from the stored slot type;
- VLESS to AWG, AWG to VLESS and AWG to AWG switches use the existing Xray
  rollback configuration as a transaction bridge;
- a failed target activation leaves the active-slot file unchanged and, when
  the previous slot was AWG, attempts to reactivate that previous AWG profile;
- status reports `(VLESS)` or `(AWG)` without printing a source, endpoint or
  key.

The old `/opt/etc/xray/vless-go.primary` and `vless-go.backup` files remain
valid. If no type file exists, a configured legacy source is inferred as
VLESS, so installing the bundle does not rewrite existing router state.

## Deliberate phase 4A limits

- watchdog and hourly recovery do not automatically select an AWG target yet;
- the agent continues to block slot-changing commands while AWG owns Xray;
- bot import, typed status buttons and automatic AWG health failover belong to
  phases 4B and 5;
- an AWG profile can be replaced only while its slot is inactive.

These limits prevent existing VLESS recovery loops from activating AWG before
the unified supervisor and bot understand typed health state.

## Dev-router validation

Start with a healthy VLESS slot. Import the self-hosted guest link into the
inactive slot; the value is read from stdin and is never passed in argv:

```sh
/opt/bin/vless-go-failover set-awg backup --input -
```

Paste one `vpn://` line, press Enter and then `Ctrl-D`. Import does not change
the active connection. Confirm the typed status:

```sh
/opt/bin/xray-go status
/opt/bin/keenetic-awg-slot status --slot backup
```

Switch manually and verify the stable SOCKS endpoint:

```sh
/opt/bin/xray-go switch backup
/opt/bin/keenetic-awg-slot status --slot backup
/opt/bin/awg show awgx0
curl --socks5-hostname 127.0.0.1:10808 -fsS --max-time 20 \
  -o /dev/null https://www.gstatic.com/generate_204 && echo AWG_SOCKS_OK
```

Return to VLESS through the same typed selector:

```sh
/opt/bin/xray-go switch primary
/opt/bin/xray-go status
curl --socks5-hostname 127.0.0.1:10808 -fsS --max-time 20 \
  -o /dev/null https://www.gstatic.com/generate_204 && echo VLESS_SOCKS_OK
```

Do not paste the guest link, private configuration, `awg show` keys or endpoint
into an issue or bot message. Routine validation should report only slot type,
phase, handshake age and pass/fail results.
