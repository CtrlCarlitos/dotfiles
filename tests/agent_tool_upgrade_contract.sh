#!/usr/bin/env bash
set -euo pipefail

# Agent-tool upgrade contract: dotup must not just install codex/graft/serena
# but UPGRADE them when their package groups are on - the old presence-only
# gates (Get-Command / command -v / $graftWorks) froze them at first-install
# version forever (confirmed live: codex banner 0.154.0 -> 0.155.1 while the
# machine dotup'd daily). The manual one-shot updater (update_ai_tools.*)
# covers the same three tools for on-demand runs.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
update_ps1="$repo_root/scripts/update_ai_tools.ps1"
update_sh="$repo_root/scripts/update_ai_tools.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. Codex: pinned-latest re-install (idempotent no-op when current).
grep -Fq '@openai/codex@latest' "$ps1_installer" ||
    fail "$ps1_installer: no codex upgrade step (@openai/codex@latest)"
grep -Fq '@openai/codex@latest' "$sh_installer" ||
    fail "$sh_installer: no codex upgrade step (@openai/codex@latest)"

# 2. Serena: uv's own upgrade verb, not a re-install of the pinned gate.
grep -Fq 'uv tool upgrade serena-agent' "$ps1_installer" ||
    fail "$ps1_installer: no serena upgrade step (uv tool upgrade)"
grep -Fq 'uv tool upgrade serena-agent' "$sh_installer" ||
    fail "$sh_installer: no serena upgrade step (uv tool upgrade)"

# 3. Graft: a working graft gets re-resolved to latest on every run (the
# npm install re-run carries the tree-sitter allow-scripts allowlist with
# it - the reason this can't just be `npm update`).
grep -Fq 'Upgrading graft' "$ps1_installer" ||
    fail "$ps1_installer: no graft upgrade step"
grep -Fq 'Upgrading graft' "$sh_installer" ||
    fail "$sh_installer: no graft upgrade step"

# 4. The manual one-shot updater covers the same three tools (codex was
# already there; graft + serena must join it).
grep -Fq 'uv tool upgrade serena-agent' "$update_ps1" ||
    fail "update_ai_tools.ps1: serena upgrade missing"
grep -Fq 'uv tool upgrade serena-agent' "$update_sh" ||
    fail "update_ai_tools.sh: serena upgrade missing"
grep -Fq '@nanonets/graft' "$update_ps1" ||
    fail "update_ai_tools.ps1: graft upgrade missing"
grep -Fq '@nanonets/graft' "$update_sh" ||
    fail "update_ai_tools.sh: graft upgrade missing"

# 5. Windows twin only: Defender exclusion for guardrail.exe (agent-guardrails
# #132 - per-spawn scan latency times out the opencode plugin's pre-hook).
grep -Fq 'Add-MpPreference -ExclusionPath $guardrailExe' "$ps1_installer" ||
    fail "$ps1_installer: no Defender exclusion for guardrail.exe"
grep -Fq 'Get-MpPreference' "$ps1_installer" ||
    fail "$ps1_installer: Defender exclusion must be idempotent (check first)"
grep -Fq 'Add the Defender exclusion for guardrail.exe' "$ps1_installer" ||
    fail "$ps1_installer: failed exclusion must surface in post-install notes"

grep -Fq -- 'bash tests/agent_tool_upgrade_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: agent tool upgrade contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: agent tool upgrade + guardrail Defender exclusion contracts\n'
