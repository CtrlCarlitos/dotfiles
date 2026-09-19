# VS Code global settings & extensions

Repo-curated machine baseline + per-machine drift, applied by the package
installers on every `chezmoi apply` (gated by `vscode_settings` — set
`vscode_settings = false` in chezmoi.toml to opt out wholesale).

## Where things live

| What | Home |
|---|---|
| Extension baseline (24 curated) | `.chezmoidata.yaml` → `vscode.extensions` (+ `extensions_windows`) |
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
| FORCED | editor/terminal font (MesloLGS NF) | re-asserted | exclude to stop |
| UPSERT | ~15 curated defaults | only written when absent | your value wins |
| MERGE | files.exclude / search.exclude junk dirs | only missing sub-keys added | your entries stay |

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
  parsed tolerantly by both twins; malformed files are never clobbered.
- Projects keep full authority: their `.vscode/settings.json` layers on top
  of these machine globals.
