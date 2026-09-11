# guardrail install strategy

_Added 2026-09-04 with Plan 3b of the agent-guardrails project._

## TL;DR

- `install_guardrail` toggle (default true), separate from `install_ai_tools`
  because it modifies `~/.claude/settings.json` hooks, not just drops files.
- Downloads the **pinned** `CtrlCarlitos/agent-guardrails` release
  (`GUARDRAIL_VERSION` — check the templates for the current pin; it moves
  often) — no "latest", per DESIGN.md Q16.
- **Checksum-verified** against the release `SHA256SUMS` before install. First
  asset-checksum check in this repo; never installs an unverified binary.
- Installs to `~/.local/bin/guardrail` (Linux/mac/WSL) /
  `%USERPROFILE%\.local\bin\guardrail.exe` (Windows, `Unblock-File`d, User PATH
  persisted).
- Wires Claude via `guardrail gen-config claude --merge ~/.claude/settings.json
  --binary <abs path>`. The merge is marker-based (guardrail-owned hook groups
  carry `"id": "guardrail-claude-*"`) so re-runs and version bumps rebind rather
  than fork — see agent-guardrails ADR-0004.
- Wires all three planes it supports today: Claude (`settings.json` hooks +
  permissions), OpenCode (`opencode.json` permission block + the embedded
  plugin), Antigravity (global `hooks.json`, no declarative floor — see
  agent-guardrails ADR-0008). Each plane's wiring is independently guarded on
  that tool being present.
- Idempotent: download skipped when `guardrail version` already matches; gen-config
  always re-run (safe).

## Bumping the version

1. Tag a new `agent-guardrails` release (CI publishes the binaries + SHA256SUMS).
2. Update `GUARDRAIL_VERSION` in `run_onchange_install_packages.sh.tmpl`,
   `run_onchange_install_packages.ps1.tmpl`, `scripts/update_ai_tools.sh`,
   `scripts/update_ai_tools.ps1` (they are not templated from one source).
3. Commit → `chezmoi apply` re-fires the `run_onchange` script.

## Not done / open

- A dedicated `guardrail` uninstall path.

## Caveats

- **Anonymous downloads 404** while the agent-guardrails repo is private — the
  installer warn-skips until the repo goes public (or downloads move to
  authenticated `gh` fetches).
- **First install on an existing machine needs `chezmoi init`** so the new
  `install_guardrail` config key is prompted into the live config; until then
  `chezmoi diff`/`apply` fail with `map has no entry for key`.
