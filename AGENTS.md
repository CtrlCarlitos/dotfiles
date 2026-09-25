# Agent notes

## Graft covers one file here

Graft is installed and this repo is `graft init`-ed, but the graph covers only
`dot_config/nvim/init.lua` — graft has no parser for the `.sh`, `.ps1`,
`.tmpl`, `.zsh` and `.toml` files that make up everything else. `graft
ask`/`callers`/`skeleton` return nothing useful outside that one Lua file.

## Where context actually lives

- `docs/invariants.md` — the repo's own list of expensive lessons; read it
  before changing templates, ignores or tests.
- The script's own header comment — every script under `scripts/` and each
  `run_*` template opens with what it is for and who calls it.
- The matching `tests/*_contract.sh` — the executable specification of each
  behavior. `bash tests/run.sh` runs the whole suite.

## Searching

Use ripgrep (`rg -n`, narrow with `--glob`) and read the hit at its line
range. `git grep <pattern> <ref>` for anything about a tag or commit that is
not checked out.
