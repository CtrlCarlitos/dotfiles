#!/usr/bin/env bash
set -euo pipefail

# Codex hook normalization contract (dotfiles #170): graft's own host-writer
# emits ~/.codex/hooks.json entries with backslash Windows paths and no
# commandWindows. The Codex TUI on Windows spawns hook commands through git
# bash, which eats the backslashes - every graft hook event dies with
# "Cannot find module 'C:\Users\Userscarlitos.codex...'". Forward-slash
# Windows paths work in cmd.exe, PowerShell AND git bash (measured 2026-09-26),
# so scripts/update_ai_tools.ps1 normalizes the spelling after every
# `graft upgrade`. The normalizer must stay surgical: only entries that have
# backslashes AND no commandWindows are rewritten, so guardrail's own Codex
# hooks (which carry a commandWindows twin) are never touched, and the file
# is only rewritten when something actually changed.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_updater="$repo_root/scripts/update_ai_tools.ps1"
sh_updater="$repo_root/scripts/update_ai_tools.sh"

. "$repo_root/tests/lib.sh"

# 1. The Windows updater normalizes after graft upgrade (the same command
#    whose regeneration brings the backslash form back - graft init/upgrade
#    rewrites hooks.json, so the fix must re-run on the same cadence).
require "$ps1_updater" 'graft upgrade'
require "$ps1_updater" 'Normalized Codex hook paths to forward slashes'
require "$ps1_updater" '.codex\hooks.json'

# 2. Surgical: only backslash paths WITHOUT a commandWindows twin are
#    rewritten. Guardrail's Codex hook entries carry a commandWindows
#    EncodedCommand - this guard is what keeps them untouched.
require "$ps1_updater" "-not \$hook.commandWindows"

# 3. The forward-slash rewrite is the only mutation; the file is written
#    BOM-less like every other JSON writer in this repo.
require "$ps1_updater" 'hook.command -replace'
require "$ps1_updater" 'New-Object System.Text.UTF8Encoding($false)'

# 4. Twin accounting (invariant #10): the Unix updater carries no
#    normalization block - graft writes the native separator there, so the
#    Windows-only fix is proven, not forgotten - but it must SAY so, so the
#    asymmetry reads as a decision.
require "$sh_updater" 'No Codex hook-path normalization here'

finish
