#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell and template text are literal
set -euo pipefail

# From the 2026-10-07 dot up / dot upgrade logs (Windows):
#   1. `claude plugin update superpowers` failed with "installed from more than one marketplace"
#      (project-local installs from claude-plugins-official / superpowers-dev), silently for
#      weeks: Superpowers sat at 6.4.1 while 6.4.2 was out. Both updaters name the marketplace
#      dotfiles installs from.
#   2. A captured "..." printed as three CP437 characters: dotupgrade.ps1 and
#      update_ai_tools.ps1 decode native output as UTF-8, like the installer.
#   3. A new Playwright browser build printed ~30 progress-bar lines on `dot up`: one line per
#      download now, the whole output only on failure.
#   4. Get-AncestorProcessId ran one WMI query per ancestor (~2 s, asked twice per dot
#      upgrade): one process-table query, walked in memory, cached (EXECUTED, fake table).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

# --- 1-3: wiring ---------------------------------------------------------------------------
grep -Fq 'claude plugin update superpowers@superpowers-marketplace -y' "$repo_root/scripts/update_ai_tools.ps1" ||
    fail "update_ai_tools.ps1: the Superpowers update must name its marketplace"
grep -Fq 'claude plugin update superpowers@superpowers-marketplace -y' "$repo_root/scripts/update_ai_tools.sh" ||
    fail "update_ai_tools.sh: the Superpowers update must name its marketplace"
if grep -Eq 'claude plugin update superpowers( |$)' "$repo_root/scripts/update_ai_tools.ps1" "$repo_root/scripts/update_ai_tools.sh"; then
    fail "an updater still runs the bare 'claude plugin update superpowers' (ambiguous with several marketplaces)"
fi
for f in scripts/dotupgrade.ps1 scripts/update_ai_tools.ps1; do
    grep -Fq '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)' "$repo_root/$f" ||
        fail "$f: native output must be decoded as UTF-8"
done
grep -Fq -- '-Description "Playwright Chromium install" -Seconds 600 -NoStream' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "installer: the Playwright download must be captured (-NoStream), not streamed"
grep -Fq 'Write-Host "    Playwright: $($Matches[1]) downloaded"' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "installer: a Playwright download must be reported as one line"
pass

# --- 4: Get-AncestorProcessId, executed ---------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:queries = 0
$script:rows = @(
    [pscustomobject]@{ ProcessId = $PID; ParentProcessId = 50 },
    [pscustomobject]@{ ProcessId = 50; ParentProcessId = 40 },
    [pscustomobject]@{ ProcessId = 40; ParentProcessId = 4 },
    [pscustomobject]@{ ProcessId = 60; ParentProcessId = 50 },
    [pscustomobject]@{ ProcessId = 70; ParentProcessId = 60 }
)
function Get-CimInstance { $script:queries++; $script:rows }
Write-Output ('ancestors=' + ((@(Get-AncestorProcessId) | Where-Object { $_ -ne $PID } | Sort-Object) -join ','))
Write-Output ('self-included=' + (@(Get-AncestorProcessId) -contains $PID))
Write-Output ('queries=' + $script:queries)
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300))"; }
    # parent chain only (40, 50 - and 4, which has no row of its own); never a sibling (60, 70)
    expect 'ancestors=4,40,50'
    expect 'self-included=True'
    # one query for the whole walk, and the second call is served from the cache
    expect 'queries=1'
    pass
else
    printf 'note: pwsh not installed - executed check skipped\n'
fi

finish
