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

. "$repo_root/tests/lib.sh"

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
if [ -n "$gate_line" ] && [ -n "$first_work" ] && [ "$gate_line" -lt "$first_work" ]; then :; else
    fail "installer: gate (line ${gate_line:-?}) must precede all work (first work at ${first_work:-?})"
fi

grep -Fqi 'administrator' "$docs" || fail "docs/windows.md: elevation requirement not documented"

# --- EXECUTED (v2, #135): the gate actually refuses, before any work ----------
# The gate is Windows-only .NET ([Security.Principal.WindowsPrincipal]), so the
# execution runs on a Windows host only (silently: the greps above remain the
# CI's contract). The rendered preamble - elevation gate + single-flight mutex
# - is extracted and run: a non-admin run must exit 1, say why, and never
# acquire the single-flight mutex.
if command -v pwsh >/dev/null 2>&1 && command -v chezmoi >/dev/null 2>&1; then
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32)
            etmp="$(mktemp -d)"
            trap '[ -n "${KEEP_TMP:-}" ] || rm -rf "$etmp"' EXIT
            rendered="$etmp/installer.ps1"
            render_to "$rendered" ps1 '{}'
            if [ -s "$rendered" ]; then
                gate_start="$(grep -nF 'if (-not $__isAdmin) {' "$rendered" | head -1 | cut -d: -f1)"
                gate_end="$(grep -nF '$__dotupMutex = New-Object' "$rendered" | head -1 | cut -d: -f1)"
                gate_end="$(awk -v s="$gate_end" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
                if [ -n "$gate_start" ] && [ -n "$gate_end" ]; then
                    fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
                    cat >"$fixture" <<'PSEOF'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
Invoke-Expression (Slice $lines $start $end)
Write-Host "GATE-PASSED-AND-RAN"
PSEOF
                    gate_log="$etmp/run.log"
                    rc=0
                    pwsh -NoProfile -File "$fixture" "$rendered" "$gate_start" "$gate_end" >"$gate_log" 2>&1 || rc=$?
                    if [ "$rc" -eq 1 ] && grep -Fq 'This installer requires an elevated PowerShell' "$gate_log"; then
                        if grep -Fq 'Another dotfiles installer instance is running' "$gate_log"; then
                            fail "the elevation gate must refuse BEFORE the single-flight mutex"
                        else
                            pass
                        fi
                    elif grep -Fq 'GATE-PASSED-AND-RAN' "$gate_log"; then
                        fail "the elevation gate let a NON-admin run through - the gate is broken"
                    else
                        fail "elevation gate execution behaved unexpectedly (rc=$rc): $(cat "$gate_log")"
                    fi
                    rm -f "$fixture"
                else
                    fail "rendered installer: elevation gate preamble not found"
                fi
            fi
            ;;
        *)
            : # Linux CI: the gate's types do not exist here; greps above are the contract.
            ;;
    esac
fi

finish
