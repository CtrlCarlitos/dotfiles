#!/usr/bin/env bash
set -euo pipefail

# Live `dot upgrade --yes` (2026-10-11): Claude Desktop was held out of the winget sweep with
# "a claude.exe is running" on a run where Claude Desktop was never open at all - the check
# was `Get-Process claude`, which also counts the very Claude Code session running THIS
# `dot upgrade` command. Every run from a Claude Code session held Claude Desktop out
# regardless of whether it (or any other session) was actually running. Fixed by excluding
# $ancestorIds (this shell's own ancestry, already computed at the top of the script and used
# by the live-session scan above) from the check, same rule that scan already applies.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

du="$repo_root/scripts/dotupgrade.ps1"
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

grep -Fq '@(Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $ancestorIds -notcontains $_.Id })' "$du" ||
    fail "dotupgrade.ps1: the Claude Desktop winget-hold check must exclude this shell's own ancestry (\$ancestorIds)"
pass

if command -v pwsh >/dev/null 2>&1; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    snippet="$(grep -n 'if (@(Get-Process claude -ErrorAction SilentlyContinue' "$du" | head -1 | cut -d: -f1)"
    [ -n "$snippet" ] || fail "dotupgrade.ps1: Claude Desktop winget-hold check not found"
    sed -n "${snippet},$((snippet + 3))p" "$du" >"$tmp/snippet.ps1"
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$SnippetPath)
Set-StrictMode -Version Latest
$snippet = Get-Content -Raw $SnippetPath
$script:fakeClaude = @()
function Get-Process {
    param($Name, [switch]$ErrorAction)
    if ($Name -eq 'claude') { return $script:fakeClaude }
    return @()
}
$cases = @(
    @{ Label = 'ancestor-only'; Procs = @(@{ Id = 100 }); Ancestor = @(100) }
    @{ Label = 'other-running'; Procs = @(@{ Id = 100 }, @{ Id = 999 }); Ancestor = @(100) }
    @{ Label = 'none-running'; Procs = @(); Ancestor = @(100) }
)
foreach ($case in $cases) {
    $script:fakeClaude = @($case.Procs | ForEach-Object { [pscustomobject]$_ })
    $ancestorIds = @($case.Ancestor)
    $wingetHold = @()
    Invoke-Expression $snippet
    Write-Output ("$($case.Label)=" + ($wingetHold -join ','))
}
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -SnippetPath "$(winpath "$tmp/snippet.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'ancestor-only='
    expect 'other-running=Anthropic.Claude'
    expect 'none-running='
    pass
else
    printf 'note: pwsh not installed - executed checks skipped\n'
fi

finish
