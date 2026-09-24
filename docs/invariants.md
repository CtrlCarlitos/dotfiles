# Invariants

Rules this repo has learned the expensive way. Each one is stated as a rule,
followed by the incident that produced it and how to check you are obeying it.

None of these are style preferences. Every one of them describes a change that
looked correct, passed review, and was silently wrong — usually on a machine
other than the one it was written on.

> **Why this file is in `docs/` rather than a root `CONTRIBUTING.md`:** everything
> under `docs/` is structurally checked by `tests/docs_contracts.sh` — no dead
> links, no stale anchors, no user-facing TODOs. A rules file that itself rots is
> worse than none.

---

## 1. `.chezmoiignore` matches **target** paths, never source paths

The names in `.chezmoiignore` are the paths as they will exist in `$HOME`, not
the `dot_`/`private_`/`executable_` names in the source tree.

**The incident.** A devcontainer block listed `private_dot_ssh/**` and
`dot_gitconfig-*`. Both are source spellings, so both matched nothing at all,
for as long as they had existed. Confirmed by diffing the ignore sets:

```sh
diff <(chezmoi ignored) <(DEVCONTAINER=true chezmoi ignored)   # was empty
```

**Obey it.** Write `.ssh/**` and `.gitconfig-*`. Then prove it: `chezmoi ignored`
prints the real list, and the `diff` above shows what a condition actually changes.

**A corollary worth remembering.** Correcting those two patterns revealed the rule
was wrong to begin with — chezmoi manages only `~/.ssh/config` in a container,
never key material, and that file carries the `github-<user>` aliases that
`.gitconfig`'s `insteadOf` depends on. The "fix" broke git in containers while
protecting nothing. A pattern that matches nothing is not harmless; it hides
whether the rule was ever right.

---

## 2. Everything in the source tree lands in `$HOME` unless ignored

There is no "repo-only" area by default. A file added for tooling is a dotfile
until you say otherwise.

**The incident.** 29 CI test files, a stale `~/scripts`, `~/AGENTS.md`, `~/graft`,
`~/guardrail.toml`, and 15 MB of `~/.oh-my-zsh` plus `~/.tmux` on Windows — for two
programs that do not run there, because WSL has its own home. Managed targets went
from **2295 to 37**.

**Obey it.** After adding anything to the source tree:

```sh
chezmoi managed | wc -l      # should not jump
chezmoi managed | grep <thing>
```

`tests/home_scope_contract.sh` enforces the current boundary.

---

## 3. A file the app rewrites must be **merged, not owned**

If a program writes to its own config, chezmoi cannot own that file. Use a
`modify_` template that reads the current contents from `.chezmoi.stdin` and
forces only the keys you care about.

**The incident.** Windows Terminal's `settings.json` was owned. Terminal rewrote
it within seconds of the first apply — it does so on every Settings UI save, and
whenever it detects a new VS Code, WSL or PowerShell install — so every
subsequent `dot up` hit chezmoi's *"changed since chezmoi last wrote it"* prompt.

**Obey it.** The repo has four of these, and they are the pattern to copy:

| File | Rewritten by |
|---|---|
| `AppData/.../LocalState/modify_settings.json` | Windows Terminal |
| `dot_config/opencode/modify_tui.json` | OpenCode |
| `dot_codex/modify_config.toml` | Codex |
| `*/modify_keybindings.json` | VS Code |

Ask one question: *does this program ever write this file itself?* If yes, merge.

---

## 4. A modify-template uses `includeTemplate`, not `{{ template }}`

**The incident.** A shared fragment was pulled in with `{{ template "..." . }}`.
It rendered perfectly under `chezmoi execute-template` and failed at apply time
with `template not defined` — on someone else's machine.

**Obey it.** Use `{{- includeTemplate "name" . -}}`. And note the deeper lesson:
`chezmoi execute-template` does **not** exercise the same code path as
`chezmoi apply`. Where that difference matters, a test must apply a scratch
source end-to-end, as `tests/windows_terminal_contract.sh` does.

---

## 5. Pin a tool to the file under test

A tool that resolves its own configuration will not necessarily resolve the same
file you are inspecting.

**The incident.** `scripts/dotfiles-doctor.sh` derived `$config` from `$HOME`,
encoding-checked that file, then validated it with a bare `chezmoi data` — which
resolves its own config through `XDG_CONFIG_HOME`. Where those disagree (GitHub
runners set it; so do many desktops), chezmoi read a different, usually absent,
config, found nothing wrong, and the doctor reported *"chezmoi loads the config"*
about a file it had never opened.

```sh
chezmoi data                  # exit 0  — wrong file
chezmoi --config "$config" data   # exit 1  — the file under test
```

**Obey it.** Pass the path explicitly. Never let ambient resolution stand in for
the thing you are asserting about.

---

## 6. A skip is not a pass

**The incident.** `bash tests/*.sh` on Windows reports `33 passed, 0 failed` while
4 of those skip outright — and that number was reported as evidence a branch was
ready.

**Obey it.** `tests/suite_integrity_contract.sh` now fails the build on any skip
on a platform that should run everything, and prints the accounting explicitly:

```
suite: 33 passed, 0 skipped, 0 failed
```

Run the suite in **WSL or Linux**, not Git Bash, before claiming it passes.
Skip guards are legitimate for genuinely absent tooling; they are not a way to
make a failing test quiet.

---

## 7. Wiring is what makes a test real

**The incident.** Seven test files were never referenced in `ci.yml` and had
therefore never run once. One of them, `agent_skill_wiring_contract.sh`, was
mis-spliced so two functions sat inside others and were never defined.

Note what was *not* happening: bash fails loudly on an undefined function. CI
never tolerated that file — it never executed it. The nesting bug surfaced the
moment the file was wired.

**Obey it.** Add the test to `.github/workflows/ci.yml` in the same commit that
adds the file. `tests/suite_integrity_contract.sh` enforces this.

---

## 8. Line endings come from `.gitattributes`, not from your editor

`* text=auto eol=lf` with `*.ps1 text eol=crlf` is the whole policy. chezmoi
writes each OS's native endings on apply; the repo stores one canonical form.

**The incidents.** A CRLF `.zshrc` tripped shellcheck SC1017. A test's fake `gum`
stub inherited CRLF from its heredoc, so its shebang carried a literal `\r` and
the stub could not execute — in a test that had never run.

**Obey it.** Write files with LF (`newline='\n'` if generating them). Check with
`git ls-files --eol`, which shows the index and worktree forms side by side.
Do not trust `git diff` here: it normalises on read, so a line-ending problem can
be invisible in a diff and still be real.

---

## 9. Go template comments need `{{- /*` with exactly one space

Go recognises a comment action only when `/*` sits exactly two bytes after `{{`.

```
{{- /* correct */ -}}
{{-     /* parses as a COMMAND: "unexpected /" */ -}}
```

**The incident.** A comment indented for readability inside a `range` block took
a debugging round to identify, because the error names a syntax problem that
looks nothing like a comment. `tests/codex_keymap_contract.sh` asserts against it.

---

## 10. Both twins, or neither

`run_onchange_install_packages.sh.tmpl` and its `.ps1` twin implement the same
policy in two languages. A change to one is a bug in the other until proven
otherwise — and the same applies to the `scripts/*.sh` / `*.ps1` pairs and to the
per-platform fixtures in `ci.yml`.

**The incident.** The two CI test configs drifted: the Unix one had no `username`
in `[[data.accounts]]`, the Windows one did. A template that reached for
`.username` without a `hasKey` guard therefore passed `Test (Windows)` and failed
Ubuntu and macOS — making a straightforward bug look platform-specific.

**Obey it.** When you touch one twin, grep the other for the same concept before
you commit. Reducing this duplication is tracked in issue #83.

The CI fixtures no longer have twins to keep in step: every job composes its
`chezmoi.toml` from `tests/fixtures/chezmoi/`, and `tests/ci_fixture_contract.sh`
fails if a workflow carries an inline one.

Neither do package names: `.chezmoidata/packages.yaml` is the one list, both
installers render their manager's names from it through `.chezmoitemplates/`
fragments, and `scripts/migrate-to-choco.ps1` reads it at runtime.
`tests/package_catalog_contract.sh` fails if a literal list reappears in any of
the three. Two things learned building it: `includeTemplate` returns the
fragment *with* its trailing newline (end the last action with `-}}`, or a
rendered `for x in …` loses its `; do` to the next line), and each installer
template renders only its own platform's branch - the contract value-checks
whichever twin the host renders, so both are exercised across the CI matrix.

---

## Checking yourself

```sh
bash tests/suite_integrity_contract.sh   # wiring, completion, no silent skips
bash tests/docs_contracts.sh             # TODOs, links, anchors, settings
chezmoi ignored | head                   # what will NOT be applied
chezmoi managed | wc -l                  # what WILL be
git ls-files --eol <file>                # index vs worktree line endings
```

Run the suite on Linux or WSL. Windows legitimately skips four tests, and a skip
is not a pass.
