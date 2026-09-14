## The Menu

When you run the installer, this is what you'll see:

**Step 1 — Pick a preset:**
```
? Choose a starting preset:
  minimal    (core only — terminal fundamentals)
  standard   (core + modern CLI + fonts + agent toolkit + Claude Code + guardrails)
  full       (everything, including all desktop apps)
> custom    (pick exactly what you want)
```

**Step 2 — Toggle your groups** (if you chose custom):
```
? Toggle the package groups you want (space to select, enter to confirm):
> [x] core              Terminal fundamentals (git, zsh, tmux, node, neovim...)
  [x] modern_cli        Modern CLI replacements (bat, eza, starship, delta...)
  [x] fonts             Nerd Fonts (required for Starship icons)
  [x] agent_toolkit     Cross-vendor agent layer (OpenCode, Serena, Graft, act...)
  [x] opencode_cli      OpenCode CLI + Superpowers + skills + guardrail
  [ ] opencode_desktop  OpenCode Desktop app (all platforms)
  [x] claude_cli        Claude Code CLI + Superpowers + skills + guardrail
  [ ] claude_desktop    Claude Desktop app (Windows/macOS only)
  [ ] chatgpt_cli       Codex CLI (OpenAI)
  [ ] chatgpt_desktop   ChatGPT Desktop app (Windows/macOS only)
  [x] antigravity_cli   Antigravity CLI (agy) + Superpowers + skills
  [ ] antigravity_desktop  Antigravity 2.0 app (all platforms)
  [ ] dev_desktop       Human desktop apps (Chrome, VS Code, Docker Desktop...)
  [ ] remote_access     Tailscale and cloudflared tools (no sign-in or tunnel setup)
  [ ] remote_access_server  OpenSSH-server prerequisites (manual setup required)
  [x] guardrail         Agent guardrails (hook enforcement)
```

**Step 3 — Done.** Your selections are saved to `~/.config/chezmoi/chezmoi.toml` and installed on the next `chezmoi apply`. Re-run the menu anytime:
```sh
bash ~/.local/share/chezmoi/scripts/select-packages.sh
```

> 💡 The menu uses [gum](https://github.com/charmbracelet/gum) — you already have it.
> If gum isn't available, chezmoi's native prompts collect the same choices.
