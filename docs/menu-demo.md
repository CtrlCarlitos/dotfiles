## The Menu

When you run the installer, this is what you'll see. (Mirrors
`scripts/select-packages.sh` / `.ps1`; the strings below are the script's
own headers, so if they drift the scripts win.)

**Step 1 — Pick a preset:**

```
Preset? minimal=core only | standard=recommended | full=everything | custom=hand-pick
? (use the arrows)
  minimal    core only — terminal fundamentals
  standard   recommended (see the pre-checked groups below)
  full       everything except remote_access_server
> custom     hand-pick (nothing pre-checked)
```

**Step 2 — Toggle your groups.** This multi-select runs for **every** preset,
pre-checked with your preset's groups (or, on a re-run, with whatever your
config already has true):

```
Toggle package groups (space=toggle, a=all, enter=confirm)
> [x] core              Terminal fundamentals (git, zsh, tmux, node, neovim...)
  [x] modern_cli        Modern CLI replacements (bat, eza, starship, delta...)
  [x] fonts             Nerd Fonts (required for Starship icons)
  [x] agent_toolkit     Cross-vendor agent layer (Serena, Graft, act...)
  [x] opencode_cli      OpenCode CLI + Superpowers + skills + guardrail
  [ ] opencode_desktop  OpenCode Desktop app
  [x] claude_cli        Claude Code CLI + Superpowers + skills + guardrail
  [ ] claude_desktop    Claude Desktop app
  [ ] chatgpt_cli       Codex CLI (OpenAI)
  [ ] chatgpt_desktop   ChatGPT Desktop app
  [ ] antigravity_cli   Antigravity CLI (agy) + Superpowers + skills
  [ ] antigravity_desktop  Antigravity 2.0 app
  [ ] dev_desktop       Human desktop apps (Chrome, VS Code, Docker Desktop...)
  [ ] remote_access     Tailscale and cloudflared tools (no sign-in or tunnel setup)
  [ ] remote_access_server  OpenSSH-server prerequisites (manual setup required)
  [x] guardrail         Agent guardrails (hook enforcement)
```

(That pre-check set is the **standard** preset. Host-only groups — the
desktop apps — are also skipped entirely on WSL and in containers.)

**Step 3 — Done.** Your selections are saved to `~/.config/chezmoi/chezmoi.toml` and installed on the next `chezmoi apply`. Re-run the menu anytime:
```sh
bash "$(chezmoi source-path)/scripts/select-packages.sh"
```

> 💡 The menu uses [gum](https://github.com/charmbracelet/gum) — you already have it.
> If gum isn't available (or stdin isn't a TTY, e.g. CI), the menu skips and
> chezmoi's native prompts or your existing config apply as-is.
