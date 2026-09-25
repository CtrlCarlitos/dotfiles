# 🌿 Git

`dot_gitconfig.tmpl` renders `~/.gitconfig` on every machine. Identities and
per-folder accounts are covered in [devprofile](devprofile.md); this page covers
everything else: line endings, defaults, delta, and aliases.

## Line endings

**`.gitattributes` is the single authority**, and `core.autocrlf = false` on every
machine. That also overrides Git for Windows' system-level `autocrlf = true`.

- `* text=auto eol=lf`: text is LF in the repo and on disk, on every OS.
- `*.ps1`, `*.ps1.tmpl`, `*.bat`, `*.cmd`: CRLF (Windows-native scripts).
- Shell types (`*.sh`, `*.sh.tmpl`, `*.zsh`, `*.bash`): LF, explicitly.
- Images, archives, binaries: `binary`.

`.editorconfig` agrees with it, so editors write the same endings Git expects. The
managed VS Code baseline also sets `files.eol` to `\n` globally, so VS Code doesn't
create CRLF files on Windows in repos that have no `.gitattributes` of their own.

**Two different things decide endings, and neither is a per-OS git setting:**

| | Decided by | Result |
|---|---|---|
| Files **in a repo** (this one or any other) | `.gitattributes`, the same rules on every OS | `.ps1`/`.bat`/`.cmd` CRLF, everything else LF |
| **Applied dotfiles** in your home directory | chezmoi, which writes each OS's native endings | CRLF on Windows, LF on macOS/Linux/WSL |

So `~/.gitconfig` on Windows has CRLF while the same file on Linux has LF, from one
LF source file — chezmoi converts on write (verified: an LF source applied on Windows
lands as CRLF; `~/.zshrc` in WSL is LF). Nothing in the git config is OS-conditional
except `core.longpaths`.

On a **fresh Windows machine** this holds even before `~/.gitconfig` exists: Git for
Windows ships `core.autocrlf = true` at the system level, but an `eol` attribute
overrides `autocrlf`, so cloning this repo still checks out LF text and CRLF `.ps1`
files (verified with a clone under `autocrlf=true` and with no global config at all).

One consequence worth knowing: in a repo with **no** `.gitattributes`, `autocrlf =
false` means files land in your working copy exactly as stored — usually LF, where
stock Git for Windows would have given you CRLF. That's the intent (one policy
everywhere); `files.eol` keeps VS Code from reintroducing CRLF.

For another repo, `scripts/init-line-endings.{sh,ps1}` writes a matching
`.gitattributes` + `.editorconfig` pair from what the repo contains, then runs
`git add --renormalize .`.

### A checkout from before `.gitattributes` existed

A clone made before `.gitattributes` was added (2026-09-19) on Windows has **CRLF on
disk**: Git for Windows' system `autocrlf = true` applied at clone time, and Git never
rewrites unchanged files. The repository itself is fine (LF). `--renormalize` fixes
only the repository side, so it doesn't help here. What goes wrong: shellcheck and
`bash` complain about `\r`, and any file copied out of the working tree is CRLF.

Fix it once, **with a clean working tree** (commit or stash first):

```sh
git status              # must show nothing to commit
git rm -r --cached -q .
git reset --hard        # re-checks out every file with .gitattributes' endings
```

A fresh clone never needs this.

## Defaults

| Setting | Value | Why |
|---|---|---|
| `init.defaultBranch` | `main` | |
| `user.useConfigOnly` | `true` | Never guess an identity; see [devprofile](devprofile.md) |
| `commit.gpgsign`, `gpg.format` | `true`, `ssh` | Signed commits with the account's SSH key (when an account has a key) |
| `pull.rebase` | `true` | Linear history on pull |
| `rebase.autoStash` | `true` | Pull/rebase with local changes |
| `rebase.updateRefs` | `true` | Stacked branches move together in a rebase |
| `push.autoSetupRemote`, `push.default` | `true`, `current` | `git push` on a new branch just works |
| `push.followTags` | `true` | Annotated tags go up with their commits |
| `fetch.prune` | `true` | Deleted remote branches disappear locally |
| `merge.conflictstyle` | `zdiff3` | Conflict markers include the common base (see below) |
| `rerere.enabled` | `true` | A resolved conflict is replayed the next time it appears |
| `diff.algorithm`, `diff.colorMoved` | `histogram`, `default` | Cleaner diffs; moved lines colored as moves |
| `branch.sort` | `-committerdate` | `git branch` shows recent branches first |
| `tag.sort` | `version:refname` | `v1.10` sorts after `v1.9` |
| `help.autocorrect` | `prompt` | Typos offer the right command |
| `apply.whitespace` | `fix` | Patches applied with `git apply` / `am` get trailing whitespace stripped |
| `core.editor` | `code --wait` or `vim` | VS Code when it's available |
| `core.longpaths` | `true` (Windows only) | Deep trees exceed the 260-character path limit |

Requires Git 2.38 or newer (`rebase.updateRefs`, `zdiff3`). Ubuntu 24.04 and current
macOS and Git for Windows all qualify.

## delta

With the `modern_cli` group, delta is the pager (`core.pager = delta`) and colors
`git add -p` hunks (`interactive.diffFilter = delta --color-only`). It uses the
**Catppuccin Mocha** syntax theme, the same palette as the terminals (see
[Terminal Experience](terminal.md)), with line numbers and `n`/`N` to jump between files.

**Conflicts:** `merge.conflictstyle` can't be delta. It only picks how markers are
written into files (`merge`, `diff3`, `zdiff3`). The two work together: `zdiff3`
writes markers with the common base, and during a merge `git diff` through delta
shows each conflict as separate "ours" and "theirs" diffs against that base.

## SSH

The global `core.sshCommand` (and each account's include file) uses that account's
key with `IdentitiesOnly=yes`, so Git never offers the wrong key to GitHub. On
Windows that's Git's bundled `ssh`, which reads key files directly. See
[Windows](windows.md#git-for-windows) for what that means for passphrases.

`[url "git@github-<user>:<org>/"] insteadOf` rules rewrite HTTPS GitHub URLs for your
accounts and organizations to the matching SSH alias. Cloning
`https://github.com/<you>/repo` therefore uses the right key automatically.

## Hooks

`core.hooksPath = ~/.config/git/hooks` makes every repository run the hooks in that
directory instead of its own `.git/hooks`. Today it holds one hook:

| Hook | Does |
|---|---|
| `commit-msg` | Removes any `Co-Authored-By: Claude <noreply@anthropic.com>` trailer (either capitalisation), says so on stderr, then runs the repository's own `.git/hooks/commit-msg` if there is one, passing its exit status through |

Why at the git layer: Claude Code only omits that trailer when its attribution
setting is off, and that setting is per machine and per agent. On 2026-09-24 a
commit picked it up while the setting was not yet applied, and GitHub's squash
merge then copied it a second time. The hook does not care what any agent's
settings were.

Two consequences of `core.hooksPath`:

- **Per-repo hooks run only if the shared directory chains to them.** Only
  `commit-msg` chains today. A repository that relies on its own `pre-commit` or
  `pre-push` needs a chaining twin added to `dot_config/git/hooks/` first.
- **`pre-commit install` refuses** while `core.hooksPath` is set globally. In that
  one repository, opt out with `git config core.hooksPath .git/hooks`; the shared
  hook then no longer runs there.

`git commit --no-verify` skips every hook, this one included.

`tests/git_hooks_contract.sh` runs the hook against fixture messages and through a
real `git commit` with `core.hooksPath` set.

## Aliases

| Alias | Runs |
|---|---|
| `s` | `status -sb` |
| `lg` / `lga` | compact graph, last 15 / all branches last 20 |
| `graph`, `hist`, `last` | full graph; dated history; last commit with stats |
| `cob`, `bra`, `brd` | `checkout -b`, `branch -a`, `branch -d` |
| `aa`, `ap` | `add --all`, `add --patch` |
| `can` | `commit --amend --no-edit` |
| `unstage` | `restore --staged --` |
| `undo` | `reset --soft HEAD~1` (keeps the changes) |
| `sl`, `sp`, `ss` | `stash list`, `stash pop`, `stash push` |
| `pu`, `puf`, `pl` | `push`, `push --force-with-lease`, `pull` |
| `rv` / `remotes`, `ra` | `remote -v`, `remote add` |
| `cleanup` | delete local branches already merged, except exactly `main` / `master` and checked-out ones |
| `whoami` | the identity Git will use here |

The shells add their own OMZ-style shortcuts on top (`gst`, `gco`, `gp`, …): see
[Zsh Tips](zsh-tips.md) and [Windows](windows.md#powershell-profile).
