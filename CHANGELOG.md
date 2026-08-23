# Changelog

## [0.3.0](https://github.com/Kuzz007/keenetic_xray_installer/compare/v0.2.1...v0.3.0) (2026-08-23)


### Features

* add fail-closed AWG live router probe ([#284](https://github.com/Kuzz007/keenetic_xray_installer/issues/284)) ([fcdd639](https://github.com/Kuzz007/keenetic_xray_installer/commit/fcdd639bb663be030865d93d8edfeac750abb4c3))
* add guarded mixed VLESS and AWG slots ([58f7156](https://github.com/Kuzz007/keenetic_xray_installer/commit/58f715680b47673e15d9ec3ffdddae9772fb46b0))
* add guarded mixed VLESS AWG slots ([504e5ab](https://github.com/Kuzz007/keenetic_xray_installer/commit/504e5abbc7913ac2e79fbfea4c07f54e8c269996))
* add isolated AmneziaWG router slot ([#286](https://github.com/Kuzz007/keenetic_xray_installer/issues/286)) ([a012ad8](https://github.com/Kuzz007/keenetic_xray_installer/commit/a012ad86b0f0ca2893174367ac9053627772f50b))
* add safe agent channels and FULL/MINIMAL router bundles ([#279](https://github.com/Kuzz007/keenetic_xray_installer/issues/279)) ([fabc6f2](https://github.com/Kuzz007/keenetic_xray_installer/commit/fabc6f268e120307c6f08d17222e47056a83c139))
* parse self-hosted AmneziaWG vpn links ([9dd32a8](https://github.com/Kuzz007/keenetic_xray_installer/commit/9dd32a8f3ed739d436e41daba654fe9e9b09165c))


### Bug Fixes

* accept native AWG vpn links ([#288](https://github.com/Kuzz007/keenetic_xray_installer/issues/288)) ([689f768](https://github.com/Kuzz007/keenetic_xray_installer/commit/689f768d21881a31a651f9bc82fa05ff6b0833a5))
* make AWG cleanup idempotent ([#291](https://github.com/Kuzz007/keenetic_xray_installer/issues/291)) ([e779b25](https://github.com/Kuzz007/keenetic_xray_installer/commit/e779b2523a49346b52cdc484e09a06e51261443f))
* restore legacy agents and automate channel updates ([#281](https://github.com/Kuzz007/keenetic_xray_installer/issues/281)) ([d92f716](https://github.com/Kuzz007/keenetic_xray_installer/commit/d92f7162de006f8405af5ef9dcea08b987acfe18))
* select BusyBox AWG route tables ([#289](https://github.com/Kuzz007/keenetic_xray_installer/issues/289)) ([ab80d4f](https://github.com/Kuzz007/keenetic_xray_installer/commit/ab80d4fdaad39290a4633974e57d3417f0a6c94a))
* split Keenetic agent install command ([#290](https://github.com/Kuzz007/keenetic_xray_installer/issues/290)) ([c4c78f2](https://github.com/Kuzz007/keenetic_xray_installer/commit/c4c78f29eb8792f1c9101b989a9c070774e97db2))
* stream router bundle installs ([#287](https://github.com/Kuzz007/keenetic_xray_installer/issues/287)) ([15c600a](https://github.com/Kuzz007/keenetic_xray_installer/commit/15c600ae65d0de9a41dc7ced49f916abf2202902))

## [0.2.1](https://github.com/Kuzz007/keenetic_xray_installer/compare/v0.2.0...v0.2.1) (2026-07-28)


### Bug Fixes

* agent/bot reliability + security fixes (shell hardening, state persistence, constant-time auth, backoff, dead-code cleanup) ([#277](https://github.com/Kuzz007/keenetic_xray_installer/issues/277)) ([36f23a0](https://github.com/Kuzz007/keenetic_xray_installer/commit/36f23a0cd119ced16ae4565cfca1a4bd40fb0cdf))

## [0.2.0](https://github.com/Kuzz007/keenetic_xray_installer/compare/keenetic_xray_installer-v0.1.4...keenetic_xray_installer-v0.2.0) (2026-07-28)


### Features

* wire GoReleaser to release-please and mirror releases to latest ([#268](https://github.com/Kuzz007/keenetic_xray_installer/issues/268)) ([758a5bd](https://github.com/Kuzz007/keenetic_xray_installer/commit/758a5bd19ffdb58a1d40b678032318c4a2755aeb))


### Bug Fixes

* keep Proxy0 upstream on LAN IP ([98b7741](https://github.com/Kuzz007/keenetic_xray_installer/commit/98b77414088dcd09accb62f37d7924d92e6e12a2))
* **proxy0:** force LAN upstream after bot updates ([cf83dbb](https://github.com/Kuzz007/keenetic_xray_installer/commit/cf83dbba2c1d3c75999974e8e066020e17cfadc3))
