# Entware package feed

This repository can build and publish first-party Entware feeds for the experimental `failover-go` package.

## Supported architectures

The bootstrap installer detects Entware architecture with `opkg print-architecture` and selects the matching GitHub Release feed.

| Entware architecture | Latest feed release tag | Versioned feed release tag | Go resolver asset |
| --- | --- | --- | --- |
| `aarch64-3.10` | `latest` | `0.1.3-go-experimental` | `xray-failover-go-linux-arm64` |
| `mipsel-3.4` / `mipsel-3.4_kn` | `latest-mipsel-3.4` | `0.1.3-go-experimental-mipsel-3.4` | `xray-failover-go-linux-mipsle` |
| `mipselsf-k3.4` / `mipselsf-k3.4_kn` | `latest-mipselsf-k3.4` | `0.1.3-go-experimental-mipselsf-k3.4` | `xray-failover-go-linux-mipsle` |

Architecture-specific feed tags are used because each GitHub Release feed root contains one `Packages` and `Packages.gz` pair.

The default install channel is `latest`. Set `BASE_REPO_TAG=0.1.3-go-experimental` or `REPO_TAG=<tag>` to pin a versioned feed.

## One-line install from GitHub Release feed

Recommended Keenetic/Entware install flow:

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/install-entware-feed.sh | sh
```

The bootstrap installer does the same steps manually recommended by projects such as `nfqws2-keenetic`:

```sh
opkg update
opkg install ca-certificates wget-ssl
opkg remove wget-nossl 2>/dev/null || true
mkdir -p /opt/etc/opkg
# The exact release URL is selected automatically from opkg print-architecture.
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/<selected-release-tag>' > /opt/etc/opkg/failover-go.conf
opkg update
opkg install failover-go
```

Then run initial setup:

```sh
xray_vless_failover_go.sh
failover-go
vless-go-doctor
```

## Build locally

```sh
chmod +x scripts/build-entware-feed.sh
scripts/build-entware-feed.sh
```

Build for a specific architecture:

```sh
PKG_ARCH=mipsel-3.4 scripts/build-entware-feed.sh
```

Output:

```text
dist/entware-feed/failover-go_<version>_<arch>.ipk
dist/entware-feed/failover-go_<version>_<arch>.ipk.sha256
dist/entware-feed/Packages
dist/entware-feed/Packages.gz
```

## Install from a local feed directory on router

For local testing on Keenetic/Entware:

```sh
cd /opt/tmp/keenetic_xray_installer/dist/entware-feed
python3 -m http.server 8080
```

Then in another shell on the same router or from a reachable HTTP host:

```sh
opkg update
opkg install ca-certificates wget-ssl
opkg remove wget-nossl 2>/dev/null || true
mkdir -p /opt/etc/opkg
echo 'src/gz failover-go http://127.0.0.1:8080' > /opt/etc/opkg/failover-go.conf
opkg update
opkg install failover-go
```

## Publish latest release assets

First publish the architecture-independent Go resolver assets:

```text
Actions -> Publish Go experimental release -> Run workflow

tag: latest
```

This uploads:

```text
xray-failover-go-linux-arm64
xray-failover-go-linux-arm64.sha256
xray-failover-go-linux-mipsle
xray-failover-go-linux-mipsle.sha256
```

Then publish architecture-specific Entware feeds:

```text
Actions -> Release Entware Feed -> Run workflow

tag: latest
version: 0.1.3-go-experimental
arch: aarch64-3.10
```

```text
Actions -> Release Entware Feed -> Run workflow

tag: latest-mipsel-3.4
version: 0.1.3-go-experimental
arch: mipsel-3.4
```

Optional, if needed for a separate mipselsf feed tag:

```text
Actions -> Release Entware Feed -> Run workflow

tag: latest-mipselsf-k3.4
version: 0.1.3-go-experimental
arch: mipselsf-k3.4
```

## Publish versioned release feed assets

The same workflow can publish pinned version tags.

For `aarch64-3.10`:

```text
tag: 0.1.3-go-experimental
version: 0.1.3-go-experimental
arch: aarch64-3.10
```

For `mipsel-3.4`:

```text
tag: 0.1.3-go-experimental-mipsel-3.4
version: 0.1.3-go-experimental
arch: mipsel-3.4
```

For `mipselsf-k3.4`:

```text
tag: 0.1.3-go-experimental-mipselsf-k3.4
version: 0.1.3-go-experimental
arch: mipselsf-k3.4
```

The `Release Entware Feed` workflow publishes these assets to the selected GitHub Release:

```text
Packages
Packages.gz
failover-go_<version>_<arch>.ipk
failover-go_<version>_<arch>.ipk.sha256
entware-feed_<version>_<arch>.tar.gz
entware-feed_<version>_<arch>.tar.gz.sha256
```

## Install from GitHub Release feed manually

For latest `aarch64-3.10`:

```sh
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/latest' > /opt/etc/opkg/failover-go.conf
```

For latest `mipsel-3.4`:

```sh
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/latest-mipsel-3.4' > /opt/etc/opkg/failover-go.conf
```

For pinned `mipsel-3.4`:

```sh
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/0.1.3-go-experimental-mipsel-3.4' > /opt/etc/opkg/failover-go.conf
```

Then run:

```sh
opkg update
opkg install failover-go
xray_vless_failover_go.sh
failover-go
vless-go-doctor
```

## Troubleshooting

If `opkg update` fails with:

```text
wget: not an http or ftp url: https://...
```

then HTTPS-capable wget is not active. Run:

```sh
opkg install --force-reinstall wget-ssl ca-certificates
opkg remove wget-nossl 2>/dev/null || true
```

Then retry:

```sh
opkg update
```

## Notes

- Keenetic Entware `.ipk` packages are gzip tar archives, not Debian `ar` archives.
- Top-level package layout follows official Entware packages:
  - `./debian-binary`
  - `./data.tar.gz`
  - `./control.tar.gz`
- The `failover-go` package `postinst` downloads `/opt/bin/xray-failover-go` from the existing GitHub Release asset.
- The tested Keenetic path for custom feeds is `/opt/etc/opkg/<name>.conf`.
