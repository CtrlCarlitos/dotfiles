# 🪟 Windows Setup

This guide covers Windows-specific configuration for a seamless development experience with WSL.
**Note**: Your PowerShell profile and packages are managed by **Chezmoi**.

## Overview

### Run `dot up` as Administrator

The chezmoi installer hard-requires an elevated terminal: Chocolatey,
OpenSSH capabilities, winget (VS Build Tools), and graft's native parser
builds all need Administrator. A non-elevated `dot up` exits 1 **before
changing anything**, and chezmoi does not record failed scripts — the next
elevated `dot up` re-runs the installer with every admin step intact.
(Never run it half-elevated by ignoring the warning: older versions
"succeeded" degraded and silently burned the one-shot trigger for the
elevated follow-up — that's why the gate exists.)

Sudo-style alternatives to opening a separate elevated terminal:

- **Windows 11 built-in sudo** (24H2+): enable once in Settings → System →
  For developers → "Enable sudo", then `sudo dot up` from a normal session.
- **gsudo** (`choco install gsudo`): the community standard for older
  builds; `gsudo dot up` behaves like Linux sudo, including credential
  caching.

### `dot up` vs `dot upgrade`

| | `dot up` | `dot upgrade` |
|---|---|---|
| What it does | `chezmoi update --apply`, then `chezmoi init` (re-renders the config template after the pull), then a final `chezmoi apply` only if init changed `chezmoi.toml`; re-reads the registry PATH into the current session | the choco and winget sweeps, then the AI tools (`scripts/update_ai_tools.ps1`) |
| Upgrades tools? | **Never.** The installer only installs what is missing | **Yes, and it is the only command that does** |
| Elevation | required (installer gate, see above) | required (`scripts/dotupgrade.ps1`) |
| Agents running? | run it with none | run it with none; live ones defer their tool |

The one exception inside the installer that `dot up` runs is npm itself: it is upgraded
once per run, and only when the registry has something newer (`npm is current (...)`
otherwise).

VS Code extensions follow the same rule: `dot up` lists what is installed once (a local call,
about 3 s) and installs only the missing ones, with no `--force`. It used to force-reinstall all of
them every run, which hit the marketplace for each one: a single slow response cost minutes (one
run took 4m44s with two failures) and extensions were upgraded behind `dot upgrade`'s back.
`dot upgrade` now runs `code --update-extensions`.

### `dot upgrade` on Windows: admin + winget

`dot upgrade` is the single owner of tool upgrades (system packages + AI
tools; `dot up` never upgrades). On Windows it is administrator-only by
design — `scripts/dotupgrade.ps1` checks `IsInRole(Administrator)` and
**exits without changing anything** from a normal shell, printing the
re-run hint. The same UAC constraints as `dot up` apply: use an elevated
terminal, Windows 11 `sudo`, or gsudo.

The Windows sweep upgrades system packages with `choco upgrade all` (the
reason elevation is required) and `winget upgrade --all
--include-unknown` (store apps can abort on interactive source agreements —
the script warns and continues), then the AI tools via
`update_ai_tools.ps1`. Like its Unix twin it
defers upgrades for tools whose directories live agent sessions are
currently using (via `DOTUPGRADE_DEFER`), and reports what to re-run when
quiet. Inside a devcontainer, upgrades ship via image rebuild and the
Unix twin (`scripts/dotupgrade.sh`) no-ops.

The `choco upgrade all` sweep prints a one-line summary (`Nothing to upgrade (101 packages
checked)` or `Upgraded 2 of 101: antigravity (2.18.1 -> 2.19.1), ...`) instead of one line per
package. What a package's own installer says still streams live, so a hung or prompting installer
stays visible, and the full output is kept in `~\.local\state\dotfiles\upgrade.log` (one previous
generation, `upgrade.log.1`, is kept once the log passes 2 MB). A non-zero exit prints the last
lines of the output; exit 1641 or 3010 prints that a restart is needed instead.

The sweep leaves out Chocolatey's `claude` package (Claude Desktop) whenever any `claude.exe` is
running: its installer ends with `taskkill /F /IM claude.exe /T`, and Claude Code's CLI has the same
image name, so the upgrade would kill live Claude Code sessions. `dot upgrade` says so; the next run
with Claude closed takes the package. This check is by image name only, unlike the live-session
check below.

**Where the time goes.** A Windows `dot upgrade` took 13 minutes with no breakdown, so each script now
marks its sections (sessions, Docker Desktop, choco, winget, VS Code extensions, AI tools; inside the AI
tools: npm packages, curated skills, guardrail, Claude Code, OpenCode, Playwright, agent-browser, Serena and
Graft) and ends with one line, for example `Timings (dot upgrade, 13m03s): choco 6m10s, AI tools 4m20s, ...`,
listing sections of 5 seconds or more, slowest first (`DOT_TIMING_MIN_SECONDS` changes the floor), plus the
same line for the AI-tools part. Time spent answering a prompt (stop sessions, stop Docker) is its own
section, `your answers`, so it is not counted as the work it interrupted. The line is appended to `upgrade.log` (Linux and macOS:
`~/.local/state/dotfiles/upgrade.log`) so one run can be compared with the next. Shell twin:
`scripts/lib/timing.sh`; PowerShell twin: `Add-DotTimingMark` / `Write-DotTimingSummary` in
`scripts/lib/ps-common.ps1`; `tests/upgrade_timing_contract.sh` runs both against a fake clock.

**winget** gets the same treatment: its output streams (minus spinner and progress-bar noise) and is
kept in the same `upgrade.log`, and the sweep ends with what it upgraded (`winget upgraded 2 package(s).`)
and, from a second listing, what is **still pending** (`Still pending in winget: Docker Desktop (4.93.0 -> 4.94.0), ...`).
winget lists some packages it cannot upgrade at all (`A newer version was found, but the install
technology is different`: Docker Desktop installed by Chocolatey, Microsoft Edge). When it reports blocked
upgrades, each pending package is asked about by id, and the ones it refuses move out of "still pending"
into `Not upgradeable through winget (installed another way; choco or the app itself updates it): ...`.
For Docker Desktop that means a newer winget build is not an upgrade `dot upgrade` can do while Chocolatey
owns the app: no offer to stop Docker is made until the `docker-desktop` choco package catches up.

**Docker Desktop** cannot be replaced while it runs: its installer (Chocolatey's `docker-desktop`, or
winget's `Docker.DockerDesktop` for the same app) used to do nothing, silently. When an upgrade is pending
and Docker Desktop is up, `dot upgrade` offers to stop it first (`docker desktop stop`, then the remaining
processes) with the same rule as the agent sessions: it asks on an interactive console, never when
`DOTUPGRADE_NO_PROMPT=1` or non-interactive, and says plainly that the upgrade was left for the next run.
Stopping it stops every running container, and they are not restarted afterwards. If it is kept running,
`docker-desktop` is left out of the choco sweep (`--except=docker-desktop`, combined with `claude` when both
apply) and the winget summary names the pending version.

**VS Code is closed first.** A VS Code window attached to a dev container loses it the moment Docker
stops, so when you accept the Docker Desktop stop and VS Code (`Code.exe`, or `Code - Insiders`) is
running, the same prompt says so and VS Code is closed **before** Docker: every window gets a normal
close request (so VS Code saves its state and ends the session cleanly), then anything still alive after
20 seconds is ended. It happens only as part of that stop, never on its own; it is not reopened
afterwards (VS Code restores its windows and a dev container reconnects once Docker is up). A VS Code
that hosts the terminal running `dot upgrade` is never closed, since that would end the command
itself, the same rule as agent sessions: the prompt warns that its container windows will disconnect,
and running `dot upgrade` from Windows Terminal avoids that. WSL needs nothing of its own: Docker
Desktop and VS Code both run on Windows (VS Code connects to WSL through its server), the WSL
`dot upgrade` upgrades neither, and the Windows `dot upgrade` above closes VS Code, including windows
connected to WSL. Native Linux and macOS have the same rule in the shell twin; see
[Docker and VS Code on Linux and macOS](tool-parity.md#docker-and-vs-code-on-linux-and-macos).

What the AI-tools step does on Windows:

| Tool | Behavior |
|---|---|
| Codex (npm package) | skipped when `npm ls -g` already matches the registry's latest (`codex is current (...)`); an unreachable registry counts as "not current" |
| Graft | skipped when `graft version` reports the installed version equals the latest published one. Otherwise installed with `npm install -g @nanonets/graft@latest` (with the installer's allow-scripts list), **not** `graft upgrade`, which fails on Windows with `spawnSync npm ENOENT`. Afterwards `graft --version` must start, and graft's Codex hook paths in `~\.codex\hooks.json` are normalized to forward slashes |
| OpenCode | `choco upgrade opencode`; a legacy npm-global `opencode-ai` shim is removed |
| Claude Code | the native installer is re-run (URL from `versions.claude_install_ps1`); deliberately **not** `claude update`, since `dot upgrade` is meant to run with every agent closed. Linux, macOS and WSL do the same |
| Skills | per-source: skipped when every skill is present and upstream HEAD equals the commit recorded in `%USERPROFILE%\.local\state\dotfiles\skills-sources`; `DOT_SKILLS_FORCE=1` forces a reinstall. See [Skills install strategy](skills-install-strategy.md) |

What counts as a live session is decided by process name **and** executable path
(`Get-LiveAgentProcess` in `scripts/lib/ps-common.ps1`; `live()` in `dotupgrade.sh`).
Codex's shared app-server daemon (it runs its own copy under
`~\.codex\packages\app-server-daemon\`, not the npm-global CLI the upgrade replaces) and
Claude Desktop (under `AnthropicClaude\`, not Claude Code) do not defer anything. A
process whose path cannot be read (an elevated process seen from a normal shell) still
counts. The Unix twin applies the Codex-daemon rule only (it has no Claude Desktop path rule).
The daemon keeps running the release it started with, so it would stay behind the upgraded
CLI. With no Codex session left, `dot upgrade` therefore stops it (`codex app-server daemon
stop`, falling back to ending the daemon's own process) before the sweep; it restarts on
demand, on the new version, and nothing in the dotfiles starts it. A live Codex session
keeps the daemon, and Codex, deferred.

#### When to run it: with every agent session closed

Run `dot up` and `dot upgrade` from a plain elevated terminal with **no agent
running** — Claude Code, Codex, OpenCode, `agy` and Serena all count, and so
does the session you are reading this in. `dot upgrade` scans for those processes and
**defers** what a live session resolves its files from:

| Live process | Deferred |
|---|---|
| `codex` | the Codex npm package |
| `opencode`, `claude`, `codex` or `agy` | Graft (every hook event resolves its directory) |
| `serena` | Serena (`uv tool upgrade` recreates its environment) |
| `opencode` | OpenCode |

Everything else (choco, winget, skills, Playwright, and the Claude Code
binary itself) still upgrades, so a run with sessions open is safe, just
incomplete: it ends with `Deferred (live sessions): ...`. Close the sessions
and run `dot upgrade` again to pick those up. Expect to reopen apps as well:
the sweep can replace the running Windows Terminal or Claude Code, and
neither takes effect until restarted.

#### The offer to stop live sessions

On an interactive console, `dot upgrade` first lists the blocking processes and asks:

```text
These sessions block part of the upgrade:
  claude (pid 1234, started 09:12)
Stop them so everything upgrades now? [y] all  [s] choose each  [N] keep and defer
```

`y` stops all of them, `s` asks per process, anything else (the default) keeps today's
defer-and-report. Stopping ends that session, so unsaved context is lost unless it can be
resumed. On Windows each process is asked to close its window, then the whole process tree
is killed after 5 seconds (Serena leaves language-server children behind); the Unix twin
sends TERM to the tree and KILL after 5 seconds. Then the live-session scan runs again, so
only what is still running defers.

A terminal UI that is ended this way never switches off what it turned on (mouse reporting, focus
reports, bracketed paste, the kitty keyboard protocol, the alternate screen), so its terminal went on
typing those reports into the prompt as stray characters. Before the kill on Windows (a short-lived child
attaches to the agent's console and writes the switch-offs there), and after the stop on Unix (written to
the agent's tty), `dot upgrade` switches them off. If a terminal still misbehaves after a stopped session,
`reset` (or closing the tab) clears it.

Never offered: this shell's own ancestry (the shell, the terminal, and the agent session
that launched `dot upgrade`), since stopping it would end the command; those still defer.
No prompt, only defer-and-report, when stdin or stdout is not a terminal or when
`DOTUPGRADE_NO_PROMPT=1`. The contract is `tests/dotupgrade_stop_sessions_contract.sh`.

#### Stop upgrades from recreating desktop shortcuts

Installers drop a shortcut on the Desktop on every upgrade, and neither
`choco upgrade all` nor `winget upgrade --all` has a global switch against
it. Set this in `~/.config/chezmoi/chezmoi.toml`:

```toml
[data.upgrade]
  desktop_shortcuts = false
```

`dot upgrade` then snapshots the `.lnk`/`.url` files on your Desktop and the
Public Desktop before the sweeps and deletes only the ones that appeared
during them, listing each. Shortcuts you already had are never touched.
Absent or `true` keeps today's behavior. The table survives `chezmoi init`.
Windows only: apt packages add menu entries rather than Desktop icons, and
Homebrew casks install into `/Applications`.

Windows provides the host side of the setup:

- **Windows Terminal**, configured by chezmoi. Details are in [Terminal Experience](terminal.md).
- **VS Code**, with Remote - WSL / SSH / Containers.
- **PowerShell 7** with a managed profile, for Windows-native work.
- **Git for Windows**, for Windows-side repos (including this one).

## Windows Terminal

Install it from the Microsoft Store or with `winget install Microsoft.WindowsTerminal`.
Chezmoi then merges its settings into Terminal's `settings.json`: the Catppuccin look,
the Nerd Font, tab colors per environment, one profile per SSH host, pane and agent
keys, and highlight-to-copy. The **[Terminal Experience](terminal.md)** guide covers
all of it, plus the VS Code terminal, OpenCode, and SSH hosts.

### Font

The `fonts` package group installs **MesloLGS Nerd Font** (Chocolatey
`nerd-fonts-meslo`), and the Terminal and VS Code settings select it. There's no
manual step. To confirm the font is installed:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -Filter "*Meslo*"
```

> **Face name:** the package (Nerd Fonts v3 naming) registers `MesloLGS Nerd Font`,
> `MesloLGS Nerd Font Mono`, and `MesloLGS Nerd Font Propo`. There is no family
> literally named `MesloLGS NF`, despite that being the font's common nickname. Use the
> **`Mono`** variant in terminals: it keeps icon glyphs one cell wide, so prompt output
> stays aligned. The plain and `Propo` variants are for proportional text in GUI editors.

## VS Code Configuration

### Managed Extensions and Settings

The installer installs the repository-curated VS Code baseline globally,
including Remote - WSL, Remote - Containers, and Remote - SSH. Do not add
GitLens to the managed list; it is explicitly excluded from this setup.

For machine-specific additions or exclusions, use `[data.vscode_overrides]` in
`~/.config/chezmoi/chezmoi.toml`. See [VS Code](vscode.md) for the supported
fields and settings behavior, and [Terminal Experience](terminal.md) for the
integrated terminal.

## PowerShell Profile

Chezmoi manages both profiles:

- PowerShell 7: `Documents/PowerShell/Microsoft.PowerShell_profile.ps1`
- Windows PowerShell 5.1: `Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1`

With OneDrive folder redirection, `$PROFILE` lives under
`OneDrive - <tenant>\Documents`, a path chezmoi can't target portably.
`run_onchange_sync_pwsh_profiles` copies the managed profiles there whenever they
change. Edit them in the repo, not in OneDrive; local edits there are overwritten.

What the PowerShell 7 profile sets up:

| Area | What |
|---|---|
| Prompt and navigation | starship, zoxide; `..` / `...` / `....`, `~` |
| Modern tools | `ls`→eza (`ll`, `la`, `lt`, `lta`), `cat`→bat, `vim`/`vi`/`v`→nvim |
| Git | OMZ-style `gst`, `gd`, `gl`, `gp`, `gco`, `ga`, `gcam`, `gb` |
| Parity with `dot_aliases.zsh` | `c`, `h`, `py`, `nr`/`nrd`/`nrb`, `serve`, `ff`, `path`, `prof`, `get`/`post`, docker `d`/`dc*` |
| Dotfiles | `dot` family (`dot up` / `dot upgrade` / `dot backup` / `dot restore` / `dot doctor` / `dot remote` / `dot devtmp` / `dot version` / `dot ssh-fingerprints`), `devprofile` / `dp` |
| Windows Terminal | reports the current folder (OSC 9;9), so splits open where you are (the 5.1 profile does too) |
| SSH agent | tops up the Windows ssh-agent with your declared keys (only adds, never removes) |

`dot_aliases.zsh` stays the source of truth for aliases; the profile ports the
subset that maps cleanly to PowerShell. The profile's comments explain each
deliberate omission.

**The two profiles are twins.** A feature added to one (the `dot` function, the
autocd handler, `clip-to-file`, `serena-clean`, the OpenCode clipboard block) belongs
in the other, adjusted for 5.1 (no `cd -`, for example). The `dot` dispatcher is
identical in both and a third copy lives in zsh; `tests/dot_unknown_command_contract.sh`
executes all three, and `tests/pwsh_profiles.ps1` parses and dot-sources both. `dot <unknown>` prints `dot: unknown command '<x>'`, a hint that a shell
started before `dot up` keeps the `dot` it loaded (open a new shell), then the help,
and exits 2. See invariant 10 in [invariants.md](invariants.md#10-both-twins-or-neither).

## Git for Windows

The `core` group installs Git for Windows (Chocolatey `git.install`), and chezmoi
writes `~/.gitconfig`. See **[Git](git.md)** for the defaults, line endings, and
aliases. Windows-specific points:

- `core.autocrlf = false` overrides Git for Windows' system-level `true`;
  `.gitattributes` decides line endings.
- `core.longpaths = true`, because deep trees (`node_modules`) exceed the 260-character path limit.
- Git uses its bundled `ssh`, which reads key files directly. That's fine for keys
  without a passphrase. The bundled `ssh` can't reach the Windows ssh-agent service,
  so passphrase-protected keys would prompt on every push.

## devprofile (PowerShell)

`devprofile` manages which Git identity (name/email/signing key) is active, based on your chezmoi accounts.

**You usually don't need to run this at all** - each account's `dirs` list is already wired into `~/.gitconfig` as a conditional include, so the right identity is selected automatically by which folder a repo lives in. `devprofile` is for the exceptions: a repo outside any mapped `dirs` path, double-checking the active identity, installing a pre-commit identity check, or creating a new account. See [devprofile](devprofile.md#example-outputs) for annotated example output of each command.

```powershell
devprofile                                      # Show the identity active in the current repo
devprofile list
devprofile use <username>
devprofile init <username> <email> -Passphrase
devprofile verify -InstallHook
```

Notes:
- `dp` is a short alias for `devprofile`, same as in zsh.
- `devprofile verify -InstallHook` preserves any existing hook as `pre-commit.user`.
- Passphrases are optional. You can force prompts with `$env:DEVPROFILE_PASSPHRASE=1`.
- Auth vs signing keys: `key` is for auth; `signingKey` is optional for signing. If omitted, `key` is used for both.
- If you use separate auth/sign keys, a passphrase on **both** is recommended. Use Windows OpenSSH agent to cache prompts.
- `devprofile use <account>` signs with that account's `signingKey` (falling back to `key` only if unset) - same key `chezmoi apply` wires up globally.
- `devprofile verify`'s `Dir` row flags it if the active identity doesn't match what the current repo's path maps to in `dirs` - catches a `use` run in the wrong repo, or a repo moved under the wrong account's directory.

### Editing `chezmoi.toml` on Windows — keep it UTF-8

`~/.config/chezmoi/chezmoi.toml` must be **UTF-8**. Editors saving as
Windows-1252/ANSI (Notepad's legacy mode, or a WinMerge copy session) turn
the template's em dashes into single 0x97 bytes, and the very next
`chezmoi init --apply` dies with `invalid UTF-8 byte` (confirmed live:
mid-install, three retries, no hint of the cause). Use VS Code or PowerShell
`Set-Content -Encoding utf8` — never "ANSI".

After any hand-edit, run the repo's own doctor:

```powershell
pwsh -File "$(chezmoi source-path)\scripts\dotfiles-doctor.ps1"        # check
pwsh -File "$(chezmoi source-path)\scripts\dotfiles-doctor.ps1" -Fix   # repair pure ANSI saves
```

It checks config encoding/parseability, prompted-key completeness, source
dir, chezmoi version drift vs `.chezmoi-version`, the guardrail pin, the installed dotfiles version (`dot version`), and that
`python3` resolves to a real interpreter (see [python3 on
Windows](#python3-on-windows)) — the failure classes `chezmoi doctor` can't see. Unix twin:
`bash "$(chezmoi source-path)/scripts/dotfiles-doctor.sh" [--fix]`.

Existing keys without passphrases:
```powershell
ssh-keygen -p -f "$env:USERPROFILE\.ssh\id_yourkey"
```

## Clipboard Integration

- **In the terminals:** highlighting copies and right-click pastes, the same in
  Windows Terminal and the VS Code terminal. See [Terminal Experience](terminal.md#clipboard).
- **From the WSL shell:** `dot_aliases.zsh` maps `pbcopy` / `pbpaste` to `clip.exe`
  and PowerShell's `Get-Clipboard` (to `xclip` on a Linux desktop), so the macOS
  habits work:

  ```bash
  echo "hello" | pbcopy
  pbpaste
  ```

- **tmux in WSL:** `y` in copy mode pipes to `clip.exe`.
- **Over SSH:** tmux and Neovim use OSC 52 instead, see
  [Terminal Experience](terminal.md#remote-ssh-hosts).

## File System Access

| From | Path |
|------|------|
| Windows → WSL | `\\wsl$\Ubuntu\home\<username>` |
| WSL → Windows | `/mnt/c/Users/YourUsername` |

**Tip**: Keep projects in WSL filesystem for better performance.

## Networking

WSL2 has its own network adapter. To access services:

| Direction | How |
|-----------|-----|
| Windows → WSL | `localhost:PORT` (usually works) |
| WSL → Windows | Use host IP from `cat /etc/resolv.conf` |

## Post-install notes

The installer used to print the same four manual-step notes on every run. Each now
prints only when its probe says it still applies, and a probe that cannot tell (tool
missing, command failed or hung) prints the note, since a hidden problem is worse than a
repeated reminder (`tests/windows_post_install_notes_contract.sh`):

| Note | Printed when |
|---|---|
| Docker Desktop EULA | `docker info` fails |
| WSL Integration | a real WSL distro (Docker's own `docker-desktop` distros excluded) has Docker Desktop's WSL Integration off, read from Docker Desktop's `settings-store.json`; with no distro at all it suggests `wsl --install -d Ubuntu` |
| Tailscale sign-in | `tailscale status` fails (`remote_access` group only) |
| sshd | the `sshd` service is not running (`remote_access_server` group only) |

The Docker notes exist only with the `dev_desktop` group. Other quiet-output changes: one
line per skills source (`<name>: up to date`), the agent-browser `doctor --json` result is
summarised, and the installer's `curl` downloads are quiet.

## Line endings and the PowerShell scripts

`.gitattributes` is the single authority: the index holds LF for every text file, while
`*.ps1`, `*.ps1.tmpl`, `*.bat` and `*.cmd` check out as CRLF (shell scripts stay LF), and
`core.autocrlf` is `false`. `git ls-files --eol` shows both forms; `git diff` hides drift.
`tests/line_endings_contract.sh` enforces it ([invariant 8](invariants.md#8-line-endings-come-from-gitattributes-not-from-your-editor);
the Windows bash-suite side is issue #233). Applied dotfiles get each OS's native endings
from chezmoi; `~/.ssh/id_*` key files are the exception, stripped of CR on every apply
and checked by `dot doctor`.

Rules learned the hard way when changing the Windows scripts:

- **Strict mode:** the installer and several scripts run under `Set-StrictMode -Version
  Latest`, where reading an unset variable is an error. Every `$script:Name` that is read
  must be initialised at script scope before the function that reads it
  (`tests/ps_script_scope_vars_contract.sh`; it broke the first Windows `dot up` once).
- **Native stderr on Windows PowerShell 5.1:** under `$ErrorActionPreference = 'Stop'` any
  stderr line from a native command becomes a terminating error. Probe natives under
  `Continue` and judge by exit code, as `Test-NpmGlobalCurrent` and `Invoke-GraftNpmInstall` do.
- **`jq.exe` emits CRLF** under Git Bash; every `jq` call in `scripts/*.sh` carries `jq -b`
  (`tests/jq_binary_contract.sh`).
- **Twins:** a change to a `.sh` / `.ps1` pair, or to one PowerShell profile, is a bug in
  the other until proven otherwise ([invariant 10](invariants.md#10-both-twins-or-neither)).

## Troubleshooting

### Antimalware Service Executable busy during Go builds

Defender rescans every freshly built test binary. See [devtmp.md](devtmp.md)
(`dot devtmp`) for a single build-output folder and the exclusion it prints for
you to run.

### python3 on Windows

POSIX has `python3`; the official Windows Python installer ships only
`python.exe` (plus the `py` launcher). The repo's scripts and tests assume the
POSIX name, so `chezmoi apply` deploys two tiny Windows-only shims to
`~\.local\bin`: `python3` (bash, for Git Bash) and `python3.cmd` (cmd and
PowerShell). Both forward every argument to `python`.

Windows also ships a **Microsoft Store `python3.exe` stub** (an "App execution
alias"). It lives in `WindowsApps`, which comes earlier on PATH than
`~\.local\bin`, so it shadows the shim and answers `Python was not found; run
without arguments to install from the Microsoft Store`. Turning the alias off
only removes the stub; it does not create a `python3`, which is why the shim is
needed either way.

`dotfiles-doctor.ps1` checks this by behaviour: does `python3 --version` print
`Python 3.x`? It only ever warns (an error would fail every apply). A genuine
Store-installed Python also lives in `WindowsApps` and passes.

- **Turn the stub off yourself:** Settings > Apps > Advanced app settings >
  App execution aliases > `python3.exe`.
- **Or let the doctor do it:**
  `dot doctor --fix` (or `pwsh -File "$(chezmoi source-path)\scripts\dotfiles-doctor.ps1" -Fix`)
  removes the `python3.exe` stub in `WindowsApps` and nothing else. It never
  runs during `chezmoi apply`. A Store update can re-create the stub; re-run the
  doctor if `python3` breaks again.

### SSH agent

Windows and WSL each run their own agent. Nothing is shared between them, by design:

- **Windows:** `ssh-agent` is a service. `run_onchange_generate_identities`
  sets it to Automatic and starts it (the first time needs an elevated shell), and
  the PowerShell profile adds your declared keys at startup. To check: `ssh-add -l`.
  The service serves Windows OpenSSH (`ssh.exe`), not the `ssh` that Git for Windows
  bundles; see [Git for Windows](#git-for-windows).
- **WSL:** the Oh My Zsh `ssh-agent` plugin starts a per-login agent and loads the
  keys the identities script lists (`zstyle :omz:plugins:ssh-agent identities`).

If a key is missing from `ssh-add -l`, re-open the shell. If it's still missing,
check that the key file exists in `~/.ssh` and is listed in your chezmoi accounts.

### Fonts Not Displaying

- **Check elevation first.** If the installer never ran elevated, Chocolatey never
  installed `nerd-fonts-meslo`. See the elevation note at the top.
- **Confirm the font is installed** (see [Font](#font)). The `fonts` group being
  `true` doesn't prove the install ran.
- **Windows Terminal and VS Code** select the font themselves (see
  [Terminal Experience](terminal.md)). Icons broken only in a WSL tab mean the
  Terminal template hasn't been applied yet. WSL's own generated profile forces
  `Ubuntu Mono`, and the template overrides it.
- **Legacy console windows** (Git Bash, Git CMD, PowerShell shortcuts opened outside
  Windows Terminal) read `HKCU:\Console\<app>` `FaceName`, not any of this.
  Set those by hand.
- Restart Windows Terminal (or VS Code) after a font change.

### Package installs failing

Chocolatey requires an **elevated PowerShell**. Without it, every `choco install`
fails with exit code 1, one per package, with no single loud error pointing at the
real cause. The installer now checks elevation first and exits before changing
anything (see [Run `dot up` as Administrator](#run-dot-up-as-administrator)). So if
packages are missing, the most likely cause is that the elevated run never
happened. Re-run `dot up` from an elevated shell.

### chezmoi itself won't run at all ("Application Control policy has blocked this file")

Different failure mode from the one above: here `chezmoi.exe` itself refuses to
launch, rather than a package failing partway through. It's Windows Smart App Control
blocking the unsigned binary, confirmed live via the Windows Event Log. See the
matching entry in the repo README's Troubleshooting section for the full diagnosis
and fix.

---

## Checklist (new Windows machine)

- [ ] Run the installer from an **elevated** PowerShell (see the README).
- [ ] Open Windows Terminal: Catppuccin colors, Nerd Font icons in the prompt, and
      an orange WSL tab.
- [ ] VS Code: its terminal shows the same colors, and extensions are installed.
- [ ] `ssh-add -l` in PowerShell lists your keys.
- [ ] `git config user.email` inside a repo under an account's `dirs` shows that
      account (see [devprofile](devprofile.md)).
- [ ] Add your SSH hosts to `[[data.ssh_hosts]]` and apply; an `SSH: <name>` tab
      appears for each (see [Terminal Experience](terminal.md#remote-ssh-hosts)).
