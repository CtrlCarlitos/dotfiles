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
| Dotfiles | `dot` family (`dot up` / `dot upgrade` / `dot backup` / `dot restore` / `dot doctor`), `devprofile` / `dp` |
| Windows Terminal | reports the current folder (OSC 9;9), so splits open where you are (the 5.1 profile does too) |
| SSH agent | tops up the Windows ssh-agent with your declared keys (only adds, never removes) |

`dot_aliases.zsh` stays the source of truth for aliases; the profile ports the
subset that maps cleanly to PowerShell. The profile's comments explain each
deliberate omission.

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
dir, chezmoi version drift vs `.chezmoi-version`, and the guardrail pin —
the failure classes `chezmoi doctor` can't see. Unix twin:
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

## Troubleshooting

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
