# Entware package feed

This repository can build and publish a first-party Entware feed for the experimental `failover-go` package.

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
cp /opt/etc/opkg.conf /opt/etc/opkg.conf.bak.$(date +%s)
grep -v 'failover-go' /opt/etc/opkg.conf > /opt/tmp/opkg.conf.new
echo 'src/gz failover-go http://127.0.0.1:8080' >> /opt/tmp/opkg.conf.new
mv /opt/tmp/opkg.conf.new /opt/etc/opkg.conf
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
version: 0.1.2-go-experimental
arch: aarch64-3.10
```

## Install from GitHub Release feed

For release tag `0.1.2-go-experimental`, users can add the feed URL directly:

```sh
cp /opt/etc/opkg.conf /opt/etc/opkg.conf.bak.$(date +%s)
grep -v 'failover-go' /opt/etc/opkg.conf > /opt/tmp/opkg.conf.new
echo 'src/gz failover-go https://github.com/Kuzz007/keenetic_xray_installer/releases/download/0.1.2-go-experimental' >> /opt/tmp/opkg.conf.new
mv /opt/tmp/opkg.conf.new /opt/etc/opkg.conf
opkg update
opkg install failover-go
```

Then run the initial setup:

```sh
xray_vless_failover_go.sh
failover-go
vless-go-doctor
```

## Notes

- Keenetic Entware `.ipk` packages are gzip tar archives, not Debian `ar` archives.
- Top-level package layout follows official Entware packages:
  - `./debian-binary`
  - `./data.tar.gz`
  - `./control.tar.gz`
- The `failover-go` package `postinst` downloads `/opt/bin/xray-failover-go` from the existing GitHub Release asset.
- Some Entware installs do not have `/opt/etc/opkg/customfeeds.conf`; editing `/opt/etc/opkg.conf` is the tested path on Keenetic.
