#!/usr/bin/env bash
set -euo pipefail

# MCP autowire contract: graft + serena must load into EVERY plane's fresh
# session with zero ritual. Survey (2026-09-20, live): claude and codex
# already automagic via user-scope config; opencode only reads the mcp block
# of its GLOBAL config (graft was absent). agy is the #175 correction
# (2026-09-28, live): agy marks every server's tools lazy, lazy tools are
# only reachable through the generic call_mcp_tool invoker guardrail denies,
# and a plugin bundle prefixes server names into forms guardrail's registry
# does not know - so the servers are declared in the TOP-LEVEL
# mcp_config.json with forceAllToolsEager, under unprefixed names. The old
# `agy mcp add` (writes the deferred file) must not return, and the
# dotfiles-mcp plugin bundle is retired by the installer.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

# 1. opencode: graft added to the GLOBAL mcp block, both twins (the serena
#    merge already proves the merge-not-clobber pattern lives there).
# The server table lives in .chezmoidata/agents.yaml (#83): both twins must
# render it, and the catalog must still define graft's MCP entry.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '.agents.mcp' "$f" ||
        fail "$f: no MCP wiring from the agent catalog (.chezmoidata/agents.yaml)"
done
grep -Fq 'command: graft' "$repo_root/.chezmoidata/agents.yaml" ||
    fail ".chezmoidata/agents.yaml: graft MCP server entry missing"
# The registration CONVERGES (a stale `npx -y` entry is repaired, #230); what it
# does is asserted by executing it: tests/opencode_mcp_sync_contract.sh.
grep -Fq 'function Sync-OpenCodeMcp' "$ps1_installer" ||
    fail "$ps1_installer: no registration step for opencode global (Sync-OpenCodeMcp)"
grep -Fq 'opencode_mcp_sync()' "$sh_installer" ||
    fail "$sh_installer: no registration step for opencode global (opencode_mcp_sync)"

# 2. agy: TOP-LEVEL mcp_config.json with forceAllToolsEager, both twins
#    (#175). The dotfiles-mcp plugin bundle is retired (plugin-prefixed
#    server names are unknown to guardrail; cross-source doubles);
#    `agy mcp add` stays banned.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq 'forceAllToolsEager' "$f" ||
        fail "$f: agy MCP servers must be declared forceAllToolsEager (#175)"
    grep -Fq 'dotfiles-mcp' "$f" ||
        fail "$f: no retirement of the old dotfiles-mcp plugin bundle"
    ! grep -Fq 'plugin.json' "$f" ||
        fail "$f: must not write a plugin bundle any more (the global mcp_config.json is the source)"
    ! grep -Fq 'agy mcp add' "$f" ||
        fail "$f: agy mcp add is superseded by the forceAllToolsEager registration (deferred path)"
done

# 3. The catalog carries both servers with the live-verified commands.
#    graft is the installed binary now (#175: with the npx -y form agy
#    exposed zero graft tools - slow npx cold start), not the npx form.
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq 'args: [start-mcp-server, --context, ide-assistant]' "$repo_root/.chezmoidata/agents.yaml" ||
        fail ".chezmoidata/agents.yaml: serena MCP command changed from the live-verified form"
    grep -Fq 'args: [mcp]' "$repo_root/.chezmoidata/agents.yaml" ||
        fail ".chezmoidata/agents.yaml: graft MCP must be the installed binary (graft mcp), not npx (#175)"
done

# 4. The global mcp_config.json is NEVER deleted: guardrail's
#    `doctor --coverage antigravity` (the `guardrail setup` gate) fails hard
#    on an absent or 0-byte file (agent-guardrails#334), so an emptied file
#    keeps `"mcpServers": {}` and every run repairs an absent/0-byte one to
#    that same shape. The registration is a merge: user-added servers
#    survive.
! grep -Fq 'Remove-Item $agyGlobalMcp' "$ps1_installer" ||
    fail "$ps1_installer: must not delete the global mcp_config.json (agent-guardrails#334)"
! grep -Fq 'os.remove(p)' "$sh_installer" ||
    fail "$sh_installer: must not delete the global mcp_config.json (agent-guardrails#334)"
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '"mcpServers": {}' "$f" ||
        fail "$f: must leave/repair the global mcp_config.json as an empty mcpServers object"
done
grep -Fq -- '-not (Test-Path $agyGlobalMcp) -or (Get-Item $agyGlobalMcp).Length -eq 0' "$ps1_installer" ||
    fail "$ps1_installer: no absent/0-byte repair of the global mcp_config.json"
grep -Fq -- '! -s "$AGY_GLOBAL_MCP"' "$sh_installer" ||
    fail "$sh_installer: no absent/0-byte repair of the global mcp_config.json"

finish
