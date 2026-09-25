# VS Code global settings & extensions

Repo-curated machine baseline + per-machine drift, applied by the package
installers. They're `run_onchange_` scripts, so they run when their rendered
content changes: after a repo update that touches them, or a change to your package
selection or `[data.vscode_overrides]`. They don't run on every apply. Opt out wholesale with:

```toml
[data.packages]
vscode_settings = false
```

## Where things live

| What | Home |
|---|---|
| Extension baseline (23 curated + 1 Windows-only) | `.chezmoidata.yaml` → `vscode.extensions` (+ `extensions_windows`) |
| Whole-feature gate | `~/.config/chezmoi/chezmoi.toml` → `[data.packages]` → `vscode_settings` |
| Settings baseline (forced/upsert/merge/unset tiers) | `.chezmoidata.yaml` → `vscode.settings` — both installer templates render from it |
| Keybindings (agent keys) | `.chezmoitemplates/vscode-keybindings.json`, applied by per-OS `modify_keybindings.json` wrappers |
| Machine overrides | `~/.config/chezmoi/chezmoi.toml` → `[data.vscode_overrides]` |

**Why a different key (`vscode_overrides`, not `vscode`)**: chezmoi does not
deep-merge same-named data tables — a config `[data.vscode]` table is
wholesale-shadowed by the `.chezmoidata.yaml` `vscode` table (confirmed
live). Overrides therefore live under their own key and the merge happens
in the installers.

## Settings tiers

| Tier | Keys | On re-apply | Local drift |
|---|---|---|---|
| FORCED | editor/terminal font (MesloLGS Nerd Font Mono) | re-asserted | exclude to stop |
| UPSERT | ~20 curated defaults, including the integrated terminal's (see below) | only written when absent | your value wins |
| MERGE | `files.exclude` / `search.exclude` junk dirs; `workbench.colorCustomizations` terminal colors | only missing sub-keys added | your entries stay |
| UNSET | `remote.SSH.configFile` | removed when present | exclude to keep |

UNSET exists for one key: `remote.SSH.configFile` pointed Remote-SSH at a hand-kept
config outside `~/.ssh`, so those hosts never reached `ssh`, Windows Terminal, or
chezmoi. Without it, Remote-SSH reads `~/.ssh/config`, which chezmoi renders from
`[[data.ssh_hosts]]` (see [Secrets & SSH Hosts](secrets.md)).

### Integrated terminal

The UPSERT tier sets the integrated terminal to match Windows Terminal. The full
picture is in [Terminal Experience](terminal.md).

| Setting | Value | Why |
|---|---|---|
| `terminal.integrated.fontSize` | `16` | About 12pt, the Windows Terminal size |
| `terminal.integrated.copyOnSelection` | `true` | Highlight copies |
| `terminal.integrated.rightClickBehavior` | `paste` | Right-click pastes |
| `terminal.integrated.commandsToSkipShell` | `-…toggleSidebarVisibility`, `-…togglePanel` | `Ctrl+B` / `Ctrl+J` reach the agent CLIs |
| `terminal.integrated.enableWin32InputMode` | `true` (Windows only) | Shift+Enter reaches CLIs behind ConPTY |
| `workbench.colorCustomizations` (MERGE) | Catppuccin Mocha `terminal.*` colors | Same palette; the editor theme is untouched |

> [!WARNING]
> **Don't run Claude Code's `/terminal-setup` in VS Code.** It adds a `shift+enter`
> → `workbench.action.terminal.sendSequence` (Esc+Enter) binding that applies to
> every program in the terminal. At a PowerShell prompt Esc clears the line, so
> `Shift+Enter` would wipe your command and run an empty one.
> `enableWin32InputMode` (above) already gets `Shift+Enter` to the agent CLIs. If you
> ran it already, delete that entry from `keybindings.json`. See
> [Terminal Experience](terminal.md#new-line-vs-submit).

### Keybindings

One shared template, `.chezmoitemplates/vscode-keybindings.json`, merges the agent
keys into VS Code's own `keybindings.json` on every OS. There's a thin
`modify_keybindings.json` wrapper per location:

- Windows: `AppData/Roaming/Code/User`
- macOS: `Library/Application Support/Code/User`
- Linux desktop: `dot_config/Code/User`

`.chezmoiignore` applies a wrapper only where VS Code's User folder already exists,
so a headless server never gets a Code config. WSL is skipped because its VS Code
keys live on the Windows side. The keys are scoped to a focused terminal: `Ctrl+Alt+C`/`X`/`O`/`A` type
`claude`/`codex`/`opencode`/`agy` + Enter; add `Shift` to run them in a new split.
Entries bound to the same keys are replaced; everything else in the file stays.
VS Code's comment header is dropped on the first merge.

## Nested values in extra_settings

Arrays and objects are fully supported. They are serialized to JSON for the
installers; `chezmoi init` may normalize TOML inline tables into nested tables
while preserving their values:

```toml
[data.vscode_overrides.extra_settings]
  "editor.rulers" = [80, 120]                       # array
  "editor.codeActionsOnSave" = { "source.fixAll.eslint" = "explicit" }   # object
  "[python]" = { "editor.tabSize" = 4 }              # language scope = just a key with brackets
```

One semantic to know: **upsert applies to the whole key**. An extra with an
object value is written only when the *entire key is absent* — there is no
deep-merge into an existing object. (Deep-merge exists only for the MERGE-tier
keys (`files.exclude`, `search.exclude`, `workbench.colorCustomizations`), and
only for the baseline entries.) If you need to merge into an existing object setting, set it
by hand in `settings.json` — upsert will never fight you.

The override payloads embed as literal blocks inside the installers (a
quoted heredoc on the Unix side, a literal here-string on the Windows
side): values may contain single quotes (terminal profile commands, quoted
font names) which would otherwise terminate single-quoted strings mid-line
in both twins.

## Machine overrides (`[data.vscode_overrides]`)

```toml
# ~/.config/chezmoi/chezmoi.toml
[data.vscode_overrides]

  # Extensions: extras append to the baseline; exclusions stop reinstalling
  # on this machine only (the repo-side veto contract still guards the
  # curated list itself).
  extra_extensions    = ["hashicorp.terraform"]
  exclude_extensions  = ["ms-python.pylint"]

  # Settings: exclusions strip any tier - including a FORCED font key, which
  # is how a machine keeps its own font. Extras join the upsert tier (only
  # applied when the key is absent). To CHANGE a baseline value: exclude it
  # AND add an extra with your value.
  exclude_settings    = ["terminal.integrated.fontFamily"]
  [data.vscode_overrides.extra_settings]
    "editor.fontSize"    = 15
    "files.autoSaveDelay" = 1000
```

## Creation semantics

- Settings file missing → created with the full effective set (only when VS
  Code itself is installed; never fabricate `%APPDATA%\Code`).
- Existing file → `.bak` before any change; JSONC (comments/trailing commas)
  is parsed tolerantly and malformed files are never clobbered. A changed file
  is rewritten as strict, alphabetized JSON with two-space indentation, so
  comments remain only in the `.bak` copy.
- Projects keep full authority: their `.vscode/settings.json` layers on top
  of these machine globals.
