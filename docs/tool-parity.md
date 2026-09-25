# Tool Parity & Installation Matrix

This document outlines the tools installed by the dotfiles configuration across different platforms, ensuring a consistent development environment.

> **Privilege requirements differ by platform, and getting them wrong causes
> real failures - confirmed live this session, not theoretical:**
> - **Linux/macOS/WSL:** Run `install.sh` as a normal user, never with `sudo`
>   in front of it. `run_onchange_install_packages.sh.tmpl` elevates
>   internally (its own `$SUDO` variable, via a single `sudo -v` prompt
>   cached for the run) only for the specific apt/package steps that need
>   root. Running the whole script as root breaks things it shouldn't:
>   Claude Code's official installer explicitly detects and refuses this
>   (`Error: do not run this installer with sudo`), and would previously
>   have taken the entire rest of the install down with it under
>   `set -euo pipefail` before this was hardened - now it warns and
>   continues, but Claude Code still won't be installed.
> - **Windows:** Chocolatey requires an **elevated PowerShell** ("Run as
>   Administrator"). Without it, every `choco install` in
>   `run_onchange_install_packages.ps1.tmpl` fails with exit code 1 -
>   confirmed live, every single package in the list failed the same way in
>   one non-elevated run.

## AI Coding Tools

| Tool | Linux (Mint/Ubuntu) | macOS | Windows (Host) | WSL (Ubuntu) | Devcontainer | Upgrade Method |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Claude Code** | Native (`curl \| sh`) | Native (`curl \| sh`) | Native (`irm \| iex`) | Native (`curl`) | ❌ | Re-run native installer |
| **Antigravity CLI (agy)** | install script (`antigravity.google/cli/install.sh`) | `brew install --cask antigravity-cli` | `choco install antigravity-cli` | install script (`antigravity.google/cli/install.sh`) | ❌ | Re-run the install method for your platform - agy also self-updates on its own (verifies its own checksum each run). Replaces Gemini CLI in this repo: Google retired standalone Gemini Code Assist for individuals in favor of the Antigravity suite |
| **Codex CLI** | `@openai/codex` | `@openai/codex` | `@openai/codex` | `@openai/codex` | ❌ | `dot upgrade` (deferred while a codex session is live) |
| **OpenCode** | Native (`curl \| bash`) | Native (`curl \| bash`) | `choco install opencode` | Native (`curl`) | ❌ | Re-run curl script, or `choco upgrade opencode` on Windows. NOT npm on Windows: opencode-ai's npm package ships a dead exe whenever its postinstall didn't run (confirmed live 2026-08-31 - "not a valid application for this OS platform") |
| **Superpowers (Claude Code)** | `claude plugin install` | `claude plugin install` | `claude plugin install` | `claude plugin install` | ❌ | `claude plugin update superpowers -y` |
| **Superpowers (OpenCode)** | `npm i --prefix ~/.config/opencode` | `npm i --prefix ~/.config/opencode` | `npm i --prefix %USERPROFILE%\.config\opencode` | `npm i --prefix ~/.config/opencode` | ❌ | Re-run the same `npm install` (no version pin, pulls latest commit) |
| **Superpowers (Antigravity)** | `agy plugin install <url>` | `agy plugin install <url>` | `agy plugin install <url>` | `agy plugin install <url>` | ❌ | Re-run `agy plugin install https://github.com/obra/superpowers` (idempotent - installs and updates are the same command). The officially-documented mechanism per obra/superpowers' own README.md, not hand-copying skill files into a guessed plugin directory |
| **Curated skills** (repository catalog) | shared-location fan-out | shared-location fan-out | shared-location fan-out | shared-location fan-out | ❌ | Run `scripts/update_ai_tools.sh` or `scripts/update_ai_tools.ps1`. Curated skills land in `~/.claude/skills`, shared `~/.agents/skills` (OpenCode and Codex), and `~/.gemini/antigravity-cli/skills`; `--copy` creates real directories, not symlinks. |
| **Superpowers (Codex CLI)** | Manual (`/plugins` in-app) | Manual (`/plugins` in-app) | Manual (`/plugins` in-app) | Manual (`/plugins` in-app) | ❌ | Not automated - confirmed via an isolated Docker test that the only scriptable option (`codex-plugin`, a third-party npm helper) expects a `plugins/<name>/` marketplace layout obra/superpowers doesn't use (root-level `.codex-plugin/plugin.json` instead), so it fails outright regardless of flags |
| **Playwright Chromium** | `npx playwright install chromium` | `npx playwright install chromium` | `npx playwright install chromium` | `npx playwright install chromium` | ❌ | `npx playwright install chromium` |
| **act** (local GitHub Actions) | install script | install script | `choco install act-cli` | `brew install act` | ❌ | Re-run the install method for your platform. Note: act runs every job inside Docker, and this repo's isDevcontainer check treats any container as one, so it can validate script/template syntax but can never exercise `core`/`agent_toolkit`/etc content - confirmed this session, had to fall back to isolated `docker run` tests instead |
| **Serena** | `uv tool install -p 3.13 serena-agent` | same | same | same (uv works in WSL) | ❌ | `uv tool upgrade serena-agent`. uv auto-manages Python 3.13 - no system Python needed. Claude checks `claude mcp get serena` before `serena setup claude-code`; Codex uses `serena setup codex`; OpenCode merges its global `mcp` key (graft too); Antigravity gets both via the dotfiles-mcp plugin bundle (eager start). See docs/agent-context-tools.md |
| **Graft** | `npm i -g @nanonets/graft` (with `--allow-scripts` allowlist for its tree-sitter native builds) | same | same | same | ❌ | `graft upgrade`. Per-repo activation is separate and manual: `graft init` (or e.g. `graft init --agents claude agents`) + `graft build` writes the gitignored local `graft/` graph. Telemetry disabled by the installer. See docs/agent-context-tools.md |
| guardrail | opt-in flag: fetch + verify the pinned release's `install.sh`, run it with `--version <pin> --state <enabled\|disabled>` (desired state from `packages.guardrail`) | same | opt-in flag: fetch + verify the pinned release's `install.ps1`, run it with `-Version <pin> -State <enabled\|disabled>` | same as Linux | not installed (no `claude` there) | bump `guardrail.version` in `.chezmoidata.yaml` (single source of truth - templates render it, updaters read it at runtime), re-`chezmoi update` (the new tag's installer updates the binary and re-runs `guardrail setup`) |

> **Note on Updates**: Most AI tools do not have a built-in auto-updater. We recommend running `npm update -g` regularly for the npm-based tools. For native tools like Claude and OpenCode, re-running the installation command usually fetches the latest version.

> **Curated skills:** the installer refreshes the repository catalog and fans it
> out to each native target. It verifies each `SKILL.md` before generating the
> matching OpenCode command in `~/.config/opencode/commands`; `/teach <topic>`
> is one example. Claude Code, Antigravity CLI, and OpenCode use `/teach
> <topic>`; Codex uses `/skills`, then `$teach <topic>`.
> Only OpenCode receives generated command adapters. Codex has no generated command files. Generated
> command files are marker-owned, so refresh may
> update them safely but preserves a user-owned command conflict with a warning.
> Use `dot upgrade` (the full sweep: packages + AI tools, live-session
> gated) or `bash "$(chezmoi source-path)/scripts/update_ai_tools.sh"` on
> Linux/macOS/WSL or `& (Join-Path (chezmoi source-path)
> 'scripts\update_ai_tools.ps1')` on Windows for AI-tools-only updates, then restart
> OpenCode and start a new Claude Code, Antigravity CLI, or Codex CLI session
> before using a refreshed skill. OpenCode and Codex discover the catalog-managed shared
> `~/.agents/skills` directory; other existing content there is not deleted.
> Superpowers is unchanged
> (still `claude plugin install` / npm / `agy plugin install <url>` per its own
> rows).

> **Note on Antigravity**: the old desktop surfaces (IDE + hub app) were
> removed from this repo on 2026-09-11 (VS Code + `agy` in a terminal cover
> that workflow); the 2.0 hub app came back on 2026-09-13 as its own
> `antigravity_desktop` group. `agy`, its Superpowers plugin, and the
> curated skills set all live under `antigravity_cli`.

> **guardrail** is gated by the `guardrail` group (prompted, default true;
> non-interactive default false). The dotfiles download the pinned
> `CtrlCarlitos/agent-guardrails` release's `install.sh` / `install.ps1`, verify
> it against that release's `SHA256SUMS`, and run it with the pin and the desired
> state. The installer does the rest: it downloads and verifies the binary,
> installs it to `~/.local/bin/guardrail` (`%USERPROFILE%\.local\bin\guardrail.exe`),
> and runs `guardrail setup`, which registers every detected agent host with one
> passkey approval. Independent of `agent_toolkit` — the installer call sites
> are hoisted out of that gate. See docs/guardrail-install.md.
> The Linux/WSL shfmt release binary is also checksum-verified before installation.

## Core & Modern CLI Tools

The package table below is **generated** from the catalog
(`.chezmoidata/packages.yaml`) by [scripts/gen-tool-parity.sh](../scripts/gen-tool-parity.sh)
- one row per tool, with each manager's name for it (#105). `procedure` means
the tool installs on that platform through a procedure (a repo + signing key,
a `.deb`/`.dmg`/binary download) instead of a plain package-manager install,
as the tool's `note` documents; `—` means the catalog names no package for
that manager. `tests/docs_contracts.sh` fails when this section drifts from
the catalog, so edit the catalog and rerun the script - never this table.

<!-- tool-parity:packages-begin (generated by scripts/gen-tool-parity.sh from .chezmoidata/packages.yaml - do not edit by hand; rerun the script) -->
| Tool | Group | apt (Linux/WSL) | brew | cask (macOS) | choco (Windows) | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `git` | core | `git` | `git` | — | `git.install` |  |
| `curl` | core | `curl` | `curl` | — | `curl` |  |
| `wget` | core | `wget` | `wget` | — | `wget` |  |
| `jq` | core | `jq` | `jq` | — | `jq` |  |
| `fzf` | core | `fzf` | `fzf` | — | `fzf` |  |
| `zsh` | core | `zsh` | `zsh` | — | — |  |
| `tmux` | core | `tmux` | `tmux` | — | — |  |
| `neovim` | core | procedure | `neovim` | — | `neovim` | apt: installed by a procedure with a fallback (the release's neovim may be too old) |
| `ripgrep` | core | `ripgrep` | `ripgrep` | — | `ripgrep` |  |
| `htop` | core | `htop` | `htop` | — | — |  |
| `gh` | core | procedure | `gh` | — | `gh` | apt: installed from GitHub's own repo by a procedure |
| `tree` | core | `tree` | `tree` | — | `tree` |  |
| `7zip` | core | `p7zip-full` | `sevenzip` | — | `7zip.install` |  |
| `cmake` | core | `cmake` | `cmake` | — | `cmake` |  |
| `ffmpeg` | core | `ffmpeg` | `ffmpeg` | — | `ffmpeg` |  |
| `python` | core | `python3` | `python3` | — | `python` |  |
| `python-venv` | core | `python3-venv` | — | — | — |  |
| `node` | core | procedure | `node@24` | — | procedure | apt: NodeSource setup script by procedure; choco: Install-Node pins 24.x by procedure |
| `coreutils` | core | — | `coreutils` | — | — | GNU coreutils on macOS (gtimeout for net_timeout) |
| `build-tools` | core | `build-essential` | `gcc` | — | — | Windows: the VS C++ Build Tools are installed by the graft step via winget |
| `bc` | core | `bc` | — | — | — |  |
| `openssh-client` | core | `openssh-client` | — | — | — |  |
| `ca-certificates` | core | `ca-certificates` | — | — | — |  |
| `zstd` | core | `zstd` | — | — | — |  |
| `socat` | core | `socat` | — | — | — | ssh-agent-relay bridges the Windows agent into WSL through socat |
| `ssh-agent-filter` | core | `ssh-agent-filter` | — | — | — | ssh-agent-relay's per-account key filtering |
| `gsudo` | core | — | — | — | `gsudo` |  |
| `powershell-core` | core | — | — | — | `powershell-core` |  |
| `psmux` | core | — | — | — | `psmux` | The native Windows tmux (Rust, github.com/psmux/psmux) - official Chocolatey package, ships psmux/pmux/tmux commands. A binary install only: the dotfiles stay tmux-free on Windows (.tmux.conf and .tmux/ are ignored there), so no tmux config is managed for it. Listed right after powershell-core deliberately: psmux recommends PS 7+, and the install order follows this list. |
| `wsl2` | core | — | — | — | `wsl2` |  |
| `npiperelay` | core | — | — | — | `npiperelay` | Bridges the Windows ssh-agent named pipe into WSL, so a WSL distro (and any devcontainer launched from it) uses the Windows agent and holds no private keys of its own. See docs/ssh-agents.md. |
| `bat` | modern_cli | `bat` | `bat` | — | `bat` | apt: binary installs as batcat, aliased to bat; shares its apt install line with fd - a multi-package apt install fails wholesale if one name is unavailable on a release |
| `eza` | modern_cli | procedure | `eza` | — | `eza` | apt: from the gierens repo with its signing key, by procedure |
| `fd` | modern_cli | `fd-find` | `fd` | — | `fd` | apt: package is fd-find, binary installs as fdfind (aliased to fd) - same naming conflict as batcat |
| `delta` | modern_cli | procedure | `git-delta` | — | `delta` | apt: GitHub release .deb by procedure |
| `starship` | modern_cli | procedure | `starship` | — | `starship` | apt: upstream install script by procedure |
| `zoxide` | modern_cli | procedure | `zoxide` | — | `zoxide` | apt: package where the release has it, upstream script as fallback - by procedure |
| `direnv` | modern_cli | `direnv` | `direnv` | — | `direnv` | hooked from .zshrc (direnv hook zsh); .envrc files are allowed per project, never by the installer |
| `lazygit` | modern_cli | procedure | `lazygit` | — | `lazygit` | apt: GitHub release tarball by procedure |
| `gum` | modern_cli | procedure | `gum` | — | — | apt: Charm's repo by procedure; choco: not published there - Install-Gum fetches the GitHub release |
| `tealdeer` | modern_cli | procedure | `tealdeer` | — | `tealdeer` | apt: official static binary by procedure (not in the archive before Ubuntu 23.04/lunar) |
| `dust` | modern_cli | procedure | `dust` | — | `dust` | apt: GitHub release .deb by procedure |
| `duf` | modern_cli | `duf` | `duf` | — | `duf` | aliased over df when present |
| `procs` | modern_cli | procedure | `procs` | — | `procs` | apt: GitHub release by procedure |
| `shellcheck` | modern_cli | `shellcheck` | `shellcheck` | — | `shellcheck` | CI and .pre-commit-config.yaml lint shell with it - a fresh machine needs it locally, not only in CI |
| `shfmt` | modern_cli | procedure | `shfmt` | — | `shfmt` | apt: official release binary by procedure, checksum-verified on x86_64/amd64 and aarch64/arm64 |
| `pstop` | modern_cli | — | — | — | `pstop` |  |
| `meslo-nerd-font` | fonts | procedure | — | `font-meslo-lg-nerd-font` | `nerd-fonts-meslo` | apt: downloaded from the Nerd Fonts release by procedure |
| `powertoys` | dev_desktop | — | — | — | `powertoys` |  |
| `files` | dev_desktop | — | — | — | `files` |  |
| `chocolateygui` | dev_desktop | — | — | — | `chocolateygui` |  |
| `cpu-z` | dev_desktop | — | — | — | `cpu-z.install` |  |
| `crystaldiskinfo` | dev_desktop | — | — | — | `crystaldiskinfo.install` |  |
| `crystaldiskmark` | dev_desktop | — | — | — | `crystaldiskmark` |  |
| `cutepdf` | dev_desktop | — | — | — | `cutepdf` |  |
| `everything` | dev_desktop | — | — | — | `Everything` |  |
| `ghostscript` | dev_desktop | `ghostscript` | — | `ghostscript` | `Ghostscript.app` |  |
| `docker-desktop` | dev_desktop | procedure | — | `docker` | `docker-desktop` | apt: official .deb download by procedure |
| `vscode` | dev_desktop | procedure | — | `visual-studio-code` | `vscode.install` | apt: Microsoft's repo by procedure |
| `geany` | dev_desktop | `geany` | — | `geany` | `geany` | Replaces Notepad++ (Windows-only): free, open source, and the same "lightweight quick-edit GUI editor" role on all three platforms. |
| `obs-studio` | dev_desktop | `obs-studio` | — | `obs` | `obs-studio.install` |  |
| `qbittorrent` | dev_desktop | `qbittorrent` | — | `qbittorrent` | `qbittorrent` |  |
| `sharex` | dev_desktop | — | — | — | `sharex` |  |
| `meld` | dev_desktop | `meld` | — | `meld` | `meld` | Replaces WinMerge (Windows-only): Meld is already the Linux/macOS diff/merge tool here and is on Chocolatey too, so one tool everywhere. |
| `wiztree` | dev_desktop | — | — | — | `wiztree` |  |
| `termius` | dev_desktop | procedure | — | `termius` | `termius` | Replaces FileZilla: one SSH/SFTP client on all three platforms. FileZilla's Homebrew cask was pulled outright (adware concerns). apt: vendor .deb download by procedure. |
| `vlc` | dev_desktop | `vlc` | — | `vlc` | `vlc` |  |
| `handy` | dev_desktop | procedure | — | `handy` | `handy` | Speech-to-text (handy.computer). Whisper/Parakeet model choice is GUI-only, nothing to pre-seed: for Spanish + English pick a Whisper model after install (Parakeet is English-only) - Large for accuracy, Turbo for speed. apt: GitHub release .deb by procedure. |
| `google-chrome` | dev_desktop | procedure | — | `google-chrome` | — | apt: Google's .deb download by procedure; Windows: Google's own installer by procedure (never choco - see the GoogleChrome note in the .ps1) |
| `ghostty` | dev_desktop | procedure | — | `ghostty` | — | apt: universe on Ubuntu 26.04+, warns elsewhere - by procedure. Windows: Windows Terminal instead |
| `flameshot` | dev_desktop | `flameshot` | — | `flameshot` | — |  |
| `rectangle` | dev_desktop | — | — | `rectangle` | — |  |
| `raycast` | dev_desktop | — | — | `raycast` | — |  |
| `codexbar` | dev_desktop | — | — | `codexbar` | — | Windows: Win-CodexBar via winget by procedure |
| `screenrec` | dev_desktop | procedure | — | procedure | procedure | Screen capture recorder; no package-manager name on any platform by design. apt: vendor repo + signing key, then apt install, by procedure - the .deb hard-depends on the removed libgdk-pixbuf2.0-0 on Ubuntu 24.04+, so the source is rolled back on failure. cask: none - the vendor .dmg by procedure. choco: none - the vendor .exe by procedure. |
| `tailscale` | remote_access | procedure | — | `tailscale-app` | `tailscale` | apt: Tailscale's repo by procedure. migrate-to-choco requires typing the name to confirm this one. |
| `cloudflared` | remote_access | procedure | `cloudflared` | — | `cloudflared` | apt: Cloudflare's repo by procedure |
| `act` | agent_toolkit | procedure | procedure | — | `act-cli` | brew/apt: installed by procedure in the agent_toolkit block |
| `antigravity-cli` | antigravity_cli | — | — | — | `antigravity-cli` |  |
| `claude-desktop` | claude_desktop | — | — | — | `claude` |  |
| `antigravity-desktop` | antigravity_desktop | — | — | — | `antigravity` |  |
| `opencode-desktop` | opencode_desktop | — | — | — | `opencode-desktop` |  |
<!-- tool-parity:packages-end -->

A few rows the catalog deliberately does not carry, kept by hand:

| Tool | Linux (Mint/Ubuntu) | macOS | Windows (Host) | WSL (Ubuntu) | Devcontainer | Parity Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Shell** | `zsh` | `zsh` | `pwsh` (PowerShell 7) | `zsh` (Default) | `zsh` | ✅ Consistent Shell Experience |
| **Tab completion** | `fzf-tab` (zsh plugin) | `fzf-tab` (zsh plugin) | ❌ (PowerShell, no zsh) | `fzf-tab` (zsh plugin) | ❌ | Not gated by a package toggle - installed the same way as the other OMZ custom plugins (`.chezmoiexternal.toml`), zsh platforms only |

## Desktop Applications

| App | Linux (Host) | macOS | Windows (Host) | WSL | Devcontainer | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Editor** | VS Code | VS Code | VS Code | `code` (Remote) | ❌ | WSL uses `code` CLI to open Host VS Code |
| **Terminal** | Ghostty (`apt install ghostty` where the release has it - Ubuntu 26.04+; otherwise warns) | Ghostty (`brew install --cask ghostty`) | Windows Terminal (ships with Windows 11; config only) | runs in Windows Terminal | ❌ | `dev_desktop` group. Same look, keys and clipboard on all 3 (see [Terminal Experience](terminal.md)). Installing Ghostty doesn't make it the default terminal. |
| **Browser** | Chrome | Chrome | Chrome | ❌ | ❌ | Browsers run on Host |
| **Container** | Docker Desktop | Docker Desktop | Docker Desktop | Docker (CLI) | ❌ | WSL connects to Docker Desktop Engine - requires WSL Integration enabled on the Windows side first. The WSL installer checks this before installing anything else and prompts whether to continue if it's off (default no); the Windows installer also reminds about it, listing detected distros. Linux host: installer adds the user to the **`kvm`** group (Desktop's VM backend), not `docker` - requires a logout/login to take effect |
| **AI Chat (Claude)** | ❌ (no official build - installer info-skips) | `brew install --cask claude` | `choco install claude` | ❌ | ❌ | `claude_desktop` group, host only. Claude *Code* (the CLI) is a separate `claude_cli` group - different software, different gate |
| **AI Chat (ChatGPT)** | ❌ (no official build - installer info-skips) | `brew install --cask chatgpt` | `winget install --id 9PLM9XGG6VKS --source msstore` | ❌ | ❌ | `chatgpt_desktop` group, host only. Windows installs ChatGPT Work/Codex. The Codex CLI is separate (`chatgpt_cli`) |
| **AI Usage Monitor (CodexBar)** | manual Linux opt-in | `brew install --cask codexbar` | `winget install --id Finesssee.Win-CodexBar --exact --source winget` | ❌ | ❌ | `dev_desktop` group. macOS uses upstream CodexBar; Windows uses native Win-CodexBar. Linux needs matched upstream desktop/CLI archives plus Qt/glibc dependencies, so remains manual. |
| **AI IDE (Antigravity 2.0)** | tar.gz (pinned hub-channel URL) | dmg (pinned hub-channel URL) | `choco install antigravity` | ❌ | ❌ | `antigravity_desktop` group, host only - distinct from the `agy` CLI (`antigravity_cli`). Pins live in `run_onchange_install_packages.sh.tmpl`; `scripts/update-versions.sh` re-checks them (Windows floats via choco) |
| **AI IDE (OpenCode Desktop)** | `.deb` (GitHub release, amd64) | `brew install --cask opencode-desktop` | `choco install opencode-desktop` | ❌ | ❌ | `opencode_desktop` group, host only - distinct from the OpenCode CLI (`opencode_cli`). Linux curls the latest `opencode-desktop-linux-amd64.deb` from the anomalyco/opencode releases (idempotence guard on the installed package/binary); all three platforms float on their package channel - no pin |
| **ScreenRec** | `.deb` / Apt | `.dmg` | `.exe` | ❌ | ❌ | Host Only. The old Antigravity IDE row that used to sit here went with the IDE itself (2026-09-11); the 2.0 hub app has its own row above |
| **Screenshot** | Flameshot | Flameshot | ShareX | ❌ | ❌ | Platform equivalents |
| **Diff/Merge** | Meld | Meld | Meld | ❌ | ❌ | Standardized on one tool across all 3 platforms; WinMerge (Windows-only) dropped in favor of Meld, confirmed on Chocolatey |
| **SFTP Client** | Termius | Termius | Termius | ❌ | ❌ | Standardized on one tool across all 3 platforms; replaced FileZilla after its Homebrew cask was pulled entirely on macOS (adware concerns) |
| **Media** | VLC | VLC | VLC | ❌ | ❌ | |
| **Streaming** | OBS Studio | OBS Studio | OBS Studio | ❌ | ❌ | |
| **Torrent** | qBittorrent | qBittorrent | qBittorrent | ❌ | ❌ | |
| **PDF** | Ghostscript | Ghostscript | Ghostscript | ❌ | ❌ | |
| **Speech-to-Text** | Handy | Handy | Handy | ❌ | ❌ | [handy.computer](https://handy.computer) - offline Whisper/Parakeet dictation. Model choice (best for Spanish+English: Whisper Large or Turbo) is GUI-only, no scriptable pre-selection |

## Remote Access

| Tool | Linux (Host) | macOS | Windows (Host) | WSL | Devcontainer | Notes |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Mesh VPN** | Tailscale | Tailscale (`tailscale-app` cask, GUI) | Tailscale | *(via Host)* | ❌ | `remote_access` group. **Never installed inside WSL**: WSL uses the Windows host's tailnet connection. Login is manual; no authkey is stored in this shared template. |
| **Application Tunnel** | cloudflared | cloudflared | cloudflared | cloudflared | ❌ | `remote_access` group. Tunnel login and service activation are manual. |
| **SSH Server Prerequisite** | `openssh-server` | Remote Login built in | Windows OpenSSH Server capability | `openssh-server` | ❌ | `remote_access_server` installs prerequisites only. It deliberately does not create a reachable SSH service: activation, firewall, keys, and access configuration remain manual. |

> **Post-Install:** Launch Docker Desktop once from your applications menu (Start menu on Windows) to accept the EULA and start the engine, then confirm it works with `docker ps`. On a Linux host the installer also adds you to the `kvm` group for Desktop's VM backend — that needs a logout/login.

## Network-step timeouts

Every unbounded network fetch in the install scripts (large `.deb`/`.dmg`/
`.msi`/tarball downloads, `curl | sh` installers, `npx` (Playwright, the
`skills` CLI), git clones) is wrapped in a wall-clock guard so one stalled
transfer can't freeze an otherwise-unattended 20-minute run - confirmed
live: Ollama's ~1.5 GB bundle stalled mid-download for 15+ min with nothing
able to proceed until it was killed by hand.

| Script | Mechanism |
| :--- | :--- |
| `run_onchange_install_packages.sh.tmpl`, `install.sh` | `net_timeout <secs> <cmd>` / `_net` helper - wraps coreutils `timeout` (always on Linux) or `gtimeout` (macOS: `coreutils` is first in the brew core list, so it's present before the download-heavy steps; resolved per-call so a mid-run install is picked up). Runs unguarded if neither exists (e.g. Homebrew's own bootstrap, which runs first). Small key/API fetches use `curl --max-time` instead. |
| `run_onchange_install_packages.ps1.tmpl`, `install.ps1` | `Invoke-WithTimeout -Seconds <n> { … }` (job + `Wait-Job -Timeout`) for `irm \| iex` installers, `npx`, and **every `choco install`** (600s cap, live-streamed output, env-var handoff - one bad installer with no cap and `\| Out-Null` once sat invisible for 22 minutes and ate a whole CI job); `-TimeoutSec` on `Invoke-WebRequest`/`Invoke-RestMethod`; `Start-Process -PassThru` + `.WaitForExit(ms)` for silent installers; `--fetch-timeout`/`--fetch-retries` on `npm install -g`. |

On timeout the step is killed and the run continues (`\|\| warn` / a warning
line) - the tool is just left uninstalled or half-installed and can be
re-run by hand. Ollama additionally `rm`s its binary on failure so a
partial extract isn't mistaken for a finished install on the next pass.
`apt` / `brew` are left alone - they carry their own network
timeouts.

## SSH agent & key loading

Every declared account's **auth key and signing key** (`id_<account>` +
`id_<account>_sign`) is loaded into the SSH agent - loading only the auth key
and missing the signing key is the classic mistake, so the verification is
`ssh-add -l` must show the `*_sign` keys too. Scope is the accounts declared
in `chezmoi.toml`, not a blind glob of `~/.ssh`; keys a user loads themselves
are never touched, and are never flushed.

| | Linux / WSL | macOS | Windows |
| :--- | :--- | :--- | :--- |
| **`~/.ssh/config`** | `AddKeysToAgent yes` | `AddKeysToAgent yes` + `UseKeychain yes` | `AddKeysToAgent yes` |
| **Agent** | OMZ `ssh-agent` plugin (per-user process) | same | `ssh-agent` **service** (`Automatic` + `Running`), set by the identity generator |
| **Key list** | `run_onchange_generate_identities.sh.tmpl` writes `~/.ssh/agent-identities.zsh` (a `zstyle :omz:plugins:ssh-agent identities …` line); `~/.zshrc` sources it *before* oh-my-zsh, the plugin does the `ssh-add` | same as Linux, plus `zstyle … ssh-add-args --apple-use-keychain` | `run_onchange_generate_identities.ps1.tmpl` `ssh-add`s them directly + writes `~/.ssh/agent-identities.ps1`; both PowerShell profiles do an idempotent startup top-up |
| **Passphrase persistence** | agent lifetime only (re-enter on logout) | login keychain (survives reboot) | service persists keys DPAPI-encrypted in `HKCU\…\OpenSSH\Agent\Keys`, reloads on boot |
| **Removing a key** | `ssh-add -d` / ends with the agent | `ssh-add -d` + remove from keychain | `ssh-add -d` **required** - see [testing.md](testing.md), de-declaring the account does not evict it |

`commit.gpgsign` is unaffected by any of this - signing key *selection* is
per-account gitconfig, and whether a commit is signed is the existing
`commit.gpgsign` / explicit `-S`, not agent contents.

## Windows vs. WSL Separation

**Windows (Host)**:
- Handles GUI applications (VS Code, Chrome).
- Manages hardware-proximal tools (Docker Desktop backend).
- Uses **Chocolatey** and **PowerShell** for package management - requires an
  elevated PowerShell (see "Privilege requirements" above); Chocolatey
  install failures with no elevation are silent-per-package, not a single
  loud error, which is why they're easy to miss until checking real state.

**WSL (Ubuntu)**:
- Acts as the primary development environment.
- Shares the Linux toolset (apt, native binaries).
- Inherits `zsh`, `starship`, and CLI tools from the Linux configuration.
- **Does not** install GUI apps by default (relies on Host).

## Devcontainers

- **Every** package category defaults to `false` in a devcontainer, Core
  included - see [devcontainer.md](devcontainer.md) for the full explanation.
  `run_onchange_install_packages.*` effectively does not run there by default.
- AI tools (Claude, Codex, etc.) should be installed via [devcontainer features](../docs/devcontainer.md) instead.
- Fonts must be installed on the **host machine** — VS Code uses host fonts.
