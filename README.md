# Dotfiles (Chezmoi Managed)

[![CI](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/ci.yml)
[![Full Install](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/full-install-test.yml/badge.svg?event=workflow_dispatch)](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/full-install-test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

One command. A menu. Your entire dev environment is set up.

Cross-platform dotfiles for **Linux, macOS, Windows, WSL, and Devcontainers** — shell, editor, git identities, modern CLI tools, AI coding agents, and the wiring between them all.

<!-- TODO: demo GIF goes here when VHS works on a real machine:
![Menu demo](assets/demo-menu.gif)
-->

## 🚀 Install

**Linux / macOS / WSL / Devcontainer:**
```sh
sh -c "$(curl -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

**Windows (PowerShell, as Administrator):**
```powershell
iex "& {$(irm https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```

That's it. You'll be asked to confirm, then a **menu appears** — pick what you want and press Enter. Packages install, dotfiles apply, and you have a working environment.

> 📺 **What the menu looks like:** [docs/menu-demo.md](docs/menu-demo.md)

### Don't know what to pick?

Use the **standard** preset (the default). You get a full terminal setup — git, zsh, neovim, tmux, modern CLI tools, Nerd Fonts, Claude Code, OpenCode, and agent guardrails. Add ChatGPT, Antigravity, or desktop apps later by re-running the menu.

### Change your selections later

**Linux/macOS/WSL**

```sh
bash "$(chezmoi source-path)/scripts/select-packages.sh"
chezmoi apply
```

**Windows PowerShell**

```powershell
& (Join-Path (chezmoi source-path) 'scripts\select-packages.ps1')
chezmoi apply
```

### Agent skills

The curated skill catalog uses the `skills` CLI's supported destinations:

- Claude Code: `~/.claude/skills`
- OpenCode and Codex discover the shared `~/.agents/skills` catalog. Only
  OpenCode receives generated command adapters in
  `~/.config/opencode/commands`.
- Antigravity CLI: `~/.gemini/antigravity-cli/skills`

Claude Code, Antigravity CLI, and OpenCode use `/teach <topic>`. Codex CLI:
open `/skills`, then enter `$teach <topic>`.
Only OpenCode receives generated command adapters. Codex has no generated command files.

Refresh curated skills explicitly after installation or whenever you want the
latest catalog - `dot upgrade` runs the full sweep (packages + AI tools,
session-gated); the underlying AI-tools section for a skills-only refresh:

```sh
bash "$(chezmoi source-path)/scripts/update_ai_tools.sh"
```

```powershell
& (Join-Path (chezmoi source-path) 'scripts\update_ai_tools.ps1')
```

After installing or refreshing, restart OpenCode so it reloads updated skills
and generated commands. Start a new Claude Code, Antigravity CLI, or Codex CLI
session before using a refreshed skill. The updater refreshes the
catalog-managed skill directories in `~/.agents/skills`; it does not remove
other user-managed content there.

### Prerequisites & platform notes

<details>
<summary><strong>Do I need sudo / an elevated prompt?</strong></summary>

- **Linux/macOS/WSL:** No. Run as your normal user without `sudo`. The script elevates internally only where needed. Running as root breaks some installers (Claude Code's, for one).
- **Windows:** Yes — elevated PowerShell. Chocolatey requires admin rights.
</details>

<details>
<summary><strong>WSL: enable Docker Desktop integration first</strong></summary>

Open Docker Desktop → Settings → Resources → WSL Integration, toggle ON for your distro, then run the installer. The installer checks this first and asks before proceeding without it.
</details>

<details>
<summary><strong>Private fork / mirror? You'll need a PAT.</strong></summary>

If you fork this repository privately, the one-liners need a Personal Access Token with repo read access:

**Linux / macOS with PAT:**
```sh
export PAT="your_github_pat_here"
sh -c "$(curl -H "Authorization: token $PAT" -fsLS https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.sh)"
```

**Windows with PAT:**
```powershell
$PAT="your_github_pat_here"; iex "& {$(irm -Headers @{Authorization="token $PAT"} https://raw.githubusercontent.com/CtrlCarlitos/dotfiles/main/install.ps1)}"
```
</details>

<details>
<summary><strong>What does the installer actually do?</strong></summary>

1. Installs `chezmoi` if missing
2. Asks for consent, then shows the package-group menu (preset → 16 groups)
3. Installs your selected packages and applies the configuration
4. Generates git identities, SSH keys, shell profiles, and AI tool wiring

Your selections persist in `~/.config/chezmoi/chezmoi.toml` — re-runs show the menu pre-checked (one Enter accepts).
</details>

---

## 📦 What gets installed

16 package groups across 5 platforms. Here's the summary — the full per-program table is in [docs/tool-parity.md](docs/tool-parity.md):

| Group | What's in it | Linux | macOS | Windows | WSL | Devcontainer* |
|-------|-------------|:-----:|:-----:|:-------:|:---:|:--------------:|
| **core** | git, zsh, tmux, node 24, neovim, ripgrep... | ✅ | ✅ | ✅ | ✅ | `runtime_core` |
| **modern_cli** | bat, eza, fd, starship, delta, lazygit... | ✅ | ✅ | ✅ | ✅ | `modern-cli` |
| **fonts** | Nerd Fonts (for Starship icons) | ✅ | ✅ | ✅ | ✅ | `nerd-font` |
| **agent_toolkit** | Serena, Graft, curated skills, act, Playwright | ✅ | ✅ | ✅ | ✅ | `serena` `graft` `curated-skills` `playwright` |
| **opencode_cli** | OpenCode CLI + Superpowers + skills + guardrail | ✅ | ✅ | ✅ | ✅ | `opencode` |
| **opencode_desktop** | OpenCode Desktop app | ✅ | ✅ | ✅ | ❌ | ❌ |
| **claude_cli** | Claude Code + Superpowers + skills + guardrail | ✅ | ✅ | ✅ | ✅ | `claude-code` |
| **claude_desktop** | Claude Desktop app | ❌ | ✅ | ✅ | ❌ | ❌ |
| **chatgpt_cli** | Codex CLI | ✅ | ✅ | ✅ | ✅ | `codex` |
| **chatgpt_desktop** | ChatGPT Desktop app | ❌ | ✅ | ✅ | ❌ | ❌ |
| **antigravity_cli** | Antigravity CLI (agy) + Superpowers + skills | ✅ | ✅ | ✅ | ✅ | `antigravity-cli` |
| **antigravity_desktop** | Antigravity 2.0 app | ✅ | ✅ | ✅ | ❌ | ❌ |
| **dev_desktop** | Chrome, VS Code, Ghostty (Mac/Linux), Docker Desktop, CodexBar, ScreenRec... | ✅ | ✅ | ✅ | ❌ | ❌ |
| **remote_access** | Tailscale and cloudflared tools only; no sign-in or tunnel setup. See [remote access](docs/remote-access.md). | ✅ | ✅ | ✅ | cloudflared only | ❌ |
| **remote_access_server** | OpenSSH-server prerequisites only; server setup is deliberately manual. See [remote access](docs/remote-access.md). | ✅ | ✅ | ✅ | ✅ | ❌ |
| **guardrail** | Agent guardrails (hook enforcement) | ✅ | ✅ | ✅ | ✅ | `guardrail` |

> \* **In devcontainers**, these tools install via [devcontainer-features](https://github.com/CtrlCarlitos/devcontainer-features) instead of the dotfiles installer — add individual features to your `devcontainer.json`. The dotfiles installer renders all groups false non-interactively in containers (they're ephemeral; a full install on every rebuild wastes time). Desktop groups (❌) stay off — no GUI in containers.

> 🔎 Full details: **[Package Groups](docs/package-groups.md)** — taxonomy, placement rules, presets, and how to customize.

---

## ⚙️ Configuration

After installation, everything lives in `~/.config/chezmoi/chezmoi.toml`:

- **Change package groups** — re-run the menu (`select-packages.sh`) or edit the file directly
- **Add git accounts** — each gets its own SSH keys, signing key, and auto-selected identity based on which folder you're in
- **Example config** — [docs/chezmoi.toml.example](docs/chezmoi.toml.example)

Apply changes:
```sh
chezmoi apply
```

---

## 🗂️ Git Identity Management

If you work across multiple GitHub accounts (personal, work, clients), this repo handles it automatically: **each account's identity is selected based on which folder you're in** — no manual switching.

<details>
<summary><strong>Show me how it works</strong></summary>

Every account in your `chezmoi.toml` gets:
- Its own SSH auth key + signing key
- A conditional include in `~/.gitconfig` — the right name/email/signing key activates automatically when you `cd` into a repo under that account's `dirs`
- A `Host <provider>-<username>` SSH alias for push/pull

The `devprofile` CLI handles the exceptions (repos outside any mapped path, verifying the active identity, creating new accounts):

```sh
devprofile                                  # Which identity is active in this repo?
devprofile list                             # All configured accounts and their keys
devprofile use <username>                   # Override identity for this repo only
devprofile init <name> <email> --passphrase # New account with fresh keys
devprofile verify --install-hook            # Sanity check + pre-commit safety net
```

Full documentation: [docs/devprofile.md](docs/devprofile.md) — cross-platform.
</details>

---

## 📚 Learn Your Tools

New to zsh, tmux, or neovim? Start here:

- **[Zsh, Tmux & Neovim Tutorial](docs/tmux-nvim-tutorial.md)** — never touched them? This is your on-ramp.
- **[Tmux Guide](docs/tmux.md)** — sessions, panes, and the plugin setup this repo ships
- **[Neovim Cheat Sheet](docs/nvim.md)** — the keybindings and plugins configured for you
- **[Zsh Tips & Tricks](docs/zsh-tips.md)** — aliases, plugins, and workflow shortcuts
- **[Terminal Experience](docs/terminal.md)** — one look and one set of keys across Windows Terminal, the VS Code terminal, WSL, and SSH hosts

## 📖 Reference

| Doc | What's in it |
|-----|-------------|
| [Invariants](docs/invariants.md) | Rules this repo learned the expensive way — read before changing templates, ignores or tests |
| [Package Groups](docs/package-groups.md) | The 16-group taxonomy, presets, and how to customize |
| [Tool Parity](docs/tool-parity.md) | Full per-program table across all 5 platforms |
| [devprofile](docs/devprofile.md) | Git identity management — multi-account, SSH keys, signing |
| [Git](docs/git.md) | Line endings, gitconfig defaults, delta, and aliases |
| [Terminal Experience](docs/terminal.md) | Windows Terminal, VS Code terminal, OpenCode theme, agent keys, clipboard, SSH hosts |
| [Agent Context Tools](docs/agent-context-tools.md) | Serena + Graft — what they do and how to use them |
| [Menu Demo](docs/menu-demo.md) | What the selection menu looks like |
| [Config Example](docs/chezmoi.toml.example) | Complete chezmoi.toml with all options |
| [VS Code](docs/vscode.md) | Managed extensions, settings tiers, and per-machine overrides |
| [Secrets & SSH Hosts](docs/secrets.md) | Machine-local config, SSH aliases, and safe handling |
| [SSH Agents](docs/ssh-agents.md) | One key vault, one filtered agent per account; WSL relay; devcontainer forwarding |
| [Windows Setup](docs/windows.md) | Windows specifics: elevation, PowerShell profile, Git for Windows, SSH agent, troubleshooting |
| [Devcontainer Setup](docs/devcontainer.md) | Using this in VS Code devcontainers |
| [Backup & Restore](docs/backup-restore.md) | How to back up and restore your environment |
| [Remote Access](docs/remote-access.md) | Private agent access and approved external-app sharing |
| [Guardrail Install](docs/guardrail-install.md) | The agent-guardrails system's design doc |
| [Skills Install Strategy](docs/skills-install-strategy.md) | How Superpowers + curated skills get wired |

## ❓ Troubleshooting

<details>
<summary><strong>Every package fails to install (Windows)</strong></summary>

PowerShell isn't running elevated. Chocolatey requires Administrator rights. Close the window, reopen via **Run as Administrator**, re-run `chezmoi apply`.
</details>

<details>
<summary><strong>"chezmoi.exe blocked by Application Control policy" (Windows)</strong></summary>

Verify the binary/source and use an approved signed distribution or an
organization-approved allow rule. Do not disable Smart App Control: it weakens
endpoint protection. On managed devices, ask IT for an allow rule. [Windows
details](docs/windows.md).
</details>

<details>
<summary><strong>Claude Code didn't install (Linux/macOS)</strong></summary>

The log shows `Error: do not run this installer with sudo`. Re-run without `sudo` — the script elevates internally where needed. See "Do I need sudo?" above.
</details>

<details>
<summary><strong>Docker not found on WSL</strong></summary>

Enable Docker Desktop's WSL Integration for your distro: Docker Desktop → Settings → Resources → WSL Integration → toggle ON. Then restart your terminal. Full steps in [the WSL section above](#wsL-enable-docker-desktop-integration-first).
</details>

<details>
<summary><strong>Docker Desktop won't start (Linux host)</strong></summary>

Docker Desktop needs the `kvm` group. The installer adds you automatically, but group membership only takes effect at login. Log out and back in, then start Docker Desktop again.
</details>

## 🔄 Day-to-Day Commands

```sh
chezmoi apply          # apply pending changes (after editing config or pulling)
chezmoi update         # pull the latest from this repo and apply
chezmoi edit ~/.zshrc # edit any managed file in your $EDITOR, then chezmoi apply
chezmoi diff          # preview what would change
chezmoi doctor        # health check
```

## 📂 Repository Structure

<details>
<summary><strong>For contributors and the curious</strong></summary>

```
install.sh / install.ps1            # Universal bootstrap (consent → gum → menu → chezmoi init)
scripts/select-packages.{sh,ps1}    # The package-group menu (gum multi-select)
scripts/update-versions.sh          # Weekly auto-updater (chezmoi + Antigravity 2.0 pins)
scripts/update_ai_tools.{sh,ps1}    # AI tool upgrade commands
run_onchange_install_packages.*     # Platform installers (16-group gated)
run_onchange_generate_identities.*  # Git identity + SSH key generation
dot_zshrc / dot_gitconfig.tmpl      # Shell and git configuration
dot_config/nvim/                    # Neovim (Lazy.nvim)
dot_config/opencode/modify_tui.json # OpenCode theme (merged into tui.json)
dot_config/ghostty/                 # Ghostty (Mac/Linux twin of Windows Terminal)
AppData/                            # Windows only: Terminal + VS Code keybindings (modify_ merges)
Library/, dot_config/Code/          # macOS / Linux desktop: VS Code keybindings (same template)
.chezmoitemplates/                  # Shared template bodies (VS Code keybindings)
Documents/                          # Windows only: PowerShell profiles
private_dot_ssh/                    # SSH config (templated, mode 600)
.chezmoi.toml.tmpl                  # Config template (16 promptBoolOnce groups)
tests/                              # CI test suite (menu, config keys, skills args)
docs/                               # You are here

scripts/ and tests/ stay in the repo - they are never copied into $HOME.
The `dot` family runs them from the source path.
```
</details>

---

## License

[MIT](LICENSE) — fork it, copy it, teach with it.
