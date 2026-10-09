#!/usr/bin/env bash
set -euo pipefail

# Codex MCP registration contract: `serena setup codex` must run AFTER the
# Codex CLI install in BOTH installer twins. The registration used to live in the serena section, which runs
# before the install: on a machine where codex is absent until that very run
# (fresh setup, or a deliberate removal + reinstall) the early call skipped
# and codex stayed MCP-less forever (observed live 2026-09-29, codex 0.159.0
# reinstalled by the same run that skipped its registration).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
sh_tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

. "$repo_root/tests/lib.sh"

order_check() { # $1 = file, $2 = install marker, $3 = twin label
    grep -Fq 'serena setup codex' "$1" || fail "$1: serena setup codex missing"
    # Graft was dropped (2026-10-09): nothing registers it for Codex any more.
    ! grep -Fq 'codex mcp add graft' "$1" || fail "$1: graft must no longer be registered for codex"
    local count install_line setup_line
    count=$(grep -cF 'serena setup codex' "$1")
    [ "$count" -eq 1 ] || fail "$3: serena setup codex must appear on exactly one line (the early skip is the bug); got $count"
    install_line=$(grep -nF "$2" "$1" | head -1 | cut -d: -f1)
    setup_line=$(grep -nF 'serena setup codex' "$1" | head -1 | cut -d: -f1)
    [ -n "$install_line" ] || fail "$3: install marker '$2' not found"
    [ "$setup_line" -gt "$install_line" ] ||
        fail "$3: serena setup codex (line $setup_line) must come after the Codex CLI install (line $install_line)"
}

order_check "$ps1_tmpl" 'Installing Codex CLI' 'ps1 twin'
order_check "$sh_tmpl" 'Installing Codex CLI...' 'sh twin'

finish
