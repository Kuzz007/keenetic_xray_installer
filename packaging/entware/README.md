# Entware package feed

This repository can build a first-party Entware feed for the experimental `failover-go` package.

## Build locally

```sh
chmod +x scripts/build-entware-feed.sh
scripts/build-entware-feed.sh
```

Output:

```text
dist/entware-feed/failover-go_<version>_<arch>.ipk
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
echo 'src/gz failover-go http://127.0.0.1:8080' >> /opt/etc/opkg/customfeeds.conf
opkg update
opkg install failover-go
```

## Release feed layout

A release/feed should expose these files from one HTTP directory:

```text
Packages
Packages.gz
failover-go_<version>_<arch>.ipk
failover-go_<version>_<arch>.ipk.sha256
```

Then users can add:

```sh
echo 'src/gz failover-go <feed-url>' >> /opt/etc/opkg/customfeeds.conf
opkg update
opkg install failover-go
```

## Notes

- Keenetic Entware `.ipk` packages are gzip tar archives, not Debian `ar` archives.
- Top-level package layout follows official Entware packages:
  - `./debian-binary`
  - `./data.tar.gz`
  - `./control.tar.gz`
- The `failover-go` package `postinst` downloads `/opt/bin/xray-failover-go` from the existing GitHub Release asset.
