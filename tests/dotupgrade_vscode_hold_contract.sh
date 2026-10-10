#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Found in a live `dot upgrade` (2026-10-09): VS Code 1.141.0 failed with `Installer failed with
# exit code: 1` because VS Code was running (the installer log says "Setup has detected that
# Visual Studio Code is currently running"), and the summary said only "Still pending". Now, like
# Docker Desktop: when VS Code is running and an upgrade is pending, the operator is offered to
# close it; otherwise the sweep holds VS Code out and the summary says why. The functions are
# EXECUTED against a fake winget and a fake process table.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib

# ---- the pending probe ------------------------------------------------------------------------
$script:wingetLines = @()
function winget { $script:wingetLines | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
$script:wingetLines = @(
    'Name                         Id                         Version Available Source',
    '--------------------------------------------------------------------------------',
    'Microsoft Visual Studio Code Microsoft.VisualStudioCode 1.140.0 1.141.0   winget',
    '1 upgrades available.'
)
Write-Output ('probe-pending=' + (Get-WingetPackageUpgrade -Id 'Microsoft.VisualStudioCode'))
$script:wingetLines = @('No installed package found matching input criteria.')
Write-Output ('probe-none=[' + (Get-WingetPackageUpgrade -Id 'Microsoft.VisualStudioCode') + ']')

# ---- the offer ----------------------------------------------------------------------------------
$script:vsProcs = @()
$script:vsStubborn = $false
$script:events = @()
function New-VsProc([int]$Id) {
    $p = [pscustomobject]@{ ProcessName = 'Code'; Id = $Id }
    $p | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value {
        $script:events += "vscode:close:$($this.Id)"
        if (-not $script:vsStubborn) { $script:vsProcs = @($script:vsProcs | Where-Object { $_.Id -ne $this.Id }) }
        return $true
    }
    return $p
}
function Get-Process {
    param([Parameter(Position = 0)][string[]]$Name, [int[]]$Id)
    if ($Id) { return @($script:vsProcs | Where-Object { $Id -contains $_.Id }) }
    return @($script:vsProcs | Where-Object { $Name -contains $_.ProcessName })
}
function Stop-AgentProcess {
    param($Process, [int]$GraceSeconds)
    $script:events += "kill:$($Process.Id)"
    $script:vsProcs = @($script:vsProcs | Where-Object { $_.Id -ne $Process.Id })
    return $true
}
$script:interactive = $true
$script:answer = 'n'
$script:prompts = 0
function Test-InteractiveConsole { return $script:interactive }
function Read-Host { param([string]$Prompt) $script:prompts++; return $script:answer }

function Offer([int[]]$Exclude = @()) {
    $script:prompts = 0; $script:events = @()
    $script:out = (& { $script:r = Invoke-VsCodeUpgradeOffer -Version '1.141.0' -ExcludeId $Exclude -GraceSeconds 1 } *>&1 | Out-String)
}
function Fresh { $script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002)) }

$script:vsProcs = @()
Offer
Write-Output ("not-running=$($script:r)|prompts=$($script:prompts)")

Fresh; $script:answer = 'y'
$env:DOTUPGRADE_NO_PROMPT = '1'
Offer
Remove-Item Env:DOTUPGRADE_NO_PROMPT
Write-Output ("no-prompt=$($script:r)|prompts=$($script:prompts)|events=$($script:events -join ',')|says=" + ($script:out -match 'left for the next run'))

Fresh; $script:interactive = $false
Offer
Write-Output ("non-interactive=$($script:r)|prompts=$($script:prompts)|events=$($script:events -join ',')")
$script:interactive = $true

Fresh; $script:answer = 'n'
Offer
Write-Output ("declined=$($script:r)|prompts=$($script:prompts)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")
Fresh; $script:answer = ''
Offer
Write-Output ("default-is-no=$($script:r)|events=$($script:events -join ',')")

Fresh; $script:answer = 'y'
Offer
Write-Output ("accepted=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)|says=" + ($script:out -match 'VS Code closed for the upgrade'))

# --yes answers without asking
Fresh; $script:DotAnswerYes = $true; $script:answer = 'n'
Offer
Remove-Variable -Name DotAnswerYes -Scope Script
Write-Output ("yes-flag=$($script:r)|prompts=$($script:prompts)|left=$(@($script:vsProcs).Count)")

# a VS Code that ignores the close request is ended after the grace period
Fresh; $script:answer = 'y'; $script:vsStubborn = $true
Offer
$script:vsStubborn = $false
Write-Output ("stubborn=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")

# VS Code hosts this terminal (7001 is an ancestor): never closed, upgrade waits - even with --yes
Fresh; $script:answer = 'y'
Offer -Exclude @(7001)
Write-Output ("hosting=$($script:r)|prompts=$($script:prompts)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)|says=" + ($script:out -match 'hosts THIS terminal'))
$script:vsProcs = @((New-VsProc 7001))
Offer -Exclude @(7001)
Write-Output ("only-host=$($script:r)|events=$($script:events -join ',')|says=" + ($script:out -match 'hosts THIS terminal'))
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))"; }

expect 'probe-pending=1.141.0'
expect 'probe-none=[]'
expect 'not-running=True|prompts=0'
expect 'no-prompt=False|prompts=0|events=|says=True'
expect 'non-interactive=False|prompts=0|events='
expect 'declined=False|prompts=1|events=|left=2'
expect 'default-is-no=False|events='
expect 'accepted=True|events=vscode:close:7001,vscode:close:7002|left=0|says=True'
expect 'yes-flag=True|prompts=0|left=0'
expect 'stubborn=True|events=vscode:close:7001,vscode:close:7002,kill:7001,kill:7002|left=0'
expect 'hosting=False|prompts=0|events=|left=2|says=True'
expect 'only-host=False|events=|says=True'
pass

# --- wiring: the offer runs before the winget sweep, and a kept VS Code is held out of it ---
du="$repo_root/scripts/dotupgrade.ps1"
offer_line="$(grep -n 'Invoke-VsCodeUpgradeOffer' "$du" | head -1 | cut -d: -f1)"
sweep_line="$(grep -n 'Invoke-WingetUpgradeAll -RunningNote' "$du" | head -1 | cut -d: -f1)"
if [ -z "$offer_line" ] || [ -z "$sweep_line" ] || [ "$offer_line" -ge "$sweep_line" ]; then
    fail "dotupgrade.ps1 must offer to close VS Code BEFORE the winget sweep"
fi
grep -Fq "wingetHold += 'Microsoft.VisualStudioCode'" "$du" || fail "dotupgrade.ps1 must hold VS Code out of the sweep when it stays running"
grep -Fq 'close it and re-run, or run: winget upgrade Microsoft.VisualStudioCode' "$du" || fail "dotupgrade.ps1 must say why a held VS Code is still pending"
pass

finish
