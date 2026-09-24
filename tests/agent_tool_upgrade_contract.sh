#!/usr/bin/env bash
set -euo pipefail

# Agent-tool upgrade contract, v2 (dot CLI era): `dot upgrade` is the ONLY
# upgrader. The AI section (scripts/update_ai_tools.*) carries defer hooks
# around every dir-recreating upgrade (npm -g / uv tool / choco opencode)
# so live agent sessions are never raced - the flaw that made the original
# in-installer upgrades (2026-09-20) record-a-hash-and-never-retry. The
# guardrail.exe Defender exclusion (agent-guardrails #132/#146) belongs to
# the agent-guardrails installer, never the dotfiles. CLI structure lives in
# tests/dot_cli_contract.sh; this file pins the upgrade semantics.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ps1_updater="$ai_ps1"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

forbid() { # $1 = file, $2 = literal
    ! grep -Fq -- "$2" "$1" || fail "$1: must not contain $2"
}

# 1. Every dir-recreating upgrade in the AI section is defer-aware.
for tool in codex graft serena; do
    grep -Fq "DOTUPGRADE_DEFER" "$ai_ps1" || fail "$ai_ps1: no defer hooks"
    grep -Fq "DOTUPGRADE_DEFER" "$ai_sh" || fail "$ai_sh: no defer hooks"
done
# codex upgrades to pinned-latest, not floating npm update semantics
# The package name comes from .chezmoidata/agents.yaml at runtime (#83); the
# @latest suffix is what makes it an upgrade rather than a floating update.
grep -Fq '.agents.npm.codex' "$ai_ps1" ||
    fail "$ai_ps1: codex package name must be read from the agent catalog"
grep -Fq '@latest"' "$ai_ps1" ||
    fail "$ai_ps1: codex must upgrade via @latest"
grep -Fq 'graft upgrade' "$ai_ps1" ||
    fail "$ai_ps1: graft must use its own self-updater"
grep -Fq 'graft upgrade' "$ai_sh" ||
    fail "$ai_sh: graft must use its own self-updater"

# 2. The agent-guardrails installer owns the Defender exclusion (#132/#146);
#    the dotfiles never touch Defender.
forbid "$ps1_installer" 'Add-MpPreference'
forbid "$ps1_updater" 'Add-MpPreference'

printf 'PASS: agent tool upgrade contracts\n'
