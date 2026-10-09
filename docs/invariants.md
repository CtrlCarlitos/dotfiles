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

**Obey it.** CI runs the suite through `bash tests/run.sh --strict`, which fails
on any skip and prints the accounting explicitly:

```
suite: 33 passed, 0 skipped, 0 failed
```

Run the suite in **WSL or Linux**, not Git Bash, before claiming it passes: on
Windows `run.sh` tolerates skips (it prints a note) because POSIX modes, symlinks
and `gum` are absent there, so a clean Windows run proves less than a clean Linux
one. Skip guards are legitimate for genuinely absent tooling; they are not a way
to make a failing test quiet.

---

## 7. Wiring is what makes a test real

**The incident.** Seven test files were never referenced in `ci.yml` and had
therefore never run once. One of them, `agent_skill_wiring_contract.sh`, was
mis-spliced so two functions sat inside others and were never defined.

Note what was *not* happening: bash fails loudly on an undefined function. CI
never tolerated that file — it never executed it. The nesting bug surfaced the
moment the file was wired.

**Obey it.** Nothing to wire anymore: `tests/run.sh` executes every `tests/*.sh`
it finds, so a file cannot sit in the directory unwired. The `.ps1` twins are
the exception - the bash runner does not enumerate them - so they keep their
own `ci.yml` steps; add one in the same commit that adds the file.

---

## 8. Line endings come from `.gitattributes`, not from your editor

`.gitattributes` is the single authority: `* text=auto eol=lf`, so the **index
always holds LF**; `*.sh`, `*.sh.tmpl`, `*.zsh` and `*.bash` stay LF; and
`*.ps1`, `*.ps1.tmpl`, `*.bat` and `*.cmd` check out as **CRLF on every OS**
(still LF in the index). `core.autocrlf` is false everywhere. chezmoi writes each
OS's native endings on apply; the repo stores one canonical form.

**The incidents.** A CRLF `.zshrc` tripped shellcheck SC1017. A test's fake `gum`
stub inherited CRLF from its heredoc, so its shebang carried a literal `\r` and
the stub could not execute — in a test that had never run. Later, two tracked
files drifted unnoticed because `git diff` normalises on read (living issue #233).

**Obey it.** Write files with LF (`newline='
'` if generating them); the CRLF
types are the only exception, and they are CRLF only in the worktree. Check with
`git ls-files --eol`, which shows the index and worktree forms side by side.
Do not trust `git diff` here: it normalises on read, so a line-ending problem can
be invisible in a diff and still be real. `tests/line_endings_contract.sh` checks
the index, the worktree against each file's `eol` attribute, `.editorconfig`'s
CRLF section, and `core.autocrlf`.

**A native executable's output is out of reach of that policy.** A Windows
`jq.exe` opens stdout in text mode, so under Git Bash every line it prints ends in
CRLF and a stray `\r` rides into variables (`"opencode\r"` missed a lookup).
Every `jq` call in `scripts/*.sh` therefore carries `-b` (`--binary`; a no-op on
Linux/macOS). `tests/jq_binary_contract.sh` fails on a `jq` without it.

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

The `dot` dispatcher is a twin trio: `dot()` in `dot_aliases.zsh` and the `dot`
function in both PowerShell profiles (`Documents/PowerShell/` and
`Documents/WindowsPowerShell/`) must keep the same subcommands and the same
unknown-command behaviour. `tests/dot_unknown_command_contract.sh` executes all
three. The `.ps1` test twins (`tests/*.ps1`) are part of the same rule: the bash
runner does not enumerate them, so each needs its own `ci.yml` step.

The CI fixtures no longer have twins to keep in step: every job composes its
`chezmoi.toml` from `tests/fixtures/chezmoi/`, and `tests/ci_fixture_contract.sh`
fails if a workflow carries an inline one.

Neither do package names: `.chezmoidata/packages.yaml` is the one list, both
installers render their manager's names from it through `.chezmoitemplates/`
fragments, and `scripts/migrate-to-winget.ps1` reads it at runtime.
`tests/package_catalog_contract.sh` fails if a literal list reappears in any of
the three. Two things learned building it: `includeTemplate` returns the
fragment *with* its trailing newline (end the last action with `-}}`, or a
rendered `for x in …` loses its `; do` to the next line), and a render that
reads the host's `chezmoi.toml` is not a test - the CI lint runner seeds none,
so every group was off there and the check failed. Render with an empty
`--config` and `--override-data` forcing the groups and the OS you mean; that
also lets one host render *both* twins (`os: windows` for the `.ps1`, `darwin`
and `linux` for the `.sh`), so each is value-checked everywhere.

---

## 11. guardrail install logic lives in agent-guardrails

The dotfiles fetch and verify the pinned release's installer, then pass it a pin
and a state. Nothing more.

**The incident.** The four consumers carried four copies of the same install
logic: the binary download, the self-update floor, Windows PATH and Defender
handling, and the plane wiring. The copies drifted from agent-guardrails, and the Windows twins
kept working around two limits that no longer existed
([ADR-0029](https://github.com/CtrlCarlitos/agent-guardrails/blob/main/docs/adr/0029-installer-lives-in-this-repo.md)).

**Obey it.** Change the installer upstream. `tests/guardrail_lifecycle_contract.sh`
requires the fetch-verify-run shape between the `# guardrail-section` markers
and forbids a fixed list of install-era literals (plane and update calls,
binary asset names, Defender, `Unblock-File`) in the four consumers. Logic
that avoids those literals gets past it, so the rule is yours to keep.

A second thing the installer owns: replacing a running binary. The Windows
consumer once moved the installed `guardrail.exe` aside before every run, which
reset the evidence window (*"hook registered but NEVER OBSERVED FIRING"* after
every `dot up`) and sent upstream down its fresh-download path instead of its
update path. Leave the installed binary where it is and hand the installer the pin
and the state; `tests/guardrail_installer_no_rename_contract.sh` executes the
function with the network and the upstream installer stubbed.

---

## 12. In PowerShell strict mode, initialise every script-scope variable before use

The Windows installer and several scripts run under `Set-StrictMode -Version Latest`,
where **reading** a variable that was never set is a terminating error.

**The incident.** A once-per-run guard, `if (-not $script:NpmUpgraded -and ...)`,
shipped without an initialiser, so the first real `dot up` that reached
`Install-Node` died with *"The variable '$script:NpmUpgraded' cannot be retrieved
because it has not been set"* (#247). CI never saw it: its Windows jobs run with
every package group off, so `Install-Node` never executes there.

**Obey it.** Assign every `$script:Name` that is read at script scope (outside any
function) before the function that reads it is defined.
`tests/ps_script_scope_vars_contract.sh` checks this with PowerShell's own parser
on the rendered installer and on the plain scripts that set strict mode.

Its companion for native commands: under `$ErrorActionPreference = 'Stop'`,
Windows PowerShell 5.1 turns a native command's **stderr** into a terminating
error, so a command whose answer is its exit code or its output (`npm ls`,
`npm install -g`, `npm uninstall -g`) is run with the preference temporarily `'Continue'`
(`Test-NpmGlobalCurrent` in `scripts/lib/ps-common.ps1`, `Invoke-GraftRetirement` in
`scripts/lib/ps-skills.ps1`).

---

## 13. A docs-only change must still create the required check names

Required status checks are matched by **name**. The ruleset requires
`Test (ubuntu-latest)` and `Test (macos-latest)`, but a skipped *matrix* job records
one check literally named `Test (${{ matrix.os }})` and never the per-OS names, so a
docs-only PR could not merge.

**The incident.** The first CHANGELOG-only PR (#243) sat BLOCKED with every check
green.

**Obey it.** The heavy `test-unix` matrix runs only when `needs.changes.outputs.heavy
== 'true'`; its companion `test-unix-skipped` has the same name and OS list, runs in
the opposite case, and does one `echo`. Change one half and you must change the
other; `tests/ci_docs_only_checks_contract.sh` reads `ci.yml` and holds the pair
together. (The `lint` job always runs, with `fetch-depth: 0`, because the docs and
changelog contracts must gate a docs change.)

---

## 14. Prefer an executable contract to a grep

A test that greps a script for a string proves the string is there, not that the
behaviour works. The contracts that have caught real bugs **run** the code: they
extract a function and execute it against a fake `npm`/`git`/`choco`/`gum`, render
the real template with `--override-data`, execute the zsh `dot()` under bash, or
parse the script with PowerShell's own parser.

**The incident.** With no `chezmoi` on the lint job's PATH, the skill-wiring
contract skipped three rendering blocks and validated only greps while the job
stayed green. And the PowerShell checker behind invariant 12 is itself run on
known-bad and known-good fixtures first, so it cannot quietly start accepting
everything.

**Obey it.** When you add a contract, make it fail first (break the code, watch it
turn red, restore it) and assert on behaviour. Keep a grep only for what cannot be
executed, such as a forbidden literal (`forbid`) or a docs sentence.

---

## 15. In TOML, a block of two or more `key = value` lines shares one `=` column

`chezmoi init` rewrites `~/.config/chezmoi/chezmoi.toml` on every `dot up`, so the
file looks exactly as `.chezmoi.toml.tmpl` writes it. A block is a run of
consecutive `key = value` lines; a `[table]` header, a comment or a blank line ends
it. A single line can be written any way.

**The incident.** The account and SSH-host blocks padded their keys to a computed
column, but `auth_fingerprint`, `signing_fingerprint` and `identity_fingerprint` were
written unpadded, so every block that carried one was ragged. The VS Code settings,
written by chezmoi's `toToml`, were not aligned at all.

**Obey it.** A hand-written block computes its column from the keys it actually
emits (`printf "%-*s"`, like `[[data.accounts]]` and `[[data.ssh_hosts]]`). Output
of `toToml` goes through `.chezmoitemplates/toml-align`. The same holds for every
TOML file in the repo: `.chezmoiexternal.toml`, `starship.toml`, `.gitleaks.toml`,
the VS Code seed, `docs/chezmoi.toml.example`, `tests/fixtures/chezmoi/`. A comment
inside a block splits it, so put an entry's comment above its `[table]` header.
`tests/config_toml_alignment_contract.sh` checks every TOML file and renders the
template from a fixture carrying every key it emits; it fails on any ragged block.

---

## 16. PowerShell sources are ASCII (or carry a BOM)

Windows PowerShell 5.1, which the `dot` command also runs under, reads a script
without a byte-order mark as Windows-1252. A UTF-8 emoji, dash or arrow then decodes
to several characters, and some of those bytes (0x84, 0x91-0x94) are "smart quotes"
that PowerShell honours as string delimiters. Nothing fails to parse: the strings are
silently re-split, and the script breaks at run time.

**The incident.** `dot upgrade` under Windows PowerShell failed with "The term
'upgrading' is not recognized": the 0x93 byte of a package emoji in
`update_ai_tools.ps1` had closed a string many lines earlier. The file tokenized to
3272 tokens under 5.1 and 3410 under PowerShell 7.

**Obey it.** Write PowerShell in ASCII. Build an output glyph from its code point
(`[char]::ConvertFromUtf32(0x1F916)`, `[char]0x2713`). `install.ps1` (run as
`irm | iex`) and the `.ps1.tmpl` templates stay pure ASCII; another script that needs
literal non-ASCII text carries a UTF-8 BOM, like `devprofile.ps1`.
`tests/ps51_source_encoding_contract.sh` checks every PowerShell file and, on Windows,
compares each script's tokens under 5.1 and 7. CI's PSScriptAnalyzer keeps
PSUseBOMForUnicodeEncodedFile on.

---

## 17. `$SUDO` is a shell function: never put it under `timeout`

The installer's `$SUDO` (and its copy `$npm_sudo`) names `dot_sudo`, a function
that primes the password prompt on the first privileged command. coreutils
`timeout` exec()s its argument, and a function is not a file.

**The incident.** The lazy prime landed with every `net_timeout 300 $npm_sudo <cmd>`
call site unchanged. On the next WSL `dot up` the Playwright deps step printed
`timeout: failed to run command 'dot_sudo': No such file or directory` and warned
"failed or timed out" on every run; the first `npm -g` install and the
agent-browser install carried the same shape and would have failed the same way.
A second latent hang hid behind it: the keep-alive loop the prime starts inherited
the caller's stdout, so a first privileged command inside `$(...)` (the Codex
install) would have held the substitution's pipe open for the life of the apply.

**Obey it.** A privileged command that needs a wall clock goes through
`sudo_net_timeout` / `sudo_net_timeout_tty "$npm_sudo" <secs> <cmd...>`, which
primes through the function and puts the real `sudo` binary under the timeout.
Background jobs started from a function close both streams.
`tests/sudo_timeout_contract.sh` forbids a sudo variable under a timeout wrapper and
executes both helpers against a stub sudo binary, with the `$(...)` case under a
timeout of its own.

---

## Checking yourself

```sh
bash tests/run.sh --strict               # completion markers; any skip fails (TESTS_STRICT=0 tolerates)
bash tests/docs_contracts.sh             # TODOs, links, anchors, settings
chezmoi ignored | head                   # what will NOT be applied
chezmoi managed | wc -l                  # what WILL be
git ls-files --eol <file>                # index vs worktree line endings
```

Run the suite on Linux or WSL: some tests legitimately skip on Windows, and a skip
is not a pass.
