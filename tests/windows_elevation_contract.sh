#!/usr/bin/env bash
set -euo pipefail

# Windows elevation-gate contract: the chezmoi installer must refuse to run
# degraded. Confirmed live: a non-admin `dotup` "succeeded" with warnings,
# chezmoi recorded the run_onchange hash, and the follow-up elevated dotup
# never fired - the admin-requiring work (Chocolatey, OpenSSH capability,
# winget Build Tools, graft native builds) stayed permanently skipped. The
# gate exits 1 before any work; chezmoi doesn't record failed scripts, so
# the next elevated dotup re-fires with admin steps intact.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repo_root/run_onchange_install_packages.ps1.tmpl"
docs="$repo_root/docs/windows.md"
ci_workflow="$repo_root/.github/workflows/ci.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

grep -Fq 'WindowsBuiltInRole]::Administrator' "$installer" ||
    fail "installer: no elevation check"
# The gate must exit non-zero (chezmoi skips recording failed scripts -
# that's the whole mechanism).
grep -Fq 'exit 1' "$installer" || fail "installer: gate does not exit non-zero"

# Gate must precede all installer work (Write-Host beyond the gate's own
# messages, choco/npm/Invoke-* steps). awk-only: no head/grep pipelines
# that can SIGPIPE under pipefail.
gate_line=$(grep -n 'Hard elevation gate' "$installer" | cut -d: -f1)
first_work=$(awk '
    /Hard elevation gate/ { gate = NR }
    # gate message lines: the block between marker and its closing brace
    gate && /^\}/ { gate_done = NR }
    gate_done && NR > gate_done && (/Write-Host/ || /choco / || /npm / || /Invoke-/) { print NR; exit }
' "$installer")
[ -n "$gate_line" ] && [ -n "$first_work" ] && [ "$gate_line" -lt "$first_work" ] ||
    fail "installer: gate (line ${gate_line:-?}) must precede all work (first work at ${first_work:-?})"

grep -Fqi 'administrator' "$docs" || fail "docs/windows.md: elevation requirement not documented"

grep -Fq -- 'bash tests/windows_elevation_contract.sh' "$ci_workflow" || {
    printf 'FAIL: ci.yml: elevation contract is not a PR CI check\n' >&2
    exit 1
}

printf 'PASS: Windows installer elevation gate contract\n'
