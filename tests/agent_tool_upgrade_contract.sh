#!/usr/bin/env bash
set -euo pipefail

# Agent-tool upgrade contract, v2 (dot CLI era): `dot upgrade` is the ONLY
# upgrader. The AI section (scripts/update_ai_tools.*) carries defer hooks
# around every dir-recreating upgrade (npm -g / uv tool / choco opencode)
# so live agent sessions are never raced - the flaw that made the original
# in-installer upgrades (2026-09-20) record-a-hash-and-never-retry. The
# Windows installer additionally excludes guardrail.exe from Defender
# (agent-guardrails #132/#146). CLI structure lives in
# tests/dot_cli_contract.sh; this file pins the upgrade semantics.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
ai_sh="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Every dir-recreating upgrade in the AI section is defer-aware.
for tool in codex graft serena; do
    grep -Fq "DOTUPGRADE_DEFER" "$ai_ps1" || fail "$ai_ps1: no defer hooks"
    grep -Fq "DOTUPGRADE_DEFER" "$ai_sh" || fail "$ai_sh: no defer hooks"
done
# codex upgrades to pinned-latest, not floating npm update semantics
grep -Fq '@openai/codex@latest' "$ai_ps1" ||
    fail "$ai_ps1: codex must upgrade via @latest"
grep -Fq 'graft upgrade' "$ai_ps1" ||
    fail "$ai_ps1: graft must use its own self-updater"
grep -Fq 'graft upgrade' "$ai_sh" ||
    fail "$ai_sh: graft must use its own self-updater"

# 2. Windows twin only: Defender exclusion for guardrail.exe stays in the
#    installer (it pairs with installation, not upgrading).
grep -Fq 'Add-MpPreference -ExclusionPath $guardrailExe' "$ps1_installer" ||
    fail "$ps1_installer: no Defender exclusion for guardrail.exe"
grep -Fq 'Get-MpPreference' "$ps1_installer" ||
    fail "$ps1_installer: Defender exclusion must be idempotent (check first)"
grep -Fq 'Add the Defender exclusion for guardrail.exe' "$ps1_installer" ||
    fail "$ps1_installer: failed exclusion must surface in post-install notes"
grep -Fq '#146' "$ps1_installer" ||
    fail "$ps1_installer: Defender exclusion must document #146 scoping"

printf 'PASS: agent tool upgrade contracts\n'
