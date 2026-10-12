#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# One `dot upgrade` asked winget for its upgrade listing again and again (2026-10-12: 6.4 s in the
# session scan, a by-id query each for Docker Desktop, VS Code and Claude Desktop, another full
# listing after a sweep that had just said "nothing to upgrade"), and `winget list --id` told it whether
# Docker Desktop was installed at all. Executed here against a fake winget that counts its calls:
#   - the scan's listing is kept for five minutes and answers the later probes - none starts a query of
#     its own while it is fresh; a stale one is not trusted;
#   - Docker Desktop's owner comes from Windows' installed-apps list before winget is asked;
#   - a sweep that installed nothing and printed winget's "No installed package found" is not followed
#     by a second listing; a sweep that installed something is.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

lib="$repo_root/scripts/lib/ps-common.ps1"
grep -Fq 'function Get-WingetUpgradeListing' "$lib" || fail "ps-common.ps1 must keep one winget upgrade listing (Get-WingetUpgradeListing)"
grep -Fq 'function Get-InstalledDisplayName' "$lib" || fail "ps-common.ps1 must read Docker Desktop's ownership from the installed-apps list"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Log)
Set-StrictMode -Version Latest
. $Lib
$script:calls = New-Object System.Collections.Generic.List[string]
$script:sweepOut = @('No installed package found matching input criteria.')
$table = @(
    'Name                Id                         Version   Available Source',
    '--------------------------------------------------------------------------',
    'Docker Desktop      Docker.DockerDesktop       4.93.0    4.94.0    winget',
    'Visual Studio Code  Microsoft.VisualStudioCode 1.140.0   1.141.0   winget',
    '2 upgrades available.')
function winget {
    $script:calls.Add(($args -join ' '))
    $global:LASTEXITCODE = 0
    if ($args[0] -eq 'upgrade' -and $args[1] -eq '--include-unknown') { $table; return }
    if ($args[0] -eq 'upgrade' -and $args[1] -eq '--all') { $script:sweepOut; return }
    if ($args[0] -eq 'upgrade' -and $args[1] -eq '--id') { $wanted = [regex]::Escape($args[2]); $table | Where-Object { $_ -match $wanted }; return }
    if ($args[0] -eq 'pin') { return }
}
function Count([string]$Pattern) { @($script:calls | Where-Object { $_ -match $Pattern }).Count }
function Out($label, $value) { Write-Output ("$label=$value") }

# the scan's listing, then the probes that used to run their own queries
$ids = Get-WingetPendingId
Out 'scan-ids' (@($ids) -join ',')
$before = $script:calls.Count
Out 'vscode' (Get-WingetPackageUpgrade -Id 'Microsoft.VisualStudioCode')
Out 'docker' (Get-DockerDesktopUpgrade -Owner 'winget')
Out 'claude-none' ('[' + (Get-WingetPackageUpgrade -Id 'Anthropic.Claude') + ']')
$null = Get-WingetPendingId
Out 'extra-calls' ($script:calls.Count - $before)
Out 'listings' (Count '^upgrade --include-unknown')

# a listing older than five minutes is not trusted: the by-id query runs
$script:WingetUpgradeListing.At = [DateTime]::UtcNow.AddMinutes(-10)
$script:calls.Clear()
Out 'stale-vscode' (Get-WingetPackageUpgrade -Id 'Microsoft.VisualStudioCode')
Out 'stale-by-id-queries' (Count '^upgrade --id')

# no listing yet: Docker's owner from the installed-apps list, the upgrade from a by-id query
$script:WingetUpgradeListing = $null
$script:calls.Clear()
Out 'docker-cold' (Get-DockerDesktopUpgrade -Owner 'winget')
Out 'cold-by-id-queries' (Count '^upgrade --id')

# the sweep: "nothing to upgrade" is believed; an install is followed by a listing
$null = Get-WingetPendingId
$script:calls.Clear()
$sweep = (Invoke-WingetUpgradeAll -LogPath $Log *>&1 | Out-String)
Out 'sweep-said-nothing' ($sweep -match 'Nothing to upgrade in winget')
Out 'sweep-listings-after-nothing' (Count '^upgrade --include-unknown')
Out 'kept-listing-cleared' ($null -eq (Get-WingetKeptUpgrade -Id 'Microsoft.VisualStudioCode'))
$script:sweepOut = @('Found Docker Desktop [Docker.DockerDesktop] Version 4.94.0', 'Successfully installed')
$script:calls.Clear()
$null = Invoke-WingetUpgradeAll -LogPath $Log
Out 'sweep-listings-after-install' (Count '^upgrade --include-unknown')
$script:sweepOut = @('1 package(s) have upgrades blocked by a pin.')
$script:calls.Clear()
$null = Invoke-WingetUpgradeAll -LogPath $Log
Out 'sweep-listings-after-blocked' (Count '^upgrade --include-unknown')
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$lib")" -Log "$(winpath "$tmp/upgrade.log")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() {
    if printf '%s\n' "$out" | grep -Fxq "$1"; then pass; else fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))"; fi
}
expect 'scan-ids=Docker.DockerDesktop,Microsoft.VisualStudioCode'
expect 'vscode=1.141.0'
expect 'docker=4.94.0'
expect 'claude-none=[]'
expect 'extra-calls=0'
expect 'listings=1'
expect 'stale-vscode=1.141.0'
expect 'stale-by-id-queries=1'
expect 'docker-cold=4.94.0'
expect 'cold-by-id-queries=1'
expect 'sweep-said-nothing=True'
expect 'sweep-listings-after-nothing=0'
expect 'kept-listing-cleared=True'
expect 'sweep-listings-after-install=1'
expect 'sweep-listings-after-blocked=1'

finish
