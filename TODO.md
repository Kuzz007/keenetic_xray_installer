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
