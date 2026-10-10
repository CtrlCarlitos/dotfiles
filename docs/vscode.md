# VS Code global settings & extensions

Repo-curated machine baseline + per-machine drift, applied by the package
installers. They're `run_onchange_` scripts, so they run when their rendered
content changes: after a repo update that touches them, or a change to your package
selection, `[data.vscode.settings]` or `[data.vscode_overrides]`. They don't run on every apply. Opt out wholesale with:

```toml
[data.packages]
vscode_settings = false
```

## Where things live

| What | Home |
|---|---|
| Extension baseline (24 curated + 1 Windows-only) | `.chezmoidata.yaml` → `vscode.extensions` (+ `extensions_windows`) |
| Whole-feature gate | `~/.config/chezmoi/chezmoi.toml` → `[data.packages]` → `vscode_settings` |
| Settings (forced/upsert/merge/unset tiers) | `~/.config/chezmoi/chezmoi.toml` → `[data.vscode.settings]`, seeded from `.chezmoitemplates/vscode-settings.toml` — both installer templates render from it |
| Keybindings (agent keys, pane/tab parity chords) | `.chezmoitemplates/vscode-keybindings.json`, applied by per-OS `modify_keybindings.json` wrappers |
| Machine overrides | `~/.config/chezmoi/chezmoi.toml` → `[data.vscode_overrides]` |

**Why the extension drift has its own key (`vscode_overrides`)**: chezmoi merges
the config's data with `.chezmoidata.yaml` table by table, key by key (the config
wins a conflict), but a **list** set in the config replaces the repo's list. An
`extensions = [...]` under `[data.vscode]` would drop the whole curated baseline,
so extension drift lives under its own key and the merge happens in the
installers. The settings, on the other hand, are in the config only: if they were
also in `.chezmoidata.yaml`, a key you deleted from `chezmoi.toml` would come back
from the merge.

## Your settings in chezmoi.toml

The settings are per machine, in `[data.vscode.settings]` of
`~/.config/chezmoi/chezmoi.toml`. `chezmoi init` (which `dot up` runs) writes them:

- **No table yet** (a new machine, or one set up before the move): the seed,
  `.chezmoitemplates/vscode-settings.toml`.
- **A table already there:** written back as it is. An edited value, an added key,
  a deleted key or a deleted tier all survive.

So a change to the seed reaches **new machines only**; an existing machine changes
when you edit its `chezmoi.toml`. `chezmoi init` writes the table with sorted keys
and no comments, so the reasons live here. A tier you delete is treated as empty.
The first `dot up` after the move applies once before its `chezmoi init`; that run
prints `VS Code settings: not in chezmoi.toml yet` and skips the settings, and the
apply after the init writes them.

```toml
[data.vscode.settings]
  junk  = ["**/__pycache__/**", "**/.venv/**", "**/venv/**", "**/node_modules/**", "**/*.pyc"]
  unset = []
  [data.vscode.settings.defaults]
    "files.autoSaveDelay" = 500
  [data.vscode.settings.defaults_windows]
    "terminal.integrated.enableWin32InputMode" = true
  [data.vscode.settings.forced]
    "editor.fontFamily" = "FiraCode Nerd Font"
    "editor.fontLigatures" = true
    "terminal.integrated.fontFamily" = "MesloLGS Nerd Font Mono"
    "terminal.integrated.gpuAcceleration" = "off"
    "remote.SSH.configFile" = "C:/Users/carlitos/.ssh/vscode_hosts"
  [data.vscode.settings.terminal_colors]
    "terminal.background" = "#181818"
```

`[data.vscode_overrides]` `exclude_settings` / `extra_settings` still work, but
editing the tiers here directly is simpler.

## Settings tiers

| Tier | Keys | On re-apply | Local drift |
|---|---|---|---|
| FORCED | editor font + ligatures, terminal font, terminal GPU acceleration, `remote.SSH.configFile` (see below) | re-asserted | exclude to stop |
| UPSERT | 21 curated defaults (+1 Windows-only), including the integrated terminal's (see below) | only written when absent | your value wins |
| MERGE | `files.exclude` / `search.exclude` junk dirs; `workbench.colorCustomizations` terminal colors | only missing sub-keys added | your entries stay |
| UNSET | (none by default) | removed when present | — |

### Editor vs. terminal font

`editor.fontFamily` and `terminal.integrated.fontFamily` are independent keys,
set to different faces on purpose: the editor uses the plain **FiraCode Nerd
Font** face (`editor.fontLigatures: true` turns `!=`, `=>`, `->` into their
connected glyphs - the font's whole reason for being there), while every
terminal surface (Windows Terminal, the VS Code integrated terminal, Ghostty)
stays on **MesloLGS Nerd Font Mono** for its Nerd Font prompt icons - see
[docs/windows.md](windows.md#font) for why each gets the face it does. Windows
Terminal's own default font is kept in sync with `terminal.integrated.fontFamily`
(not `editor.fontFamily`) by the installer, so the two terminal faces can never
drift apart; see `run_onchange_install_packages.ps1.tmpl` ("Wire the Nerd Font").

### `remote.SSH.configFile`

Forced to `~/.ssh/vscode_hosts` (with `/` separators even on Windows, since the
value lands in JSON and OpenSSH-style paths work either way there). That file holds
only `[[data.ssh_hosts]]` - no `github-<user>` git identity aliases - so
Remote-SSH's "Connect to Host" list shows real remote machines only, instead of
also listing every configured git account. `~/.ssh/config` `Include`s that file,
so `ssh` and `dot ssh` still see every host exactly as before. See
[Secrets & SSH Hosts](secrets.md#ssh-hosts-datassh_hosts).

Unlike every other FORCED key, this one isn't a literal in the seed
(`.chezmoitemplates/vscode-settings.toml`) - it needs this machine's home
directory, and the seed is plain, strict TOML (CI's "Validate all TOML and
YAML files" step parses it with Python's `tomllib`, so it can't hold a
template expression). `.chezmoi.toml.tmpl` injects it into `[forced]` right
after loading the seed, first-seed only - same "new machines only" rule as
the note below.

> [!NOTE]
> **Existing machine, from before this split:** `chezmoi init` writes a table
> back as-is when one already exists (see [Your settings in
> chezmoi.toml](#your-settings-in-chezmoitoml) above), so a machine whose
> `chezmoi.toml` still has `unset = ["remote.SSH.configFile"]` from before this
> change won't pick up the new FORCED value on its own. Delete that line (and
> add the `remote.SSH.configFile` entry under `[data.vscode.settings.forced]` if
> you want it before the next `chezmoi init` reseeds it) once, by hand.

### Integrated terminal

The UPSERT tier sets the integrated terminal to match Windows Terminal. The full
picture is in [Terminal Experience](terminal.md).

| Setting | Value | Why |
|---|---|---|
| `terminal.integrated.fontSize` | `16` | About 12pt, the Windows Terminal size |
| `terminal.integrated.cursorStyle` | `bar` | Windows Terminal's bar cursor (VS Code defaults to block) |
| `terminal.integrated.scrollback` | `30000` | Long agent transcripts |
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
agent keys and the Windows Terminal parity chords into VS Code's own `keybindings.json` on every OS (including `Ctrl+Enter` = line feed in the terminal, so it is a newline in every agent CLI). There's a thin
`modify_keybindings.json` wrapper per location:

- Windows: `AppData/Roaming/Code/User`
- macOS: `Library/Application Support/Code/User`
- Linux desktop: `dot_config/Code/User`

`.chezmoiignore` applies a wrapper only where VS Code's User folder already exists,
so a headless server never gets a Code config. WSL is skipped because its VS Code
keys live on the Windows side. The keys are scoped to a focused terminal: `Ctrl+Alt+C`/`X`/`O`/`A` type
`claude`/`codex`/`opencode`/`agy` + Enter; add `Shift` to run them in a new split
(same folder). The parity chords, also only while a terminal has focus:

| Keys | Action |
|---|---|
| `Alt+Shift+D` | Split the terminal |
| `Alt+←` / `Alt+→` | Focus previous / next terminal |
| `Ctrl+Tab` | Focus next terminal |
| `Ctrl+Shift+R` | Rename the terminal |
| `Ctrl+Shift+W` | Kill the terminal |
| `Ctrl+=` / `Ctrl+-` / `Ctrl+0` | Terminal font zoom in / out / reset |

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
