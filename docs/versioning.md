# Versioning and releases

Every machine tracks `main` (`dot up` pulls it), so tags are **reference points**,
not a channel you install from. They give you a name for "the state I was on",
a rollback anchor, and a changelog.

## Version scheme

Tags are dates: `vYYYY.MM.DD`, and `vYYYY.MM.DD.1`, `.2` for a second release the
same day. There is no semantic version: for a dotfiles repo "breaking" is not
well-defined, and a date says when it was cut.

The version a machine reports is **computed from git**, never stored in a file, so
it cannot drift from the history:

```sh
dot version
```

| Output | Meaning |
|---|---|
| `dotfiles v2026.10.04 (abc1234)` | exactly on that release |
| `dotfiles v2026.10.04 (+3 commits, abc1234)` | 3 commits past it |
| `dotfiles v2026.10.04 (+3 commits, abc1234, dirty)` | tracked files in the source directory are edited |
| `dotfiles abc1234 (untagged)` | no release tag is reachable |
| `dotfiles unknown (no git metadata in DIR)` | a copy of the repo without `.git` (exit 1) |

Untracked files do not count as `dirty`. `dot doctor` prints the same line as its
`dotfiles-version` check; it is informational and never a warning or an error.

## The changelog

[`CHANGELOG.md`](../CHANGELOG.md) is **generated** from the tags and commit titles by
`scripts/changelog.sh`. Do not edit it by hand: `tests/changelog_committed_contract.sh`
regenerates every section whose tag exists and fails on any difference.

It relies on the commit title, which the squash-merge makes the PR title:

| Title | Section |
|---|---|
| `feat(scope): ...` | Features |
| `fix(scope): ...` | Fixes |
| `docs: ...` | Documentation |
| `test: ...`, `ci: ...` | Tests and CI |
| `refactor: ...` | Refactoring |
| `chore: ...` | Maintenance |
| anything else | Other |
| any type with `!` (`fix(x)!: ...`) | **Breaking**, listed there only |

The `(#N)` GitHub adds becomes a PR link. Automation is not listed one by one:
`chore(release): ...` commits are dropped, and the version-pin bumps
(`chore: auto-update software versions`, `chore(guardrail): pin ...`) are summarised
as one line under Maintenance. The oldest tag is the **baseline**: its section lists no
commits, and earlier history stays in `git log`.

Useful while working:

```sh
bash scripts/changelog.sh --unreleased   # what is pending since the last tag
bash scripts/changelog.sh --next-tag     # the tag a release would get today
```

## Cutting a release

Two steps, each reviewed. Publishing creates a public tag and release, so it is
deliberate.

1. **Prepare**, on a branch fresh from `origin/main`:

   ```sh
   git switch -c chore/release origin/main
   bash scripts/release.sh prepare          # or: prepare vYYYY.MM.DD, --dry-run
   git add CHANGELOG.md
   git commit -m "chore(release): vYYYY.MM.DD"
   ```

   Open the PR and merge it like any other.

2. **Publish**, after it merged:

   ```sh
   bash scripts/release.sh publish vYYYY.MM.DD --dry-run   # the plan, nothing done
   bash scripts/release.sh publish vYYYY.MM.DD
   ```

   This tags the **release commit** (annotated), pushes the tag, and creates the
   GitHub Release with that changelog section as its notes (`gh` is required). It
   tags the release commit, not `HEAD`: the version-pin bot lands commits on `main`
   within minutes of a merge, and a tag on `HEAD` would then list commits the
   committed `CHANGELOG.md` does not.

`prepare` refuses to run with uncommitted tracked changes, from a `HEAD` that is not
`origin/main`, or when there is nothing to release. `publish` refuses a malformed tag,
a tag that already exists (locally or on origin), and a tag with no merged
`chore(release)` commit.

## Rolling back

To go back to a release:

```sh
git -C ~/.local/share/chezmoi checkout v2026.10.02
chezmoi apply
```

Two things to know. chezmoi does not delete files that a *newer* version added, so
those stay. And `dot up` expects the `main` branch, so switch back first:
`git -C ~/.local/share/chezmoi switch main`. `dot version` shows `(+N commits)` or the
tag you are on, so you can always tell where you are.
