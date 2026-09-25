# Dotfiles (Chezmoi Managed)

[![CI](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/ci.yml/badge.svg)](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/ci.yml)
[![Full Install](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/full-install-test.yml/badge.svg?event=workflow_dispatch)](https://github.com/CtrlCarlitos/dotfiles/actions/workflows/full-install-test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

One command. A menu. Your entire dev environment is set up.

Cross-platform dotfiles for **Linux, macOS, Windows, WSL, and Devcontainers** — shell, editor, git identities, modern CLI tools, AI coding agents, and the wiring between them all.

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

> 🌱 **New here?** [**Quickstart**](docs/quickstart.md) — install, what you got, the four commands you will use, and a ten-minute check that it all works.

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

Curated skills install for every agent in one pass: Claude Code reads
`~/.claude/skills`, OpenCode and Codex discover the shared
`~/.agents/skills` catalog, Antigravity gets a synced copy. Refresh with
`update_ai_tools.sh` / `update_ai_tools.ps1` (or just `dot upgrade`). Full
story — destinations, the `/teach` surface, and why you must restart OpenCode
after a refresh — in
[docs/skills-install-strategy.md](docs/skills-install-strategy.md).

### Prerequisites & platform notes

<details>
<summary><strong>Do I need sudo / an elevated prompt?</strong></summary>

- **Linux/macOS/WSL:** No. Run as your normal user without `sudo`. The script elevates internally only where needed. Running as root breaks some installers (Claude Code's, for one).
- **Windows:** Yes — elevated PowerShell. Chocolatey requires admin rights.
</details>

<details>
<a id="wsl-docker-desktop-integration"></a>
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

If you work across multiple GitHub accounts (personal, work, clients), this repo handles it automatically: **each account's identity is selected based on which folder you're in** — no manual switching. Every account gets its own SSH keys and a conditional include in `~/.gitconfig`; the `devprofile` CLI (`dp`) covers the exceptions (repos outside any mapped path, verification, new accounts).

Command reference and annotated output: [docs/devprofile.md](docs/devprofile.md).

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
| [Quickstart](docs/quickstart.md) | Ten minutes from a fresh machine to a working environment |
| [Docs index](docs/README.md) | Every doc in this repo, one line each |
| [Invariants](docs/invariants.md) | Rules this repo learned the expensive way — read before changing templates, ignores or tests |
| [Testing the dotfiles](docs/testing.md) | The per-platform verify/fix playbook (Linux, macOS, WSL, Windows) |
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
| [Guardrail Install](docs/guardrail-install.md) | How the dotfiles call the agent-guardrails installer |
| [Skills Install Strategy](docs/skills-install-strategy.md) | How Superpowers + curated skills get wired |
| [Agent Skill Wiring Design](docs/agent-skill-wiring-design.md) | The original design spec behind the skills wiring (implemented) |
| [agent-browser install](docs/agent-browser-install.md) | Install requirements for the browser-automation skill's CLI |

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

Enable Docker Desktop's WSL Integration for your distro: Docker Desktop → Settings → Resources → WSL Integration → toggle ON. Then restart your terminal. Full steps in [the WSL section above](#wsl-docker-desktop-integration).
</details>

<details>
<summary><strong>Docker Desktop won't start (Linux host)</strong></summary>

Docker Desktop needs the `kvm` group. The installer adds you automatically, but group membership only takes effect at login. Log out and back in, then start Docker Desktop again.
</details>

## 🔄 Day-to-Day Commands

The `dot` family is the daily interface (zsh and PowerShell both define it):

```sh
dot up        # sync: pull the repo, apply changes. Never upgrades packages.
dot upgrade   # upgrade ALL tooling (apt/brew/choco/winget + AI CLIs). The only thing that does.
dot backup    # encrypted portable backup of config + SSH keys
dot restore   # restore a backup: dot restore <archive.7z>
dot doctor    # dotfiles health check; add --fix to repair what it can
```

`dot` with no arguments prints this list. Underneath, it is still chezmoi —
for the raw commands:

```sh
chezmoi apply          # apply pending changes (after editing config or pulling)
chezmoi edit ~/.zshrc # edit any managed file in your $EDITOR, then chezmoi apply
chezmoi diff          # preview what would change
chezmoi doctor        # chezmoi's own health check
```

### Environment variables the tooling reads

| Variable | Set by / for | What it does |
|---|---|---|
| `DOTUPGRADE_DEFER` | `dot upgrade` | Comma list of tools whose upgrades are deferred because live agent sessions are using them; consumed by `update_ai_tools.*` |
| `DOTFILES_DOCTOR_IN_APPLY` | `run_after_dotfiles-doctor.*` | Runs `dot doctor` mid-apply in a restricted, non-fatal mode (it fires on every `chezmoi apply`) |
| `CHEZMOI_CONFIG_DIR` | `dotfiles-doctor.*` | Where the doctor looks for `chezmoi.toml` (default `~/.config/chezmoi`) |
| `CHEZMOI_SOURCE_DIR` | `run_after_dotfiles-doctor.*` | Where the apply-time doctor finds the source repo (default `~/.local/share/chezmoi`) |
| `DEVPROFILE_PASSPHRASE` | `devprofile init` | `1`/`0` (or `true`/`yes`/`no`/`false`) sets the passphrase default for new keys when no flag is given — see [devprofile](docs/devprofile.md) |

## 📂 Repository Structure

<details>
<summary><strong>For contributors and the curious</strong></summary>

```
install.sh / install.ps1              # Universal bootstrap (consent → menu → chezmoi init --apply)
run_onchange_install_packages.*       # Platform installers (16-group gated)
run_onchange_generate_identities.*    # Git identity + SSH key generation
run_onchange_sync_pwsh_profiles.ps1.tmpl   # OneDrive-redirected profile sync (Windows)
run_after_dotfiles-doctor.*           # dot doctor health check on every apply
run_once_windows_set-executionpolicy.ps1.tmpl  # PS execution policy, once ever
.chezmoi.toml.tmpl                    # Config template (16 promptBoolOnce groups)
.chezmoidata.yaml + .chezmoidata/     # Curated data: VS Code baseline, package catalog, agents.yaml
.chezmoiexternal.toml                 # Oh My Zsh + tmux plugin externals (pinned archives)
.chezmoitemplates/                    # Shared template bodies (pkg-names, keybindings, ...)
.chezmoiignore                        # What never deploys to $HOME
guardrail.toml                        # guardrail overlay (read from the source repo, not $HOME)
dot_zshrc / dot_aliases.zsh           # Shell config + the dot/devprofile/dco alias layer
dot_tmux.conf / dot_gitconfig.tmpl    # tmux bindings; gitconfig with includeIf identity routing
dot_config/                           # nvim (Lazy.nvim), git hooks, starship, ghostty, opencode, Code keys
dot_codex/modify_config.toml          # Codex config (merged, never clobbered)
dot_local/bin/                        # devprofile (+ .ps1 twin), ssh-agent-relay
private_dot_ssh/private_config.tmpl   # SSH config (templated, mode 600)
Documents/                            # Windows only: PowerShell profiles (5.1 + 7)
AppData/, Library/, dot_config/Code/  # Windows Terminal settings + VS Code keybindings (per-OS)
devcontainer/install.sh               # Devcontainer bootstrap
scripts/                              # The dot family, menu, updaters, doctors (never deployed)
tests/                                # CI contract suite — run it: bash tests/run.sh
docs/                                 # You are here — index: docs/README.md

scripts/ and tests/ stay in the repo - they are never copied into $HOME.
The `dot` family runs them from the source path.
```
</details>

---

## License

[MIT](LICENSE) — fork it, copy it, teach with it.
