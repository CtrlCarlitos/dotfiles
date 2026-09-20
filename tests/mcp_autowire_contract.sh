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
for f in "$ps1_installer" "$sh_installer"; do
    grep -Fq '@nanonets/graft' "$f" ||
        fail "$f: no graft MCP wiring (opencode global block missing graft)"
done
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
    grep -Fq 'start-mcp-server' "$f" || fail "$f: bundle missing serena"
    grep -Fq '"-y"' "$f" || fail "$f: bundle missing graft npx -y form"
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
