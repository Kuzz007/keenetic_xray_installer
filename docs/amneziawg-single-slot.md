# Single self-hosted AmneziaWG slot

This stage adds one isolated AWG slot for live-router validation. It is not yet
part of the primary/backup selector and the bot cannot manage it yet. The
current VLESS slot remains the rollback target.

## Installed components

Both FULL and MINIMAL `.run` bundles contain the same AWG capability:

- `keenetic-awg-slot`, the profile and lifecycle manager;
- pinned `amneziawg-go` and the static `awg` configurator;
- upstream licenses, exact GPL source archive and runtime provenance;
- `S23keenetic-awg-recover`, which restores the saved VLESS config before Xray
  starts if the router rebooted while the experimental AWG slot was active.

The runtime is started on demand. Import and status do not start it. Activation
still requires at least 24576 kB `MemAvailable` by default; the isolated router
probe measured approximately 22 MB while AWG was running, so a true 40 MB
physical-RAM router remains outside the proven target set.

## Safety model

- Only self-hosted AWG guest `vpn://` links are accepted. Premium/API,
  full-access and non-AWG links fail closed.
- Import reads the link from stdin or a file. It is never accepted as a command
  line argument, which keeps it out of `ps` and normal shell history.
- The validated native profile is atomically stored as
  `/opt/etc/xray/awg/single.conf` with mode `0600` in a mode `0700` directory.
- Unknown native keys and all `PostUp`/`PreDown`-style hooks are rejected.
- The current Xray config is saved before activation. Any runtime, interface,
  Xray validation, handshake or SOCKS failure restores that config and stops
  AWG.
- Xray keeps its existing SOCKS inbound, including optional authentication.
  Only its outbound changes to `freedom` with `sockopt.interface=awgx0` and a
  dedicated routing mark/table.
- The manager refuses to reuse an existing interface, UAPI socket, rule
  priority or routing table.
- A runtime-state ownership marker blocks the bundled VLESS update, failover,
  watchdog, hourly recovery and Minimal daemon paths from overwriting Xray
  while AWG is active. Previously running failover daemons are also stopped
  and restored transactionally.
- The Go agent keeps status, diagnostics and agent update available, but
  rejects bot commands that mutate Xray or switch VLESS while AWG owns it.
- Routine status and errors never print the native config, private key,
  preshared key or full `vpn://` value.

## Dev-router validation

Install the matching FULL or MINIMAL bundle from the `dev` release first. The
single-slot manager does not change the active VPN during installation.

Create a private temporary input without placing the link in the command:

```sh
umask 077
cat > /opt/tmp/awg-guest.vpn
```

Paste one self-hosted AWG guest `vpn://` line, press Enter, then `Ctrl-D`.
Import it and remove the temporary input:

```sh
/opt/bin/keenetic-awg-slot import --input /opt/tmp/awg-guest.vpn
rm -f /opt/tmp/awg-guest.vpn
/opt/bin/keenetic-awg-slot status
```

Import only stages the profile. Activation is the explicit live change:

```sh
/opt/bin/keenetic-awg-slot activate
/opt/bin/keenetic-awg-slot status
```

`activate` resolves the AWG peer before changing Xray, starts `awgx0`, applies
the tunnel addresses, configures a private marked route table, validates the
new Xray config, restarts Xray and requires both a recent AWG handshake and a
successful HTTP check through the existing SOCKS endpoint. The existing VLESS
watchdog/failover daemons are paused while AWG owns Xray.

At this stage a router reboot intentionally returns to the stored VLESS
configuration. Persistent AWG boot activation is deferred until mixed failover
understands typed profiles and can monitor it safely.

Return to the previous VLESS config:

```sh
/opt/bin/keenetic-awg-slot deactivate
```

If a previous command or router interruption left recovery state, use:

```sh
/opt/bin/keenetic-awg-slot recover
```

Only after the slot is inactive can the stored profile be removed:

```sh
/opt/bin/keenetic-awg-slot delete
```

Do not use the existing `vless-go-failover switch` or bot slot buttons while
AWG is active in this validation stage. Typed primary/backup integration is
the next delivery stage.
