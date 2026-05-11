# Entware package feed

This repository can build and publish a first-party Entware feed for the experimental `failover-go` package.

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
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/0.1.3-go-experimental' > /opt/etc/opkg/failover-go.conf
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

## Publish release feed assets

The `Release Entware Feed` workflow publishes these assets to a GitHub Release:

```text
Packages
Packages.gz
failover-go_<version>_<arch>.ipk
failover-go_<version>_<arch>.ipk.sha256
entware-feed_<version>_<arch>.tar.gz
entware-feed_<version>_<arch>.tar.gz.sha256
```

The workflow runs automatically when a release is published. It can also be started manually with:

```text
Actions -> Release Entware Feed -> Run workflow
```

Required manual input:

```text
tag: <existing GitHub Release tag>
```

Optional inputs:

```text
version: 0.1.3-go-experimental
arch: aarch64-3.10
```

## Install from GitHub Release feed manually

For release tag `0.1.3-go-experimental`, users can add the feed URL directly:

```sh
opkg update
opkg install ca-certificates wget-ssl
opkg remove wget-nossl 2>/dev/null || true
mkdir -p /opt/etc/opkg
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/0.1.3-go-experimental' > /opt/etc/opkg/failover-go.conf
opkg update
opkg install failover-go
```

Then run the initial setup:

```sh
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
