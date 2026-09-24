#!/usr/bin/env bash
set -euo pipefail

# MCP autowire contract: graft + serena must load into EVERY plane's fresh
# session with zero ritual. Survey (2026-09-20, live): claude and codex
# already automagic via user-scope config; opencode only reads the mcp block
# of its GLOBAL config (graft was absent); agy defers global mcp_config.json
# entries until /mcp - its own documented fix is a plugin bundle, whose
# servers start eagerly. The installer owns both wirings; the superseded
# `agy mcp add` (writes the deferred file) must not return.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 1. opencode: graft added to the GLOBAL mcp block, both twins (the serena
#    merge already proves the merge-not-clobber pattern lives there).
# The server table lives in .chezmoidata/agents.yaml (#83): both twins must
# render it, and the catalog must still define graft's MCP entry.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '.agents.mcp' "$f" ||
        fail "$f: no MCP wiring from the agent catalog (.chezmoidata/agents.yaml)"
done
grep -Fq '@nanonets/graft' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: graft MCP server entry missing"
grep -Fq 'Registering graft MCP in opencode' "$ps1_installer" ||
    fail "$ps1_installer: no graft registration step for opencode global"
grep -Fq 'Registering MCP in opencode' "$sh_installer" ||
    fail "$sh_installer: no graft-aware registration step for opencode global"

# 2. agy: plugin bundle (eager start), both twins; `agy mcp add` gone.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq 'plugins' "$f" || fail "$f: no agy plugin bundle"
    grep -Fq 'dotfiles-mcp' "$f" || fail "$f: no dotfiles-mcp plugin dir"
    ! grep -Fq 'agy mcp add' "$f" ||
        fail "$f: agy mcp add is superseded by the plugin bundle (deferred path)"
done

# 3. The bundle carries both servers with the exact live-verified commands.
for f in "$ps1_installer" "$sh_installer"; do
    # The exact commands live in .chezmoidata/agents.yaml (#83); the twins render
    # them. Assert the catalog still carries the live-verified forms.
    grep -Fq 'args: [start-mcp-server, --context, ide-assistant]' "$repo_root/.chezmoidata/agents.yaml" ||
        fail ".chezmoidata/agents.yaml: serena MCP command changed from the live-verified form"
    grep -Fq 'args: [-y, "@nanonets/graft", mcp]' "$repo_root/.chezmoidata/agents.yaml" ||
        fail ".chezmoidata/agents.yaml: graft MCP command changed from the live-verified npx -y form"
done

# 4. One-time migration: our keys retire from the old global
#    mcp_config.json - the bundle is the only MCP source this repo owns
#    (cross-source doubles otherwise). Surgical: only serena/graft removed;
#    the file is deleted only when nothing else remains.
grep -Fq 'Remove-Item $agyGlobalMcp' "$ps1_installer" ||
    fail "$ps1_installer: no agy global mcp_config.json retirement"
grep -Fq 'AGY_GLOBAL_MCP' "$sh_installer" ||
    fail "$sh_installer: no agy global mcp_config.json retirement"
grep -Fq 'os.remove(p)' "$sh_installer" ||
    fail "$sh_installer: retirement must delete the file only when empty"

grep -Fq -- 'bash tests/mcp_autowire_contract.sh' "$repo_root/.github/workflows/ci.yml" || {
    printf 'FAIL: ci.yml: MCP autowire contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: MCP autowire contracts\n'
