# Optional VLESS Go Web UI

`vless-go-web` is an optional web interface for the Full Go/Entware edition.

It is not installed or started by default. Install it only when you want a browser UI on top of the existing Full Go commands.

## Install

On fresh Full Go installs, the helper is included as:

```sh
vless-go-web-install
```

For existing installs, install directly from GitHub raw:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/vless-go-web-install.sh | sh
```

## Start/stop

```sh
/opt/etc/init.d/S27vless-go-web start
/opt/etc/init.d/S27vless-go-web stop
/opt/etc/init.d/S27vless-go-web restart
/opt/etc/init.d/S27vless-go-web status
```

## Default listen address

By default the service listens only on localhost:

```text
127.0.0.1:18088
```

Use an SSH tunnel from your computer:

```sh
ssh -L 18088:127.0.0.1:18088 root@192.168.1.1
```

Then open:

```text
http://127.0.0.1:18088/
```

## LAN access

To expose the UI on the LAN, edit:

```sh
vi /opt/etc/xray/vless-go-web.conf
```

Set:

```text
LISTEN="0.0.0.0:18088"
```

Then restart:

```sh
/opt/etc/init.d/S27vless-go-web restart
```

Only expose this on a trusted LAN. Do not expose it to the internet.

## Token

A form token is generated during installation and stored at:

```text
/opt/etc/xray/vless-go-web.token
```

The token is used internally by the UI forms to protect POST actions.

## Current UI controls

The web UI exposes these Full Go operations:

```text
Status and diagnostics:
  - status
  - watchdog status
  - doctor

Profile switching:
  - switch to primary
  - switch to backup

Profile management:
  - set primary or backup VLESS/subscription URL
  - set primary and backup selectors

Automation:
  - update active config
  - run auto-update now
  - enable/disable backup -> primary recovery

Maintenance:
  - restart Xray
  - restart watchdog
  - show switch history
  - cleanup dry-run
  - Xray-core update with backup
```

Source URLs are accepted by form but are not rendered back into the page.

The UI uses the existing command-line helpers under `/opt/bin` and does not replace them.

## Release assets

The `Publish Go experimental release` workflow publishes these optional web UI binaries:

```text
vless-go-web-linux-arm64
vless-go-web-linux-arm64.sha256
vless-go-web-linux-mipsle
vless-go-web-linux-mipsle.sha256
```

The installer automatically selects the correct asset from the `latest` release based on Entware architecture.
