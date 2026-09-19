# 🪟 Windows Setup

This guide covers Windows-specific configuration for a seamless development experience with WSL.
**Note**: Your PowerShell profile and packages are managed by **Chezmoi**.

## Overview

Your development happens inside WSL, but Windows provides:
- **Windows Terminal** - Modern terminal emulator
- **VS Code** - Editor with Remote-WSL extension
- **Git** - For any Windows-native repos (rare)

## Windows Terminal Configuration

### Install Windows Terminal

```powershell
# From Microsoft Store or:
winget install Microsoft.WindowsTerminal
```

### Recommended Settings

TODO: Document your preferred settings

Key settings to configure:
- [ ] Default profile → Ubuntu/WSL
- [ ] Font → A Nerd Font (for Starship icons)
- [ ] Terminal → Windows Terminal (recommended)
- [ ] Color scheme
- [ ] Key bindings
- [ ] Starting directory

### Font Installation

For Starship to display correctly, install a Nerd Font:

1. If `install_fonts = true`, this repo already installs it for you via the
   `nerd-fonts-meslo` Chocolatey package - no manual download needed. Confirm
   it's actually there first: `Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -Filter "*Meslo*"`.
   Otherwise, download from [nerdfonts.com](https://www.nerdfonts.com/)
   - Recommended: **MesloLGS Nerd Font** (Excellent choice)
   - Alternative: **JetBrainsMono Nerd Font**

2. Install by right-clicking the `.ttf` files → Install

3. **Set the font in Windows Terminal settings - this step does not happen
   automatically**, even when the repo installed the font files for you.
   Installing the font and *selecting* it in your terminal profile are two
   separate steps; skipping the second one is the most common reason icons
   still look broken after a full install.

### Example settings.json Snippet

> **Face name:** the Chocolatey `nerd-fonts-meslo` package (Nerd Fonts v3
> naming) registers `MesloLGS Nerd Font`, `MesloLGS Nerd Font Mono`, and
> `MesloLGS Nerd Font Propo` - there is no family literally named `MesloLGS NF`
> despite that being the font's common nickname (confirmed by listing installed
> font families on a real machine). Use the **`Mono`** variant for terminals -
> it fixes icon glyphs to a single cell width so prompt output stays aligned;
> the plain/`Propo` variants are meant for proportional text in GUI editors.

```json
{
    "profiles": {
        "defaults": {
            "font": {
                "face": "MesloLGS Nerd Font Mono",
                "size": 11
            }
        },
        "list": [
            {
                "guid": "{YOUR-WSL-GUID}",
                "name": "Ubuntu",
                "source": "Windows.Terminal.Wsl",
                "startingDirectory": "//wsl$/Ubuntu/home/<username>"
            }
        ]
    }
}
```

### Finding Your WSL GUID

To find the GUID for your WSL distributions, run this in PowerShell:

```powershell
Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss |
% {
  $p = Get-ItemProperty $_.PsPath
  "$($p.DistributionName) => $($_.PSChildName)"
}
```

Example output:
```
Ubuntu-24.04 => {12345678-1234-1234-1234-123456789abc}
```

Use this GUID in your Windows Terminal `settings.json` to configure the profile manually.

## VS Code Configuration

### Extensions to Install

- [ ] Remote - WSL
- [ ] Remote - Containers (for devcontainers)
- [ ] GitLens
- [ ] TODO: Add your preferred extensions

### Settings Sync

If using Settings Sync, document any Windows-specific overrides needed.

## PowerShell Profile

TODO: If you use PowerShell for anything, add configuration here.

Location: `$PROFILE` (usually `~\Documents\PowerShell\Microsoft.PowerShell_profile.ps1`)

```powershell
# Example: Quick access to WSL
function wsl { wsl.exe -d Ubuntu }

# Example: SSH agent forwarding
# TODO: Document if needed
```

## Git for Windows

Generally not needed since Git runs in WSL, but if required:

```powershell
winget install Git.Git
```

Configure to use WSL's SSH:
```
TODO: Document SSH agent sharing if needed
```

## devprofile (PowerShell)

`devprofile` manages which Git identity (name/email/signing key) is active, based on your chezmoi accounts.

**You usually don't need to run this at all** - each account's `dirs` list is already wired into `~/.gitconfig` as a conditional include, so the right identity is selected automatically by which folder a repo lives in. `devprofile` is for the exceptions: a repo outside any mapped `dirs` path, double-checking the active identity, installing a pre-commit safety net, or creating a new account. See the [README's Git Identity section](../README.md#git-identity-devprofile) for annotated example output of each command.

```powershell
devprofile                                      # Show the identity active in the current repo
devprofile list
devprofile use <username>
devprofile init <username> <email> -Passphrase
devprofile verify -InstallHook
```

Notes:
- No `dp` alias is defined for PowerShell yet (unlike the `dp` alias in zsh) - use `devprofile` in full.
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

Clipboard sharing between Windows and WSL is automatic in modern WSL.

From WSL:
```bash
# Copy
echo "hello" | clip.exe

# Paste
powershell.exe -command "Get-Clipboard"
```

The aliases in this dotfiles repo handle this automatically.

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

### Slow WSL Startup

TODO: Document common fixes

### SSH Agent Not Working

TODO: Document SSH agent setup for Windows ↔ WSL

### Fonts Not Displaying

- **Check elevation first** - if PowerShell wasn't running as Administrator
  when `chezmoi apply` ran, `choco install nerd-fonts-meslo` failed outright
  (confirmed live: every Chocolatey package fails with exit code 1 without
  elevation) and the font was never installed at all, not just misconfigured.
  See "Package installs silently failing" below before checking anything else.
- Confirm the font is actually installed (`install_fonts = true` doesn't
  guarantee it ran, or that it's this profile's active font):
  `Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" -Filter "*Meslo*"`
- Set the font in the Windows Terminal profile - installing it is not the same
  as selecting it, and nothing does the second step for you (see the face-name
  note above; `MesloLGS NF` alone won't match anything installed)
- Also check VS Code's `terminal.integrated.fontFamily` if icons look wrong
  specifically in its integrated terminal, and legacy console apps (Git Bash,
  Git CMD, PowerShell shortcuts opened outside Windows Terminal) separately -
  they read `HKCU:\Console\<app>` `FaceName`, not the Windows Terminal config
- Restart Windows Terminal (or VS Code) after changing the font

### Package installs silently failing

Chocolatey requires an **elevated PowerShell** ("Run as Administrator") -
without it, every `choco install` fails with exit code 1, one per package,
with no single loud error to point at the real cause (confirmed live this
session: an entire non-elevated run failed every package the same way, and
it wasn't obvious from the output alone that elevation was the problem).

- **Symptom:** `chezmoi apply` finishes without an overall failure, but
  packages/fonts/tools you expected are missing afterward.
- **Fix:** close the window, reopen PowerShell via **Run as Administrator**,
  and re-run `chezmoi apply`.

### chezmoi itself won't run at all ("Application Control policy has blocked this file")

Different failure mode from the two above - this one is `chezmoi.exe`
itself refusing to launch, not a package install failing partway through.
It's Windows Smart App Control blocking the unsigned binary, confirmed live
via the Windows Event Log - see the matching entry in the repo README's
Troubleshooting section for the full diagnosis and fix.

---

## Checklist

Complete these items from Windows:

- [ ] Install Windows Terminal
- [ ] Install Nerd Font
- [ ] Configure Windows Terminal settings
- [ ] Install VS Code extensions
- [ ] Test clipboard integration
- [ ] Document any custom PowerShell profile
