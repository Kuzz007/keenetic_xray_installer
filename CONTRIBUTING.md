# Contributing

## Commit messages

This repo uses [release-please](https://github.com/googleapis/release-please) to
compute the next version and changelog from commit history on `main`. Write
commit subjects as [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Common types:

- `feat:` — new user-facing capability (minor version bump)
- `fix:` — bug fix (patch version bump)
- `chore:`, `docs:`, `refactor:`, `test:`, `ci:` — no version bump, still shows
  in commit history but excluded from the changelog by default
- A `BREAKING CHANGE:` footer (or `!` after the type/scope, e.g. `feat!:`)
  triggers a major version bump

Squash-merged PRs: the squash commit message (usually the PR title) is what
release-please parses, so make sure the PR title itself follows this format.

Commits that don't follow this format aren't rejected — they just won't be
picked up by release-please's version/changelog computation.
