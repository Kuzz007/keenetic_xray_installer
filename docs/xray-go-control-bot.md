# Xray Go control bot MVP

This document describes the proposed multi-router control plane for Keenetic Xray Go installs.

## Goal

Manage several routers from one Telegram bot running on a VPS without opening inbound ports on routers.

```text
Telegram admin
  -> VPS xray-go-control-server
  -> outbound router agents
  -> local xray-go / failover / watchdog / recovery helpers
```

## Components

### VPS

```text
cmd/xray-go-control-server
```

Responsibilities:

- accept Telegram commands from one admin account;
- keep a registry of routers and per-router tokens;
- receive router heartbeats;
- queue allowlisted commands for a selected router;
- receive command results;
- notify admin about results and events.

### Router

```text
cmd/xray-go-agent
```

Responsibilities:

- run on Keenetic/Entware as an init service;
- poll the VPS over outbound HTTPS/HTTP;
- execute only allowlisted local actions;
- never expose an inbound port;
- never print raw VLESS/subscription values back to the server;
- report command results and heartbeat state.

## Security model

- Telegram commands are accepted only from `ADMIN_USER_ID`.
- Each router has a unique `AGENT_TOKEN`.
- Router agents authenticate every request with `Authorization: Bearer <token>`.
- Commands are allowlisted; arbitrary shell execution is intentionally unsupported.
- Source URLs are accepted only for dedicated source-update actions and are redacted from results.
- Support diagnostics use `xray-go doctor --support`.
- Logs are limited with `tail -n`.

## MVP command allowlist

```text
status             -> xray-go status
doctor             -> xray-go doctor --support
switch_primary     -> xray-go switch primary
switch_backup      -> xray-go switch backup
recover_status     -> xray-go recover status
recover_check      -> xray-go recover check
recover_run        -> xray-go recover
recover_enable     -> xray-go recover enable-hourly
recover_disable    -> xray-go recover disable-hourly
history            -> xray-go history
watchdog_log       -> tail -n 100 /opt/var/log/vless-go-watchdog.log
recovery_log       -> tail -n 100 /opt/var/log/vless-go-recover.log
source_status      -> xray-go status, redacted summary only
set_primary_source -> vless-go-failover set-primary <hidden> --selector <selector>
set_backup_source  -> vless-go-failover set-backup <hidden> --selector <selector>
```

## Source update flow

1. Admin selects a router.
2. Admin sends a new primary or backup VLESS/subscription URL.
3. VPS queues a source-update command for the chosen router.
4. Router agent receives the command.
5. Router agent runs the local failover helper with the source value.
6. Router agent redacts the source value from all output.
7. Router agent reports only result metadata.

The bot must not echo raw source values back to Telegram.

## Router config example

```sh
SERVER_URL="https://control.example.com"
ROUTER_ID="home"
ROUTER_NAME="Дом"
AGENT_TOKEN="replace-with-long-random-token"
POLL_INTERVAL="5"
```

## VPS config example

```sh
LISTEN=":18090"
BOT_TOKEN="123456:telegram-token"
ADMIN_USER_ID="123456789"
ROUTERS="home:token1:Дом,dacha:token2:Дача,office:token3:Офис"
```

## Telegram command examples

```text
/routers
/status_home
/doctor_home
/switch_primary_home
/switch_backup_home
/recover_home
/history_home
/watchdog_home
/recoverylog_home
/set_primary_home first vless://...
/set_backup_home first https://subscription.example/path
```

The first token after `/set_primary_<router>` or `/set_backup_<router>` is the selector. The remaining text is treated as the source value and is redacted in results.
