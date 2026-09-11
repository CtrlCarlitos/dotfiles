# Dotfiles (Chezmoi Managed)

This repository contains my personal dotfiles, managed by [Chezmoi](https://www.chezmoi.io/).  
It supports **Linux**, **macOS**, **Windows**, and **Devcontainers**.

## 🚀 Quick Start

### Universal Installer (Recommended)

> **Prerequisites:**
> *   **Linux/macOS:** `curl` and `git` must be installed.
> *   **Windows:** PowerShell and `winget` (App Installer) are required. The script will install Git if missing.

> **Do you need `sudo` / an elevated prompt?**
> *   **Linux/macOS/WSL:** No - run it as your normal user, **without** `sudo`. The
>     script elevates internally only for the specific steps that need root, prompting
>     for your password once and caching it for the rest of the run. Running the whole
>     thing as root/sudo is actively worse: some installers (Claude Code's, for one)
>     explicitly refuse to run under sudo and will fail.
> *   **Windows:** Yes - use an **elevated PowerShell** ("Run as Administrator").
>     Chocolatey (this repo's package manager on Windows) requires admin rights to
>     install anything; without it every package install fails immediately. (The
>     Antigravity CLI - `agy` - is a plain Chocolatey package with no
>     admin-refusal quirk; the Antigravity *desktop* apps are no longer installed
>     by this repo at all.)

> **WSL: enable Docker Desktop's WSL integration *before* running this.**
> This repo never installs a Docker engine/CLI inside WSL - it's designed to
> use Docker Desktop for Windows instead, and that link has to be turned on
> from the Windows side first: open **Docker Desktop → Settings → Resources →
> WSL Integration**, toggle **ON** for this distro, then run the installer.
> The installer checks this **first, before installing anything**, and if
> Docker still isn't reachable it'll ask whether to continue anyway (default
> is no) rather than silently finish an install where Docker doesn't work -
> doing it first just skips that prompt.

**Linux / macOS / WSL / Devcontainer**
```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```
> **Note:** On Host and WSL, the installer will **prompt** you to select components (Core, Modern Tools, Fonts, AI, etc.).  
> On Devcontainers and CI, it runs non-interactively with safe defaults.


**Windows (PowerShell, run as Administrator)**
```powershell
iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

### Private Fork / Mirror Access (Optional)
If you fork or mirror this repository **privately**, the one-liners above need a **Personal Access Token (PAT)** with repo read access.

**Windows (PowerShell) with PAT**
```powershell
$PAT="your_github_pat_here"; iex "& {$(irm -Headers @{Authorization="token $PAT"} https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

**Linux / macOS with PAT**
```sh
export PAT="your_github_pat_here"
sh -c "$(curl -H "Authorization: token $PAT" -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

This script will:
1.  Install `chezmoi` if missing.
2.  Initialize this repository.
3.  Prompt you to select package groups (Core, Modern CLI, Fonts, AI Tools, Desktop).
4.  Install selected packages and apply the configuration.

> **Tip:** On subsequent runs, chezmoi caches your selections — you won't be re-prompted.

## ⚙️ Configuration

After installation, your configuration is stored in **`~/.config/chezmoi/chezmoi.toml`**.
You can edit this file to:
*   Add more Git accounts/identities.
*   Enable/Disable package groups (e.g. `install_ai_tools`).
*   Customize folder mappings.

**First-time setup prompt**
If `~/.config/chezmoi/chezmoi.toml` doesn't exist, `chezmoi init` will prompt for your primary account (non-devcontainer only).  
For non-interactive runs (CI), pre-seed this file or provide it before running `chezmoi apply`.

**Example:**
*   [Config Example](docs/chezmoi.toml.example) - Complete example with accounts, packages, and settings.

To apply changes after editing:
```sh
chezmoi apply
```

## 📦 Platform Defaults

The installer automatically detects your environment and sets the following defaults.
You can override these in `~/.config/chezmoi/chezmoi.toml`.

| Feature | Windows / Mac / Linux (Host) | WSL | Devcontainer |
| :--- | :---: | :---: | :---: |
| **Core Tools** (Git, Zsh, Tmux) | ✅ | ✅ | ✅ |
| **Modern CLI** (Bat, Eza, Fd) | ✅ | ✅ | ✅ |
| **Fonts** (Meslo Nerd Font) | ✅ | ✅ | ✅ |
| **AI Tools** (Codex, etc.) | ✅ | ✅ | ✅ |
| **Desktop Apps** (Chrome, VS Code) | ✅ | ❌ | ❌ |
| **Git Identity** | Prompted | Prompted | Auto (Dev User) |

---

## 🛠️ Components

### Core Configuration
*   **Shell**: Zsh + Oh My Zsh + Starship / Zoxide
*   **Editor**: Neovim (Lazy.nvim)
*   **Terminal**: Tmux (with plugins)
*   **Git**: Stateless identity management (auto-switches emails based on folder). Supports multiple GitHub organizations.
    *   On WSL/devcontainers, Git uses `code --wait` when the VS Code CLI is available.

### Git Identity (devprofile)
`devprofile` manages which Git identity (name/email/signing key) is active, based on your chezmoi `accounts`.

**You usually don't need to run this at all.** Every account's `dirs` list is wired into `~/.gitconfig` as a conditional include, so the right identity is already selected automatically just by which folder a repo lives in - that's the "implicit" use most people actually experience. `devprofile` is for the exceptions: a repo outside any mapped `dirs` path, double-checking the active identity is actually correct, installing a pre-commit safety net, or creating a brand-new account.

**Commands (Linux/macOS/WSL, alias `dp`):**
```sh
devprofile                                      # Show the identity active in the current repo (bare = dp)
devprofile list                                 # List all configured accounts and their SSH keys
devprofile use <username>                       # Override identity for the current repo only (interactive if omitted)
devprofile init <username> <email> --passphrase # Create a new account (auth + signing key)
devprofile verify --install-hook                # Sanity-check the active identity; optionally add a pre-commit safety net
```

**PowerShell** (no `dp` alias defined there yet):
```powershell
devprofile
devprofile list
devprofile use <username>
devprofile init <username> <email> -Passphrase
devprofile verify -InstallHook
```

**Example output** (`account-a`/`account-b`/`account-c` below stand in for whatever accounts are actually in your `chezmoi.toml`):

<details>
<summary><code>devprofile list</code></summary>

```
▸ Configured Accounts (3 total):

  ┌────────────────────┬────────────────────────┬──────────────────────────────┬──────────┐
  │ USERNAME           │ NAME                   │ EMAIL                        │ PROVIDER │
  ├────────────────────┼────────────────────────┼──────────────────────────────┼──────────┤
  │ account-a          │ Account A              │ account-a@example.com        │ github   │
  │ account-b          │ Account B              │ account-b@example.com        │ github   │
  │ account-c          │ Account C              │ account-c@example.com        │ github   │
  └────────────────────┴────────────────────────┴──────────────────────────────┴──────────┘

▸ SSH Keys:

  ┌──────────────────────────┬────────────┬────────────────┐
  │ KEY FILE                 │ TYPE       │ STATUS         │
  ├──────────────────────────┼────────────┼────────────────┤
  │ id_account-a             │ auth       │ ✓ in use       │
  │ id_account-a_sign        │ signing    │ ✓ in use       │
  │ id_account-b             │ auth       │ ✓ in use       │
  │ id_account-b_sign        │ signing    │ ✓ in use       │
  │ id_account-c             │ auth       │ ✓ in use       │
  └──────────────────────────┴────────────┴────────────────┘
```
</details>

<details>
<summary><code>devprofile</code> (bare, inside a repo) / <code>devprofile use account-b</code></summary>

```
✓ Current identity (repo-local):

  ┌──────────┬────────────────────────────────────────────┐
  │ Name     │ Account B                                  │
  ├──────────┼────────────────────────────────────────────┤
  │ Email    │ account-b@example.com                      │
  ├──────────┼────────────────────────────────────────────┤
  │ Key      │ ~/.ssh/id_account-b_sign.pub               │
  └──────────┴────────────────────────────────────────────┘

✓ Email matches a configured account
```

`use` additionally prints a `Signing` row (the dedicated signing key, separate from the auth key shown as `Key`):
```
✓ Configured identity for this repo: account-b

  ┌──────────┬────────────────────────────────────────────┐
  │ Name     │ Account B                                  │
  ├──────────┼────────────────────────────────────────────┤
  │ Email    │ account-b@example.com                      │
  ├──────────┼────────────────────────────────────────────┤
  │ Key      │ ~/.ssh/id_account-b                        │
  ├──────────┼────────────────────────────────────────────┤
  │ Signing  │ ~/.ssh/id_account-b_sign                   │
  └──────────┴────────────────────────────────────────────┘
```
</details>

<details>
<summary><code>devprofile verify</code> - correct identity for this repo</summary>

```
▸ Identity Verification:

  ┌──────────┬──────────────────────────────────────────┬───┐
  │ Identity │ Account B <account-b@example.com>        │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Key      │ ~/.ssh/id_account-b_sign.pub             │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Account  │ Email matches configured account         │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Dir      │ Matches account-b (dirs mapping)         │ ✓ │
  └──────────┴──────────────────────────────────────────┴───┘

✓ All checks passed!
```
</details>

<details>
<summary><code>devprofile verify</code> - wrong identity for this repo</summary>

E.g. <code>devprofile use account-c</code> was run while sitting in a repo whose `dirs` mapping actually belongs to `account-b`:

```
▸ Identity Verification:

  ┌──────────┬──────────────────────────────────────────┬───┐
  │ Identity │ Account C <account-c@example.com>        │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Key      │ ~/.ssh/id_account-c.pub                  │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Account  │ Email matches configured account         │ ✓ │
  ├──────────┼──────────────────────────────────────────┼───┤
  │ Dir      │ Expected account-b (account-b@example... │ ✗ │
  └──────────┴──────────────────────────────────────────┴───┘

! 1 issue(s) found
```
</details>

**Notes:**
*   `devprofile` reads accounts from `chezmoi data --format=json` (no config migration needed).
*   `devprofile verify --install-hook` installs a wrapper and preserves any existing hook as `pre-commit.user`.
*   Passphrases are optional. For new keys, you can force prompts with `DEVPROFILE_PASSPHRASE=1`.
*   Auth vs signing keys: `key` is used for auth; `signingKey` is optional for signing. If `signingKey` is omitted, `key` is used for both.
*   If you use separate auth/sign keys, a passphrase on **both** is recommended. Use `ssh-agent`/OS keychain to avoid repeated prompts.
*   Account `dirs` are created automatically during `chezmoi apply` when identities are generated.
*   `devprofile use <account>` signs with that account's `signingKey` (falling back to `key` only if no `signingKey` is set) - same key `chezmoi apply` wires up globally.
*   `devprofile verify`'s `Dir` row cross-checks the current repo's path against every account's `dirs` list and flags it if the active identity doesn't match - catches a repo-local `devprofile use` run in the wrong repo, or a repo cloned/moved under the wrong account's directory.

**Verifying signatures locally across multiple machines**

`~/.ssh/allowed_signers` (what makes `git log --show-signature` / `git verify-commit` actually work, rather than error with "needs to be configured") is generated **per machine, from what's already local to it** - this repo never commits anyone's public keys, since it's shared across many people's independent setups, not just one person's own machines. Every machine generates its own SSH keys (`devprofile init`), so the same identity has *different* key material on each machine unless you deliberately copy keys between them.

Each `chezmoi apply` merges three things into this file, without ever deleting what's already there:
1. Whatever the file already contains (so a file you copied in from another machine, or hand-edited, survives).
2. Each configured account's dedicated signing key, from `chezmoi.toml` - the most reliable source.
3. Every other `*.pub` under `~/.ssh` not already covered - lets a machine pick up keys for identities it doesn't have configured itself. The email is recovered from the key's own comment (`devprofile init` writes signing keys as `<email>-sign` specifically so this works); a key whose comment isn't a recognizable email is skipped with a warning rather than guessed at.

Practical effect: if you copy SSH keys between your own machines (as opposed to generating fresh ones per machine), everything already lines up with zero extra steps. If you generate fresh keys per machine instead, either let the scan above pick each one up over time, or copy `~/.ssh/allowed_signers` itself from one machine to another - it'll merge into whatever's already there rather than overwrite it.

**Existing keys without passphrases**
No, you do not need to regenerate them. The passphrase option only affects new keys created with `devprofile init`.

If you want to add a passphrase to an existing key:
```sh
# Linux/macOS/WSL
ssh-keygen -p -f ~/.ssh/id_yourkey
```

```powershell
# Windows
ssh-keygen -p -f "$env:USERPROFILE\.ssh\id_yourkey"
```

### Platform Specifics
*   **Windows**: Setup includes Chocolatey packages, PowerShell profiles, and `devprofile` scripts.
*   **Devcontainers**: Automatic detection and configuration of environment.

## 📊 Detailed Installed Programs

This table lists all programs installed by your dotfiles across different environments.
**Legend:**
- ✅ : Installed
- ❌ : Not installed
- ⚠️ : Optional / Depends on config (default shown)
- 📦 : Installed via Package Manager (apt/brew/choco)
- 🔧 : Manual/Script Install
- 🟢 : Node/NPM Global
- 🖥️ : Desktop only (skipped in headless)

| Category | Program | Windows | WSL | Linux (Desktop) | Mac | Devcontainer |
|----------|---------|---------|-----|-----------------|-----|--------------|
| **Core Utilities** | git | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | curl | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | wget | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | jq | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | fzf | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | zsh | ❌ | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | tmux | ✅ 📦 (psmux) | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | neovim | ✅ 📦 | ✅ 🔧 | ✅ 🔧/📦 | ✅ 📦 | ✅ 📦 |
| | ripgrep | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | htop | ❌ | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | tree | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | 7zip | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | bc | ❌ | ✅ 📦 | ✅ 📦 | ❌ | ✅ 📦 |
| | build-essential / gcc | ❌ | ✅ 📦 | ✅ 📦 | ✅ 📦 (gcc) | ✅ 📦 |
| | openssh-client | ✅ 🛡️(System) | ✅ 📦 | ✅ 📦 | ✅ 🛡️(System) | ✅ 📦 |
| | python3 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | nodejs (v24) + npm | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | gsudo | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | powershell-core| ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | ffmpeg | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 |
| | sevenzip | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| **Modern CLI** | bat | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | eza | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | fd | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | git-delta | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | zoxide | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | starship | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 📦 | ❌ |
| | direnv | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| | lazygit | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 📦 | ❌ |
| | gum | ✅ 📦 | ✅ 📦 | ✅ 📦 | ✅ 📦 | ❌ |
| **Fonts** | Meslo Nerd Font | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 📦 | ❌ |
| **AI Tools** | @openai/codex | ✅ 🟢 | ✅ 🟢 | ✅ 🟢 | ✅ 🟢 | ❌ |
| | Antigravity CLI (agy) | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 📦 | ❌ |
| | Claude Code | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | OpenCode | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | Superpowers (Claude Code) | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | Superpowers (OpenCode) | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | Superpowers (Antigravity) | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | Curated skills (Matt Pocock + `frontend-design`) — Claude Code / OpenCode / Antigravity | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | Superpowers (Codex CLI) | ❌ manual only (`/plugins` in-app) | ❌ manual only (`/plugins` in-app) | ❌ manual only (`/plugins` in-app) | ❌ manual only (`/plugins` in-app) | ❌ |
| | Playwright Chromium | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ✅ 🔧 | ❌ |
| | act (local GitHub Actions) | ✅ 📦 | ✅ 🔧 | ✅ 🔧 | ✅ 📦 | ❌ |
| **Desktop Apps** | VS Code | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Google Chrome | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Docker Desktop | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | OBS Studio | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | VLC | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Meld (Diff/Merge) | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Flameshot / ShareX | ✅ 📦 (ShareX) | ❌ | ✅ 📦 (Flameshot) | ✅ 📦 (Flameshot) | ❌ |
| | ScreenRec | ✅ 🔧 | ❌ | ✅ 📦 | ✅ 🔧 | ❌ |
| | PowerToys | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | Rectangle | ❌ | ❌ | ❌ | ✅ 📦 | ❌ |
| | Raycast | ❌ | ❌ | ❌ | ✅ 📦 | ❌ |
| | Handy (Speech-to-Text) | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Termius (SSH/SFTP) | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Geany | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | WizTree | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | qBittorrent | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |
| | Files (App) | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | ChocolateyGUI | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | CPU-Z | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | CrystalDiskInfo| ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | CrystalDiskMark| ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | CutePDF | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | Everything | ✅ 📦 | ❌ | ❌ | ❌ | ❌ |
| | Ghostscript | ✅ 📦 | ❌ | ✅ 📦 | ✅ 📦 | ❌ |

> **Post-Install:** Launch Docker Desktop once from your applications menu (Start menu on Windows) to accept the EULA and start the engine, then confirm it works with `docker ps`.

**Notes:**
1. **Devcontainers**: By default, only "Core" packages are installed. Other categories are disabled unless explicitly enabled in `chezmoi.toml`.
2. **WSL**: Desktop apps are generally skipped in WSL unless manually enabled, even though WSLg supports them.
3. **Antigravity**: Only the CLI (`agy`) is installed, everywhere `install_ai_tools` does (WSL included) - the desktop apps (IDE, hub) were removed from this repo; VS Code + `agy` in a terminal cover that workflow. Its skills (Superpowers plugin, curated `skills`-CLI set) also live under `install_ai_tools`.

## 📂 Repository Structure

*   `install.sh`: Universal bootstrap script.
*   `dot_zshrc` → `~/.zshrc`: Main shell configuration.
*   `dot_gitconfig.tmpl` → `~/.gitconfig`: Global git config (templated).
*   `dot_config/nvim/`: Neovim configuration.
*   `run_onchange_install_packages.sh.tmpl`: Hook to install packages on Linux/Mac.
*   `run_onchange_install_packages.ps1.tmpl`: Hook to install packages on Windows.
*   `private_dot_ssh/`: SSH config (private).

## 📄 Documentation
*   [Zsh, Tmux & Neovim Tutorial](docs/tmux-nvim-tutorial.md) - Leveling up Zsh, or never touched tmux/nvim? Start here.
*   [Tmux Guide](docs/tmux.md)
*   [Neovim Cheat Sheet](docs/nvim.md)
*   [Zsh Tips & Tricks](docs/zsh-tips.md)
*   [Windows Setup](docs/windows.md)
*   [Devcontainer Setup](docs/devcontainer.md)
*   [Backup & Restore](docs/backup-restore.md)
*   [Tool Parity](docs/tool-parity.md)

## ❓ Troubleshooting

### Every package fails to install (Windows)
If you see `Warning: Failed to install <pkg> (choco exit code 1)` repeated for
every package, PowerShell isn't running elevated. Chocolatey requires
Administrator rights. Close the window, reopen PowerShell via **Run as
Administrator**, and re-run `chezmoi apply`.

### "chezmoi.exe failed to run: An Application Control policy has blocked this file" (Windows)
Confirmed live via the Windows Event Log (`Microsoft-Windows-CodeIntegrity/Operational`,
Event IDs 3033/3077/3118): this is **Windows Smart App Control** blocking
`chezmoi.exe` because it's an unsigned binary (Chocolatey doesn't
code-sign it, and neither do most single-maintainer open-source CLI
tools). Nothing in this repo or its installer causes this - it's an OS-level
policy decision, and once it fires it blocks *every* invocation of that
binary, not just `chezmoi update`.
- **Confirm it's this, not something else:** Windows Security → App &
  browser control → Smart App Control. If it shows as On (or "Evaluation"),
  that's almost certainly the cause.
- **Fix:** turn Smart App Control off there, then re-run `chezmoi`. On
  recent Windows 11 builds (24H2/25H2-era) this toggle is reversible without
  reinstalling Windows - the dialog itself will tell you; on older builds it
  was historically one-way. There is no per-app allowlist/exception - it's
  on or off for the whole system, confirmed via Microsoft's own FAQ.
- **Not just chezmoi:** if this fires once, check whether it's also
  silently blocking other things - on the machine this was diagnosed on, it
  had already blocked the same user's own antivirus's AMSI component
  hundreds of times. Worth a look at that same Event Log rather than
  assuming it's chezmoi-only.
- **Platform scope, reasoned but not all live-verified:** this is a
  Windows-specific mechanism (Smart App Control / Windows Defender
  Application Control). **Linux** (the mainstream distros this repo
  targets - Ubuntu/Debian) has no default equivalent - no out-of-the-box
  policy blocks running an arbitrary unsigned binary; confirmed by nothing
  like this ever surfacing across this session's live Linux/WSL testing.
  **macOS** has a conceptual equivalent (Gatekeeper + notarization), but it
  triggers via the `com.apple.quarantine` attribute that browsers/Finder
  set on downloaded files - Homebrew-installed CLI binaries (how this repo
  installs `chezmoi` on macOS) essentially never carry that attribute, so
  in practice this repo's Mac install path is much less likely to hit
  anything like this. This macOS reasoning hasn't been confirmed live
  against a real Gatekeeper block the way the Windows case was reproduced
  and diagnosed from actual Event Log evidence - if it ever does surface on
  macOS, note that Gatekeeper's fix is a one-time per-app override (right-click
  → Open, or System Settings → Privacy & Security → "Open Anyway"), not an
  all-or-nothing system toggle like Smart App Control.

### Claude Code (or another AI tool) didn't install (Linux/macOS)
If the log shows `Error: do not run this installer with sudo` (or a similar
installer refusal), the script was run with `sudo` in front of it. Don't do
that - see "Do you need sudo?" in Quick Start above. Re-run without `sudo` as
your normal user; the script elevates internally only where it actually needs to.

### Docker command not found on WSL
The installer checks for this itself, first thing, before installing
anything else, and will ask whether to continue if `docker` isn't reachable
(default is not to). Installing Docker Desktop on the Windows side also
prints this same reminder, listing whichever WSL distro(s) it can already
see. If you're hitting it manually - "The command 'docker' could not be
found in this WSL 2 distro" - or answering the installer's prompt, the fix
is the same either way:
1.  Open **Docker Desktop** on Windows.
2.  Go to **Settings > Resources > WSL Integration**.
3.  Toggle **ON** for your specific distro (e.g. `Ubuntu`).
4.  Restart your WSL terminal, then (re-)run the installer.

Don't have a WSL distro yet at all? `wsl --install -d Ubuntu` first, then
come back to the steps above.

### Docker Desktop won't start after install (Linux host)
Docker Desktop's VM backend needs `/dev/kvm` access via the **`kvm`** group -
not the `docker` group (Desktop's CLI uses its own per-user socket, so the
classic "add user to docker group" advice doesn't apply here). The installer
adds you to `kvm` automatically if it's missing, but **a new terminal or
`exec $SHELL` won't pick that up** - group membership is only re-read at
login, and Docker Desktop is a GUI app launched from your desktop session,
not from whatever shell ran the installer. Log out and back in (or reboot),
then start Docker Desktop again.

## 🔄 Management (Cheat Sheet)

Apply changes after pulling:
```sh
chezmoi apply
```

Edit a file (e.g., zshrc):
```sh
chezmoi edit ~/.zshrc
chezmoi apply
```

Update from remote:
```sh
chezmoi update
```
