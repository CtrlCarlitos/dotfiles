# Package Groups

_Added 2026-09-13 with the package-groups project
(docs/research/package-groups-spec.md)._

How this repo decides what to install. The 16 groups below are the single
vocabulary shared by everything that touches packages: the interactive menu
(`scripts/select-packages.{sh,ps1}`), the config template's `promptBoolOnce`
keys, the installer templates' gates, and the CI seeds all use the same key
names — `tests/check_workflow_config_keys.sh` exists to keep them from
drifting apart.

## The 16 groups

The "menu line" is the group's one-line description (what the config-template
prompts show). The gum menu itself lists the bare keys in this order under
the header "Toggle package groups (space=toggle, a=all, enter=confirm)" —
the order below is load-bearing: it's the menu's display order and the order
the persisted `[data.packages]` section is emitted in.

| Group | Menu line | Contents |
|---|---|---|
| `core` | Terminal fundamentals | git, zsh, tmux/psmux, node 24, python, neovim, ripgrep, gh, jq, fzf, 7zip… |
| `modern_cli` | Modern CLI replacements | bat, eza, fd, starship, zoxide, direnv, lazygit, delta, gum, tealdeer, dust/duf/procs, shellcheck, shfmt |
| `fonts` | Nerd Fonts | MesloLGS NF |
| `agent_toolkit` | Cross-vendor agent layer | Serena, Graft, act, Playwright Chromium |
| `opencode_cli` | OpenCode CLI + Superpowers + skills + guardrail | OpenCode CLI (native installer / choco) + superpowers plugin + curated skills + guardrail opencode plane |
| `opencode_desktop` | OpenCode Desktop app | Win choco `opencode-desktop`; mac brew cask `opencode-desktop`; Linux GitHub-release .deb (amd64) |
| `claude_cli` | Claude Code | Claude Code CLI + superpowers plugin + curated skills + guardrail claude plane |
| `claude_desktop` | Claude Desktop app | Win choco `claude`; mac brew cask `claude`; Linux: none exists (info line, no-op) |
| `chatgpt_cli` | Codex CLI | `@openai/codex` npm. Zero wiring by design (superpowers/skills/guardrail have no codex surface) |
| `chatgpt_desktop` | ChatGPT desktop app | Win winget msstore `9PLM9XGG6VKS` (ChatGPT Work/Codex); mac brew cask `chatgpt`; Linux: none (no-op) |
| `antigravity_cli` | Antigravity CLI (agy) | choco `antigravity-cli` / brew cask / official script + superpowers + skills + guardrail antigravity plane |
| `antigravity_desktop` | Antigravity 2.0 app | Win choco `antigravity`; mac 2.0 dmg; Linux 2.0 x64/arm64 (pinned hub-channel URLs) |
| `dev_desktop` | Human desktop apps | Chrome, VS Code, Docker Desktop, CodexBar, ScreenRec, Termius, Handy… |
| `remote_access` | Private mesh access and approved app tunneling | Tailscale and cloudflared; installs tools only, no sign-in, tunnel, or service setup |
| `remote_access_server` | Explicit SSH-server prerequisite opt-in | OpenSSH-server prerequisites only; no keys, firewall, service, or configuration changes |
| `guardrail` | Agent guardrails | guardrail binary; planes fire per present CLI (existing gating) |

## Ground rules

**Placement — who uses it decides where it lives.** A vendor's whole product
line goes in that vendor's group (Claude Code → `claude_cli`, Claude Desktop
→ `claude_desktop`). Something an *agent* uses → `agent_toolkit` (e.g.
Playwright Chromium). Something a *human* uses → `dev_desktop` (e.g. Chrome).

**Wiring keys off CLI groups only.** The superpowers plugins, the curated
skills pass, and the guardrail planes gate on `claude_cli`, `opencode_cli`,
`antigravity_cli`, and `agent_toolkit` — never on the desktop groups. Desktop
groups are pure installs: the app lands, nothing gets wired into it.

**The menu owns `[data.packages]`.** Re-running the menu rewrites the whole
section — hand-edited keys inside it are intentionally overwritten (that's
what re-choosing means). Everything outside the section (accounts etc.) is
byte-preserved. To hand-edit, edit the file directly or use the
`chezmoi init` prompts; just don't expect edits inside the section to
survive the next menu run.

**Disabling never uninstalls.** The installers only ever add. Turning a
group off stops it installing on new machines; removing it from a machine
that already applied it stays manual, as it always was.

## The menu

`install.sh` / `install.ps1` run the menu *before* `chezmoi init --apply`,
so the selection lands in `~/.config/chezmoi/chezmoi.toml` ahead of the
config template. The flow by entry point:

- **Fresh machine (`install.sh` / `install.ps1`):** plain y/n consent prompt
  (no dependencies — naked-machine safe) → gum bootstrap (pinned static
  download if `gum` isn't on PATH; best-effort, warns and continues on
  failure) → preset pick (`minimal` / `standard` / `full` / `custom`) → the
  16-group multi-select, pre-checked per the preset → `chezmoi init --apply`
  (accounts still prompted by chezmoi itself).
- **Re-run:** your existing `[data.packages]` keys arrive pre-checked — one
  Enter accepts them unchanged. No preset prompt; presets are first-run
  scaffolding only.
- **Standalone re-choose:** run `scripts/select-packages.sh` (or `.ps1`)
  directly at any time, then `chezmoi apply` installs the difference.
- **Bare `chezmoi init` (no installer, no gum):** the config template's
  `promptBoolOnce` prompts take over — same 16 keys, one question each,
  defaults = the standard preset. Non-interactive renders (CI, containers,
  no TTY) take `false` for every key: explicit seeds and prompts are the
  only sources of truth.
- **CI:** workflow configs are pre-seeded with all 16 keys and the menu
  self-skips (no TTY / `$env:CI` set / no gum → prints "skipping menu",
  exits 0, never prompts).

## Presets

| Preset | Pre-checks |
|---|---|
| `minimal` | `core` |
| `standard` | `core`, `modern_cli`, `fonts`, `agent_toolkit`, `opencode_cli`, `claude_cli`, `guardrail` |
| `full` | all groups except `remote_access_server` |
| `custom` | nothing — hand-pick in the multi-select |

Presets are **not persisted** — they're pre-check sets for the menu only.
What lands in the config is always the 16 explicit booleans; the config
template's prompt defaults equal the standard preset.

## Rename map (clean break)

The old six `install_*` toggles became these groups. No auto-migration —
old keys are simply ignored if they're still lying around in a config:

- `install_core` → `core`
- `install_modern` → `modern_cli`
- `install_fonts` → `fonts`
- `install_ai_tools` → `agent_toolkit` (Codex, Claude Code, and `agy` moved
  out to their own vendor groups: `chatgpt_cli`, `claude_cli`,
  `antigravity_cli`)
- `install_desktop` → `dev_desktop`
- `install_guardrail` → `guardrail`
- `install_antigravity` → already gone (removed 2026-09-11)

## FAQ

**Why no per-package keys?** Because groups are the vocabulary *everywhere*
— menu options, config keys, and CI seeds are the same names, and one test
enforces that. Per-package keys would multiply the prompts, the CI seeds,
and the drift surface without adding control the groups don't already give;
sixteen lines is also what a person will actually read in a menu.

**Does turning a group off uninstall anything?** No — disabling never
uninstalls (see ground rules). Uninstalling stays manual.

**Linux + Claude/ChatGPT desktop?** Neither app exists officially for
Linux as of 2026-09. Those two groups are no-ops there by design, not
failures: the installer prints an info line ("no official Linux build -
skipping") and moves on. Antigravity 2.0 does ship Linux builds, so
`antigravity_desktop` installs for real on all three platforms.

**Why do the desktop groups have no wiring?** The wiring (superpowers
plugins, curated skills, guardrail planes) targets CLIs — that's where the
plugin/hook surfaces live. The desktop apps have none of that to wire;
they're just apps, so they're pure installs.
