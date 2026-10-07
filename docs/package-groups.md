# Package Groups

_Added 2026-09-13 with the package-groups project (the design spec lived in
the gitignored `docs/research/` scratch area and is not part of the repo;
this page is the canonical taxonomy)._

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
| `modern_cli` | Modern CLI replacements | bat, eza, fd, starship, zoxide, direnv, lazygit, delta, gum, tealdeer, dust/duf/procs, shellcheck, shfmt; docs linting (markdownlint-cli2 via npm, lychee, vale); network diagnostics (net-tools, dnsutils, traceroute, mtr, tcpdump, nmap, whois, iperf3, telnet — #177) |
| `fonts` | Nerd Fonts | MesloLGS NF |
| `agent_toolkit` | Cross-vendor agent layer | Serena, Graft, act, Playwright Chromium |
| `opencode_cli` | OpenCode CLI + Superpowers + skills + guardrail | OpenCode CLI (native installer / choco) + superpowers plugin + curated skills + guardrail opencode plane |
| `opencode_desktop` | OpenCode Desktop app | Win choco `opencode-desktop`; mac brew cask `opencode-desktop`; Linux GitHub-release .deb (amd64) |
| `claude_cli` | Claude Code | Claude Code CLI + superpowers plugin + curated skills + guardrail claude plane |
| `claude_desktop` | Claude Desktop app | Win choco `claude`; mac brew cask `claude`; Linux: none exists (info line, no-op) |
| `chatgpt_cli` | Codex CLI | `@openai/codex` npm + Superpowers via `codex plugin add superpowers@openai-curated-remote` + curated skills in shared `~/.agents/skills` (OpenCode and Codex); no generated command adapters |
| `chatgpt_desktop` | ChatGPT desktop app | Win winget msstore `9PLM9XGG6VKS` (ChatGPT Work/Codex); mac brew cask `chatgpt`; Linux: none (no-op) |
| `antigravity_cli` | Antigravity CLI (agy) | choco `antigravity-cli` / brew cask / official script + superpowers + skills + guardrail antigravity plane |
| `antigravity_desktop` | Antigravity 2.0 app | Win choco `antigravity`; mac 2.0 dmg; Linux 2.0 x64/arm64 (pinned hub-channel URLs) |
| `dev_desktop` | Human desktop apps | Chrome, VS Code, Ghostty (Mac/Linux), Docker Desktop, CodexBar, ScreenRec, Termius, Handy… |
| `remote_access` | Private mesh access and approved app tunneling | Tailscale and cloudflared; installs tools only, no sign-in, tunnel, or service setup |
| `remote_access_server` | Explicit SSH-server prerequisite opt-in | OpenSSH-server prerequisites only; no keys, firewall, service, or configuration changes |
| `guardrail` | Agent guardrails | opt-in desired state, passed to the pinned agent-guardrails installer: true = `--state enabled`; false = `--state disabled` only if a binary exists, never a download (never auto-removed). See [guardrail-install.md](guardrail-install.md) |

## Ground rules

**Placement — who uses it decides where it lives.** A vendor's whole product
line goes in that vendor's group (Claude Code → `claude_cli`, Claude Desktop
→ `claude_desktop`). Something an *agent* uses → `agent_toolkit` (e.g.
Playwright Chromium). Something a *human* uses → `dev_desktop` (e.g. Chrome).

**Wiring keys off CLI groups only.** The superpowers plugins and the curated
skills pass (18 curated skills, `scripts/curated-agent-skills.txt`) gate on
`claude_cli`, `opencode_cli`, `antigravity_cli`, and `agent_toolkit` — never on
the desktop groups. The guardrail planes are
registered by the agent-guardrails installer (`guardrail setup`) for each agent
CLI it detects. Desktop groups are pure installs: the app lands, nothing gets
wired into it.

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

**`vscode_settings` is not a group.** `[data.packages]` also carries a
`vscode_settings` flag (default `true`, no prompt, not in the menu) that gates
VS Code settings and extension management; see [VS Code](vscode.md). It is not
one of the 16, no preset touches it, and the menu preserves an existing value
when it rewrites the section.

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

## Where the package names live

Every package-manager name is in one file: `.chezmoidata/packages.yaml`, one
record per tool with its `apt`, `brew`, `cask`, `winget` and `choco` spellings (`fd` is
`fd-find` on apt; 7-Zip is `p7zip-full` / `sevenzip` / `7zip.install`). Both
installers render their manager's lists from it, and
`scripts/migrate-to-winget.ps1` (and the older `migrate-to-choco.ps1`) read the same records at runtime — so adding,
renaming or dropping a package is one edit, and `tests/package_catalog_contract.sh`
fails if a name reappears anywhere else.

Tools that need more than a plain install (a repository, a signing key, a
`.deb` download) stay as procedures in the installers; their catalog record
says so in its `note` and carries no name for that manager.

### Windows: winget first, Chocolatey as the fallback

On Windows a record names **winget** (`winget:`, with optional `winget_args` such as
`--scope machine` for VS Code and PowerShell, which Chocolatey had installed machine-wide)
and only falls back to **Chocolatey** (`choco:`) where winget has no package or carries an older
one: today the Antigravity CLI, the Meslo Nerd Font, npiperelay, Python and Vale. Node.js comes from
winget's LTS package (`OpenJS.NodeJS.LTS`, the `versions.node_major` line): Chocolatey's `nodejs`
had floated to 26 under `choco upgrade all`, past the 24 pin. winget's LTS package follows whatever
is LTS today, so a gating pin (`winget pin add --version <node_major>.*`) holds it on the same major
as Linux/WSL (NodeSource's `node_<major>.x` repo) and macOS (`node@<major>`); `dot upgrade` keeps the
pin in step with `versions.node_major`, so one bump there moves all three. The
installer installs Chocolatey's list first, then winget's, from one `winget list` inventory;
`dot upgrade` sweeps both (`choco upgrade all`, `winget upgrade --all`). WSL belongs to neither:
the installer runs `wsl --install --no-distribution` when it is missing and `dot upgrade` runs
`wsl --update`.

A tool that moved keeps its old Chocolatey name in `choco_was`. An app Chocolatey installed cannot
be adopted by winget ("install technology is different"), so an existing machine moves with
`scripts/migrate-to-winget.ps1` (elevated): `-ListOnly` prints the plan; otherwise the plain tools
move as one batch after one question, each app with a `migrate_risk` note (VS Code, Git,
Tailscale, Claude Desktop, Termius, Handy, PowerShell) is asked about on its own, and what dotfiles
replaced (WinMerge -> Meld, Notepad++ -> Geany, WinSCP -> Termius, CutePDF -> Microsoft Print to
PDF, with the Ghostscript and AutoHotkey packages that came with it), Chocolatey GUI and
Chocolatey's WSL record (`--skip-autouninstaller`: WSL itself stays) are dropped after a last
question. A failed winget install prints the `choco install` that puts the app back. PowerShell 7
cannot replace itself: run the script once more from Windows PowerShell (`powershell.exe`) for it.
Moving Node from 26 to 24 LTS rebuilds the global npm tools' native modules (`npm rebuild -g`)
right after. A tool that a package staying on Chocolatey depends on stays too, and the plan says
which one (`fzf`, `ripgrep` and `unzip` under `opencode`). A meta package and its `.install`
package leave in one `choco uninstall` (alone, the meta package waits on a prompt). Chocolatey's
exit code is not trusted on its own: a package that is gone despite a non-zero exit (a warning
from its uninstall script) still gets its winget copy. `tests/migrate_to_winget_contract.sh`
runs the plan and each step against fakes.
