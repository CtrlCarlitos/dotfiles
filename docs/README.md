# Docs index

Every document in `docs/`, one line each. Start with the quickstart; the rest
are reference.

## Getting started

- [Quickstart](quickstart.md) — ten minutes from a fresh machine to a working environment
- [Package Groups](package-groups.md) — the 16 groups, presets, and how to change your selection
- [Menu Demo](menu-demo.md) — what the selection menu actually looks like
- [Backup & Restore](backup-restore.md) — `dot backup` / `dot restore`, the encrypted portable archive

## Daily reference

- [devprofile](devprofile.md) — multi-account git identities, SSH keys, signing, passphrases
- [Git](git.md) — line endings, gitconfig defaults, delta, aliases
- [Terminal Experience](terminal.md) — Windows Terminal, VS Code terminal, agent keys, clipboard, SSH host tabs
- [Zsh Tips](zsh-tips.md) — plugins, aliases, globbing, troubleshooting
- [Tmux Guide](tmux.md) — sessions, panes, windows, copy mode
- [Neovim Guide](nvim.md) — keymaps, plugins, clipboard
- [Zsh, Tmux & Neovim Tutorial](tmux-nvim-tutorial.md) — the beginner on-ramp for all three
- [Windows Setup](windows.md) — elevation, PowerShell profiles, `dot upgrade` on Windows, troubleshooting

## Agents and security

- [Agent Context Tools](agent-context-tools.md) — Serena + Graft: what they do, how to query them
- [Skills Install Strategy](skills-install-strategy.md) — the as-built curated-skills wiring (status: implemented)
- [Agent Skill Wiring Design](agent-skill-wiring-design.md) — the original design spec behind it (implemented; rationale record)
- [agent-browser install](agent-browser-install.md) — install requirements for the browser-automation CLI
- [Guardrail Install](guardrail-install.md) — how the dotfiles call the agent-guardrails installer, and the config they ship
- [Secrets & SSH Hosts](secrets.md) — machine-local config, SSH aliases, safe handling
- [SSH Agents](ssh-agents.md) — the key vault, the WSL relay, devcontainer forwarding

## Platform and internals

- [Tool Parity](tool-parity.md) — the full per-program table across all 5 platforms
- [VS Code](vscode.md) — managed extensions, settings tiers, per-machine overrides
- [Devcontainer Setup](devcontainer.md) — using the dotfiles in VS Code devcontainers
- [Remote Access](remote-access.md) — private mesh access and approved app tunneling
- [Testing the dotfiles](testing.md) — the per-platform verify/fix playbook (Linux, macOS, WSL, Windows)
- [Config Example](chezmoi.toml.example) — complete annotated `chezmoi.toml`
- [Invariants](invariants.md) — the expensive lessons; read before changing templates, ignores or tests

## Elsewhere in the repo

- [README](../README.md) — install one-liners and the day-to-day `dot` family
- [SECURITY](../SECURITY.md) — how to report vulnerabilities
