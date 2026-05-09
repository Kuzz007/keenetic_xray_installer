# Experimental opkg feed

This is an experimental packaging path for the Go-based Keenetic Xray installer helpers.

## Target UX

After the feed is published:

```sh
mkdir -p /opt/etc/opkg
echo "src/gz keenetic-xray-go-experimental https://kuzz007.github.io/keenetic_xray_installer/opkg/all" > /opt/etc/opkg/keenetic-xray-go-experimental.conf
opkg update
opkg install keenetic-xray-go-experimental
xray-go-install
```

For later updates:

```sh
opkg update
opkg upgrade keenetic-xray-go-experimental
xray-go-repo-update
```

`xray-go-repo-update` reuses saved sources by default and does not ask for VLESS/subscription input again.

To force interactive re-entry:

```sh
xray-go-repo-update --interactive
```

## Feed setup helper

```sh
curl -fsSL https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_go_opkg_feed_setup.sh | sh
opkg install keenetic-xray-go-experimental
xray-go-install
```

## Build feed locally

```sh
chmod +x scripts/build-opkg-feed.sh
sh scripts/build-opkg-feed.sh
```

Output:

```text
dist/opkg/all/keenetic-xray-go-experimental_0.1.0_all.ipk
dist/opkg/all/Packages
dist/opkg/all/Packages.gz
```

Publish `dist/opkg` to GitHub Pages under `/opkg` so the feed URL becomes:

```text
https://kuzz007.github.io/keenetic_xray_installer/opkg/all
```

## Notes

The package is architecture-independent because it currently installs shell wrappers only. The actual Go helper binary is still downloaded from GitHub Releases by `xray_vless_failover_go.sh`.
