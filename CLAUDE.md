# CLAUDE.md

Operational memory for working on this repo. For the feature-level roadmap
(direct-install v2 checklist), see `TODO.md`. For commit message format, see
`CONTRIBUTING.md`. This file is about pipeline mechanics, repo-specific
gotchas, and conventions learned the hard way — read it before touching CI,
release plumbing, or the agent/control-server subsystem.

## Architecture

- **Router-side installer**: POSIX `sh` scripts (`install.sh` at root,
  `scripts/*.sh`), fetched and run via `curl | sh` on Keenetic/Entware. Two
  install profiles: Full Go/Entware and Minimal Go (see `TODO.md` section 5).
- **3 Go binaries** (`cmd/xray-failover-go`, `cmd/xray-go-agent`,
  `cmd/xray-go-control-server`), Go 1.22, no external deps (no `go.sum`).
  - `xray-failover-go`: the core failover/profile-switch logic, runs on the router.
  - `xray-go-agent`: polls a control server for remote commands, runs on the
    router. Has a POSIX-shell fallback twin, `scripts/xray-go-agent-shell.sh`
    (marked experimental) — same protocol, independent implementation, used
    when the compiled binary isn't viable for an architecture. Don't expect
    changes in one to apply to the other; they share no code.
  - `xray-go-control-server`: a separate server (deployed to a VPS via
    `scripts/xray-go-control-server-install.sh` + a systemd unit, NOT part of
    the router installer) that agents poll and that runs a Telegram bot for
    remote multi-router control. TLS is self-signed with fingerprint pinning
    (agents pin the SHA256 fingerprint like an SSH host key, not a CA chain).
- **Shell script dedup**: `fetch_url`/`sha256_file`/`looks_like_shell_script`
  live once in `scripts/lib/xray-go-common.sh`. Hand-edited fragments in
  `scripts/src/direct/*.sh` and `scripts/src/misc/*.sh` (source, minus those
  3 functions) get spliced with the shared lib by
  `sh scripts/build-generated-scripts.sh` into the actual published,
  git-committed scripts (`scripts/xray-go-direct-*.sh`, `install.sh`, and
  the other `scripts/*.sh` files the manifest covers). **Never hand-edit a
  generated file's copy of these 3 functions** — edit the fragment or the
  lib and rebuild. CI (`installer-smoke-test.yml`) fails if generated output
  doesn't match a fresh build. The splice point is detected dynamically
  (shebang + optional `set` line), not a hardcoded line count — some
  fragments have no `set` directive.

## Release pipeline

`go.mod` → `go-ci.yml` (lint/test/build matrix, now with QEMU smoke-tests,
see below) → `.goreleaser.yaml` → `release-please.yml`.

Flow: commits to `main` following Conventional Commits (`CONTRIBUTING.md`)
→ release-please maintains one open "release PR" (title
`chore(main): release X.Y.Z`) that auto-updates as commits land → merging it
creates a real `vX.Y.Z` tag + GitHub Release → `release-please.yml`'s
`publish` job runs `goreleaser release --clean` (attaches all 3 binaries'
full arch matrix + `checksums.txt`) → then force-moves the mutable `latest`
tag to that release and mirrors all assets there with per-file `.sha256`
sidecars, because 8+ router-side scripts hardcode
`releases/download/latest/<asset>[.sha256]` URLs.

**QEMU smoke tests** (`go-ci.yml`'s `build` job): after cross-compiling each
arm64/mipsle/mips binary, it's actually executed under `qemu-<arch>-static`
(installed via apt, not `docker/setup-qemu-action` — that action's bundled
emulators dropped mips/mipsle support upstream). `xray-failover-go` gets a
real check via `-version`; `xray-go-agent`/`xray-go-control-server` are
daemons with no no-op flag, so they're pointed at a config path that can't
exist and checked for a clean status-1 failure (a real exec-format/SIGILL
problem exits with a signal-based status instead).

## Repo-specific gotchas (all confirmed firsthand, not theoretical)

- **"Allow GitHub Actions to create pull requests" is disabled on this
  repo.** Any workflow that does `gh pr create` under the default
  `GITHUB_TOKEN` will fail at that exact step with "GitHub Actions is not
  permitted to create or approve pull requests" — everything before it
  (including committing and pushing a branch) still succeeds. This is why
  `.github/workflows/harden-shell-agent-downloads.yml` failed all 7 of its
  runs on 2026-05-25 despite its patch logic being correct; if you find a
  similarly-shaped stuck automation, check for this exact failure signature
  before assuming the patch itself is broken.
- **release-please's release PR's `shellcheck` check gets stuck at
  `action_required` with zero jobs dispatched, every single time the PR is
  updated.** Confirmed across three separate release cycles (0.2.0, 0.3.0,
  0.2.1) — the release PR's branch is pushed by `github-actions[bot]`
  (release-please itself), and workflow runs triggered by that actor need
  manual approval before any job runs, unlike PRs pushed by a real user.
  There's no API-based approve for this (only environment-protection-rule
  approvals have that); it needs a human to open the stuck run's page
  (`Actions` tab → the run → "Approve and run") and click through. It does
  **not** block merging the release PR itself (`mergeable_state` is
  `unstable`, not `blocked` — shellcheck isn't a required check), so if the
  approval is inconvenient, merging without it is fine; the check just stays
  permanently unresolved on that PR. This will keep happening on every
  future release-please PR until someone changes the repo's Actions
  approval policy (Settings → Actions → General) — that's outside what's
  achievable from a session without repo-admin UI access.
- **A tag pushed via `GITHUB_TOKEN` does not trigger other workflows.**
  This is standard GitHub Actions behavior (loop prevention), confirmed
  empirically against this repo's actual run history: `go-ci.yml`'s old
  `push: tags: ['v*']` trigger never fired once across the repo's whole
  history, because release-please/GoReleaser always create tags using the
  default token. Don't design a release step assuming a tag push will
  cascade into another workflow — it won't, unless a human pushes the tag
  with their own credentials/PAT. (This is also why the now-removed
  `attach-release-asset` job in `go-ci.yml` was dead code — see commit
  `fe43878`.)
- **The local git proxy's remote-tracking refs can be stale.** A plain
  `git fetch origin <branch>` sometimes doesn't update
  `refs/remotes/origin/<branch>` even though the real remote has moved;
  `git ls-remote origin <branch>` bypasses the staleness and shows the true
  tip. If a push is rejected as non-fast-forward and the local view
  disagrees with `ls-remote`, force-refresh with an explicit refspec:
  `git fetch origin +refs/heads/<branch>:refs/remotes/origin/<branch>`.
- **Squash-merge leaves the dev branch's own history "behind" origin/main**
  (the squash commit on `main` has a different SHA than anything on the
  branch, even though the content is identical). Pushing the same branch
  name again for the next piece of work then gets rejected as
  non-fast-forward. Standard recovery, safe every time it's been needed
  here: verify the old branch tip's content is fully subsumed by the new
  `origin/main` (`git diff <old-branch-tip> <new-main-tip> --stat` — empty
  output means safe), then `git checkout -B <branch> origin/main` (or
  `--force` push) to restart clean. Never force-push without that diff
  check first.

## Conventions

- **Two files are permanently excluded from `gofmt`**, written in a
  deliberately compact single-line style:
  `cmd/xray-go-agent/mux_config.go` and
  `cmd/xray-go-control-server/main.go`. `go-ci.yml`'s formatting check
  greps them out explicitly. Never reformat them to standard Go style, and
  match their compact style when hand-editing them (new files added to
  either package — `state.go`, `auth_test.go`, etc. — use normal `gofmt`
  style; the exclusion is per-file, not per-package).
- **PR-per-logical-change, draft-then-merge.** Every PR this session was
  opened as a draft, watched via `subscribe_pr_activity` until CI was green
  and the user explicitly confirmed ("зелёный"/"да"), then marked ready and
  squash-merged. Don't merge without that confirmation unless told
  otherwise. Don't bundle unrelated changes into one PR by default — this
  session did it twice (PR #277 ended up with 5 commits across shell-agent
  hardening, control-server state persistence, constant-time auth, poll
  backoff, and dead-code cleanup) only because they were discovered
  together in one investigation and the branch was already open; splitting
  would have been cleaner if there'd been no time pressure.
- **Always develop on branch `claude/keenetic-xray-project-0c3qzk`** (per
  this session's task instructions) — reset it from `origin/main` at the
  start of each new piece of work once the previous PR has merged, don't
  stack unrelated work on an unmerged branch if avoidable.
- Router-facing shell scripts target POSIX `sh` (busybox ash on
  Entware/Keenetic) — no `local`, no bashisms. `shellcheck -s sh -S warning`
  is the CI gate (`.shellcheckrc` documents the 2 intentionally-disabled
  checks: SC1090 for runtime-path `source`, SC1007 for the `CDPATH= cd --`
  idiom).

## Current state (as of 2026-07-28, end of session)

Released: **v0.2.1** (latest release-please cycle), mirrored to the
`latest` GitHub Release channel that all router-side install/update scripts
pull from.

This session's work, in order (all merged, all on top of an already-working
release pipeline from a prior session — go.mod, unified CI, GoReleaser,
release-please were already in place before this list starts):

1. **#274/#275** — deduplicated `fetch_url`/`sha256_file`/
   `looks_like_shell_script` across all 17 router-side scripts that had
   their own copies (the source+build pattern described above).
2. **#276** — added QEMU smoke-tests for cross-compiled Go binaries in CI.
3. **#277** — five agent/control-server fixes found during a manual code
   survey (not asked for individually, found by reading through the
   subsystem): shell-agent download hardening (syntax-check before
   executing anything fetched over HTTP), control-server command
   queue/results persistence across restarts (previously in-memory only —
   `cmd/xray-go-control-server/state.go`), constant-time router-token
   comparison (`crypto/subtle`), agent poll backoff on consecutive
   failures, and removal of the two dead-code items above.
   `xray-go-control-server` had zero tests before this PR; it has 10 now
   (`state_test.go`, `auth_test.go`).

Explicitly considered and **declined**: binary signing (cosign/minisign) —
assessed as not worth the operational cost (offline key management,
router-side verification code) for a single-user personal deployment; the
realistic threat it closes (GitHub account/CI compromise, or third-party
tampering with an already-published release asset) is low-probability here
and HTTPS+sha256 already covers the common cases (network tampering,
corrupted downloads). Revisit only if the project gains other users or
there's a concrete reason not to trust GitHub's account security for this
repo specifically.

Not done, no active plan: expanding control-server test coverage beyond
`state.go`/`authRouter` (the Telegram bot handlers, wizard flow, and HTTP
routing are all still untested); redeploying the updated control-server
binary to the user's actual VPS (state persistence and constant-time auth
are in the shipped binary but only take effect after a manual
`xray-go-control-server-install.sh --update-only` run there — nothing in
CI/CD does this automatically, by design, since the control server isn't
part of the router installer).