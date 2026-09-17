#!/usr/bin/env bash
set -euo pipefail

# Guardrail plane-lifecycle contract (agent-guardrails v0.19.2+ / dotfiles):
#   - packages.guardrail is a single opt-in desired-state flag:
#       true  = ensure binary at the pinned version, then plane enable --all
#       false = never download; plane disable --all only if a binary exists
#   - Unix: lifecycle is guardrail-owned (update + plane enable/disable);
#     no direct gen-config calls, output streams (WebAuthn approval URL).
#   - Windows: no plane/update commands (plane exits 2 there; update can't
#     rename a running exe). Keeps the curl download + gen-config --merge path,
#     gated on the same flag.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sh_installer="$repo_root/run_onchange_install_packages.sh.tmpl"
sh_updater="$repo_root/scripts/update_ai_tools.sh"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
ps1_updater="$repo_root/scripts/update_ai_tools.ps1"
ci_workflow="$repo_root/.github/workflows/ci.yml"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

require() { # $1 = file, $2 = literal
    grep -Fq -- "$2" "$1" || fail "$1: missing $2"
}

forbid() { # $1 = file, $2 = literal
    ! grep -Fq -- "$2" "$1" || fail "$1: must not contain $2"
}

# --- Unix installer: desired-state flag drives guardrail-owned lifecycle -----

# The template renders the flag into the script (unconditional call sites).
require "$sh_installer" 'GUARDRAIL_ENABLED="{{ $guardrail }}"'
require "$sh_installer" 'plane enable --all'
require "$sh_installer" 'plane disable --all'
require "$sh_installer" 'update "$ver"'
# gen-config wiring is guardrail's job now (plane enable regenerates the floor).
forbid "$sh_installer" 'gen-config'

# --- Unix manual updater: same lifecycle, flag read from chezmoi config ------

require "$sh_updater" 'chezmoi/chezmoi.toml'
require "$sh_updater" '[data.packages]'
require "$sh_updater" 'plane enable --all'
require "$sh_updater" 'plane disable --all'
require "$sh_updater" 'update "$GUARDRAIL_VERSION"'
forbid "$sh_updater" 'gen-config'

# --- Windows: curl + gen-config kept, plane/update never invoked -------------

for file in "$ps1_installer" "$ps1_updater"; do
    require "$file" 'gen-config'
    forbid "$file" 'plane enable --all'
    forbid "$file" 'plane disable --all'
    forbid "$file" 'guardrail update'
done

# The Windows manual updater skips every guardrail step when the flag is false.
require "$ps1_updater" 'chezmoi.toml'
require "$ps1_updater" '[data.packages]'

grep -Fq -- 'bash tests/guardrail_lifecycle_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: guardrail lifecycle contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: guardrail plane lifecycle contract\n'
