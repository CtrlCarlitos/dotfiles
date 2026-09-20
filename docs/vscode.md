# VS Code global settings & extensions

Repo-curated machine baseline + per-machine drift, applied by the package
installers on every `chezmoi apply`. Opt out wholesale with:

```toml
[data.packages]
vscode_settings = false
```

## Where things live

| What | Home |
|---|---|
| Extension baseline (24 curated) | `.chezmoidata.yaml` → `vscode.extensions` (+ `extensions_windows`) |
| Whole-feature gate | `~/.config/chezmoi/chezmoi.toml` → `[data.packages]` → `vscode_settings` |
| Settings baseline (forced/upsert/merge tiers) | embedded in both installer templates |
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
| UPSERT | ~15 curated defaults | only written when absent | your value wins |
| MERGE | files.exclude / search.exclude junk dirs | only missing sub-keys added | your entries stay |

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
deep-merge into an existing object. (Deep-merge exists only for the two
MERGE-tier keys, `files.exclude`/`search.exclude`, and only for the baseline
junk entries.) If you need to merge into an existing object setting, set it
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
