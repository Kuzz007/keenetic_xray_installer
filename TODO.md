# TODO

## Route list automation

- [ ] Design a safe upstream/import pipeline for all `routes/*.txt` lists.

  Current automatic updater covers only machine-readable official IP sources:

  - `amazon` / AWS CloudFront IPv4 prefixes
  - `cloudflare` IPv4 prefixes
  - `fastly` IPv4 prefixes

  Open design questions:

  - [ ] Choose primary upstream source for domain lists, for example `v2fly/domain-list-community` or another ruleset repository.
  - [ ] Add `routes-sources.yml` with explicit mapping from local list id to upstream source/file.
  - [ ] Add importer that supports only safe record types first: plain domains and `full:` domains.
  - [ ] Do not import `regexp:`, broad `keyword:`, or implicit includes until reviewed.
  - [ ] Keep curated/manual lists separate from generated lists where needed, for example `github` domains vs optional `github-ip` ranges.
  - [ ] Decide whether ASN/BGP-generated lists are acceptable for broad providers such as `akamai`, `digitalocean`, `meta`, and `ovh`.
  - [ ] Start with manual-only workflow that opens a PR with diff summary before enabling scheduled updates.
  - [ ] Add validation for duplicates, invalid domains, unsafe values, unexpectedly large diffs, and list-id mismatch.

  Candidate phases:

  1. Import a small test set from a domain ruleset source: `github`, `telegram`, `youtube`.
  2. Add more curated domain services after reviewing diffs: `discord`, `gemini`, `tiktok`, `tidal`.
  3. Evaluate optional ASN/BGP-generated route lists separately from the safe updater.

## Operational tooling ideas

- [ ] Add `xray-go doctor-full`.

  One command should check the full installation state: Xray binary, Xray config validation, active slot, primary/backup source presence, watchdog, recovery cron, routes helper/cache, bot agent, disk space, required opkg packages, DNS availability, and `Proxy0`/policy availability.

- [ ] Add `xray-go report` with secret redaction.

  Generate `/tmp/xray-go-report.txt` with versions, services, disk/memory state, active slot, routes status, recent logs, and diagnostics. Redact `vless://`, tokens, server URLs with embedded credentials, and other sensitive values so the report can be safely shared.

- [ ] Add snapshot and rollback center.

  Before dangerous operations, create snapshots under `/opt/etc/xray/snapshots/<timestamp>/` containing Xray config, active slot, primary/backup stores, relevant helper state, and optionally Keenetic `running-config`. Provide commands to list and restore snapshots.

- [ ] Add routes dry-run and diff commands.

  Candidate commands:

  - `xray-keenetic-routes-catalog plan <list_id>`
  - `xray-routes diff <list_id>`

  The plan command should show object-group/policy changes before applying. The diff command should show added/removed route entries after route catalog updates.

- [ ] Add Telegram bot confirmations for dangerous commands.

  Require a second explicit confirmation for `reboot`, route apply/remove, source replacement, Xray-core update, and similar destructive or connectivity-impacting actions.

- [ ] Add a unified component version source.

  Consider a `VERSION` or `versions.json` file so installer, menus, package metadata, bot agent, and route updater can report consistent release/component versions.

- [ ] Add install/update self-test.

  After install or update, run syntax checks for installed scripts, Xray config validation, helper executable checks, cron checks, agent config readability checks, and produce a concise OK/WARN/FAIL summary.

- [ ] Add routes safety limits.

  For automated route updates, fail or require manual review if a managed list grows/shrinks too much, contains invalid values, introduces duplicates, or changes unexpectedly large portions of the file.

- [ ] Add optional release notes automation.

  Generate draft release notes from merged PRs and grouped changes, but do not auto-publish releases until the workflow has been tested.

- [ ] Add optional update channels.

  Consider `stable`, `beta`, and `canary` update channels so routers can opt into safer or earlier installer/helper updates.
