#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Two silent gaps in the Windows `dot upgrade`, found in a live run:
#   - Docker Desktop 4.94.0 was available and never installed. Its installer cannot replace a
#     running app, winget skipped it without a word, and nothing said so. `dot upgrade` now finds
#     the pending upgrade, offers to stop Docker Desktop (like it offers to stop agent sessions),
#     and leaves it out of the sweep when it stays up.
#   - `winget upgrade --all` printed its raw table with no summary: no way to tell what upgraded,
#     what is still pending, or which package is "blocked". It now ends with what upgraded, what is
#     STILL pending (parsed from a second listing), the blocked note, and keeps the full output in
#     ~\.local\state\dotfiles\upgrade.log like the choco sweep.
# The functions are EXECUTED against fake winget / choco / docker and a fake process table; the
# sample winget text below is the real output from that run.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$LogDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib

# ---- the table parser, on winget's real output ------------------------------------------------
$real = @(
    'Name           Id                   Version       Available     Source',
    '----------------------------------------------------------------------',
    'Docker Desktop Docker.DockerDesktop 4.93.0        4.94.0        winget',
    'Microsoft Edge Microsoft.Edge       154.0.4258.53 154.0.4258.62 winget',
    '2 upgrades available.',
    '1 package(s) have upgrades blocked because newer versions use a different install technology than the current installation. Uninstall each package, then install the newer version.'
)
$rows = @(ConvertFrom-WingetUpgradeTable -Lines $real)
Write-Output ('parse-count=' + $rows.Count)
Write-Output ('parse-first=' + $rows[0].Name + '|' + $rows[0].Id + '|' + $rows[0].Version + '|' + $rows[0].Available + '|' + $rows[0].Source)
Write-Output ('parse-second=' + $rows[1].Name + '|' + $rows[1].Available)
Write-Output ('parse-empty=' + @(ConvertFrom-WingetUpgradeTable -Lines @()).Count)
Write-Output ('parse-none=' + @(ConvertFrom-WingetUpgradeTable -Lines @('No installed package found matching input criteria.', '')).Count)

# ---- the sweep ----------------------------------------------------------------------------------
$script:sweep = @()
$script:listing = @()
$script:sweepExit = 0
function winget {
    if ($args -contains '--all') { $script:sweep | ForEach-Object { $_ }; $global:LASTEXITCODE = $script:sweepExit }
    elseif ($args -contains '--id' -and $script:idProbe.Count -gt 0) { $script:idProbe[[string]$args[([array]::IndexOf($args, '--id') + 1)]] | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
    else { $script:listing | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
}
$script:idProbe = @{}
$log = Join-Path $LogDir 'upgrade.log'
function Run([scriptblock]$Block) { $script:out = (& $Block *>&1 | Out-String) }

$bar = [string][char]0x2588 * 8
$script:sweep = @('Found Docker Desktop [Docker.DockerDesktop] Version 4.94.0', '  -', '  \', "  $bar  50%", '  12.3 MB / 45.6 MB', 'Successfully installed', '')
$script:listing = @('Name Id Version Available Source', '-----', 'No applicable upgrade found.')
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('swept-count=' + ($script:out -match 'winget upgraded 1 package\(s\)'))
Write-Output ('swept-no-pending=' + (-not ($script:out -match 'Still pending')))
Write-Output ('swept-keeps-chatter=' + ($script:out -match 'Found Docker Desktop'))
Write-Output ('swept-hides-noise=' + ((-not ($script:out -match [char]0x2588)) -and (-not ($script:out -match '12\.3 MB'))))
Write-Output ('swept-exit=' + $script:code)

$script:sweep = @('Found Docker Desktop [Docker.DockerDesktop] Version 4.94.0')
$script:listing = $real
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log -RunningNote 'Docker Desktop waits: it is running' }
Write-Output ('pending-names=' + ($script:out -match 'Still pending in winget: Docker Desktop \(4\.93\.0 -> 4\.94\.0\), Microsoft Edge \(154\.0\.4258\.53 -> 154\.0\.4258\.62\)'))
Write-Output ('pending-note=' + ($script:out -match 'Docker Desktop waits: it is running'))
Write-Output ('pending-blocked=' + ($script:out -match '1 package\(s\) have upgrades blocked'))
Write-Output ('pending-no-upgraded-claim=' + (-not ($script:out -match 'winget upgraded')))

# winget lists packages it cannot upgrade; asked by id it says why. Those are not "pending".
$sentence = 'A newer version was found, but the install technology is different from the current version installed. Please uninstall the package and install the newer version.'
$script:idProbe = @{ 'Docker.DockerDesktop' = @($sentence); 'Microsoft.Edge' = @($sentence) }
# Real winget (2026-10-06): the blocked note is printed by the `upgrade --all` SWEEP only; the
# plain listing ends at "2 upgrades available." - so the listing here carries no blocked line.
$listingNoNote = @($real | Where-Object { $_ -notmatch 'have upgrades blocked' })
$script:sweep = @($real)
$script:listing = $listingNoNote
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log -RunningNote 'Docker Desktop waits: it is running' }
Write-Output ('other-listed=' + ($script:out -match 'Not upgradeable through winget .*Docker Desktop \(4\.93\.0 -> 4\.94\.0\), Microsoft Edge'))
Write-Output ('other-not-pending=' + (-not ($script:out -match 'Still pending')))
Write-Output ('other-not-nothing=' + (-not ($script:out -match 'Nothing to upgrade in winget')))
Write-Output ('other-no-raw-blocked=' + (-not ($script:out -match 'have upgrades blocked')))
$script:idProbe = @{ 'Docker.DockerDesktop' = @($sentence); 'Microsoft.Edge' = @('Found Microsoft Edge') }
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('mixed-pending=' + ($script:out -match 'Still pending in winget: Microsoft Edge'))
Write-Output ('mixed-other=' + ($script:out -match 'Not upgradeable through winget .*Docker Desktop'))
# a sweep without the blocked note probes nothing: the listing's rows stay "still pending"
$script:idProbe = @{ 'Docker.DockerDesktop' = @($sentence); 'Microsoft.Edge' = @($sentence) }
$script:sweep = @('Found nothing')
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('noblock-no-probe=' + ($script:out -match 'Still pending in winget: Docker Desktop'))
$script:idProbe = @{}

$script:sweep = @()
$script:listing = @('No installed package found matching input criteria.')
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('idle-says-nothing=' + ($script:out -match 'Nothing to upgrade in winget'))
# the sweep's own "nothing" wording stays in the log, not on screen next to the summary
$script:sweep = @('No installed package found matching input criteria.')
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('idle-sweep-quiet=' + ((-not ($script:out -match 'No installed package found')) -and ($script:out -match 'Nothing to upgrade in winget')))
$script:sweep = @()

$script:sweepExit = 5
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('fail-warns=' + ($script:out -match 'winget exited 5'))
Write-Output ('fail-exit=' + $script:code)
$script:sweepExit = 0

$logText = Get-Content -Raw -LiteralPath $log
Write-Output ('log-header=' + ($logText -match '(?m)^=== .* winget upgrade --all'))
Write-Output ('log-has-noise-too=' + ($logText -match '12\.3 MB'))

# ---- Docker Desktop: what is pending ---------------------------------------------------------------
$script:chocoOutdated = @()
function choco { $script:chocoOutdated | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
$script:listing = $real
Write-Output ('docker-pending-winget=' + (Get-DockerDesktopUpgrade))
$script:listing = @('No applicable upgrade found.')
$script:chocoOutdated = @('docker-desktop|4.93.0|4.95.0|false', 'git|2.56.0|2.57.0|false')
Write-Output ('docker-pending-choco=' + (Get-DockerDesktopUpgrade))
$script:chocoOutdated = @('git|2.56.0|2.57.0|false')
Write-Output ('docker-pending-none=[' + (Get-DockerDesktopUpgrade) + ']')

# ---- Docker Desktop: stopping it ---------------------------------------------------------------------
$script:dockerUp = $true
$script:dockerStubborn = $false
$script:dockerCalls = @()
# A fake process table: Docker Desktop (pid 4242) and VS Code processes, found by name or by id.
# A VS Code process answers CloseMainWindow like a real one (it exits unless $vsStubborn).
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
    $all = @()
    if ($script:dockerUp) { $all += [pscustomobject]@{ ProcessName = 'Docker Desktop'; Id = 4242 } }
    $all += @($script:vsProcs)
    if ($Id) { return @($all | Where-Object { $Id -contains $_.Id }) }
    if ($Name) { return @($all | Where-Object { $Name -contains $_.ProcessName }) }
    return $all
}
function docker { $script:dockerCalls += ($args -join ' '); if (-not $script:dockerStubborn) { $script:dockerUp = $false } }
$script:killed = @()
function Stop-AgentProcess {
    param($Process, [int]$GraceSeconds)
    $script:killed += $Process.Id
    $script:events += "kill:$($Process.Id)"
    if ($Process.Id -eq 4242) { $script:dockerUp = $false } else { $script:vsProcs = @($script:vsProcs | Where-Object { $_.Id -ne $Process.Id }) }
    return $true
}

Write-Output ('stop-graceful=' + (Stop-DockerDesktop -TimeoutSeconds 1))
Write-Output ('stop-used-cli=' + ($script:dockerCalls -join '|'))
Write-Output ('stop-no-kill=' + ($script:killed.Count -eq 0))
$script:dockerUp = $true; $script:dockerStubborn = $true; $script:dockerCalls = @(); $script:killed = @()
Write-Output ('stop-forced=' + (Stop-DockerDesktop -TimeoutSeconds 1))
Write-Output ('stop-forced-killed=' + ($script:killed -join ','))

# ---- Docker Desktop: the offer ---------------------------------------------------------------------
$script:interactive = $true
$script:answer = 'n'
$script:prompts = 0
function Test-InteractiveConsole { return $script:interactive }
function Read-Host { param([string]$Prompt) $script:prompts++; return $script:answer }
$script:stopResult = $true
$script:stopCalls = 0
function Stop-DockerDesktop { param([int]$TimeoutSeconds) $script:stopCalls++; $script:events += 'docker:stop'; return $script:stopResult }

function Offer([int[]]$Exclude = @()) {
    $script:prompts = 0; $script:stopCalls = 0; $script:events = @()
    $script:out = (& { $script:r = Invoke-DockerDesktopStopOffer -Version '4.94.0' -ExcludeId $Exclude -VsCodeGraceSeconds 1 } *>&1 | Out-String)
}

$script:dockerUp = $false
Offer
Write-Output ("offer-not-running=$($script:r)|prompts=$($script:prompts)")

$script:dockerUp = $true; $script:dockerStubborn = $true
$env:DOTUPGRADE_NO_PROMPT = '1'
Offer
Write-Output ("offer-no-prompt=$($script:r)|prompts=$($script:prompts)|says=" + ($script:out -match 'left for the next run'))
Remove-Item Env:DOTUPGRADE_NO_PROMPT
$script:interactive = $false
Offer
Write-Output ("offer-non-interactive=$($script:r)|prompts=$($script:prompts)")
$script:interactive = $true

$script:answer = 'n'
Offer
Write-Output ("offer-declined=$($script:r)|prompts=$($script:prompts)|stops=$($script:stopCalls)")
$script:answer = ''
Offer
Write-Output ("offer-default-is-no=$($script:r)|stops=$($script:stopCalls)")
$script:answer = 'y'
Offer
Write-Output ("offer-accepted=$($script:r)|stops=$($script:stopCalls)|says=" + ($script:out -match 'start it again'))
$script:stopResult = $false
Offer
Write-Output ("offer-stop-failed=$($script:r)|warns=" + ($script:out -match 'did not stop'))
Write-Output ('no-vscode-no-mention=' + (-not ($script:out -match 'VS Code')))

# ---- VS Code: closed first, only as part of stopping Docker ------------------------------------------
# A window attached to a dev container loses it when Docker stops, so VS Code is closed (cleanly)
# BEFORE Docker is stopped; a VS Code that hosts this terminal is never closed (that would end
# this very command); nothing is touched unless the operator accepts.
$script:stopResult = $true
$script:answer = 'y'
$script:dockerUp = $true; $script:dockerStubborn = $true
$script:vsStubborn = $false
$script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002))
Offer
Write-Output ("vs-accepted=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")
Write-Output ('vs-prompt-says=' + (($script:out -match 'VS Code is running \(2 process') -and ($script:out -match 'closed first')))
Write-Output ('vs-no-host-note=' + (-not ($script:out -match 'hosts THIS terminal')))
Write-Output ('vs-confirms=' + ($script:out -match 'VS Code closed'))

$script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002))
$script:answer = 'n'
Offer
Write-Output ("vs-declined=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")

$script:answer = 'y'
$script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002))
$env:DOTUPGRADE_NO_PROMPT = '1'
Offer
Remove-Item Env:DOTUPGRADE_NO_PROMPT
Write-Output ("vs-no-prompt=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")

# VS Code hosts this terminal (pid 7001 is an ancestor): only the other window is closed
$script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002))
Offer -Exclude @(7001)
Write-Output ("vs-hosting=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs | ForEach-Object { $_.Id }) -join ',')")
Write-Output ('vs-hosting-says=' + ($script:out -match 'hosts THIS terminal'))

# only the terminal's own VS Code: nothing to close, the note still warns, Docker is stopped
$script:vsProcs = @((New-VsProc 7001))
Offer -Exclude @(7001)
Write-Output ("vs-only-host=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")
Write-Output ('vs-only-host-no-close-line=' + (-not ($script:out -match 'will be closed first')))

# a VS Code that ignores the close request is ended after the grace period, still before Docker
$script:vsStubborn = $true
$script:vsProcs = @((New-VsProc 7001), (New-VsProc 7002))
Offer
Write-Output ("vs-stubborn=$($script:r)|events=$($script:events -join ',')|left=$(@($script:vsProcs).Count)")
PSEOF

mkdir -p "$tmp/log"
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -LogDir "$(winpath "$tmp/log")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))"; }

expect 'parse-count=2'
expect 'parse-first=Docker Desktop|Docker.DockerDesktop|4.93.0|4.94.0|winget'
expect 'parse-second=Microsoft Edge|154.0.4258.62'
expect 'parse-empty=0'
expect 'parse-none=0'
expect 'swept-count=True'
expect 'swept-no-pending=True'
expect 'swept-keeps-chatter=True'
expect 'swept-hides-noise=True'
expect 'swept-exit=0'
expect 'pending-names=True'
expect 'pending-note=True'
expect 'pending-blocked=True'
expect 'other-listed=True'
expect 'other-not-pending=True'
expect 'other-not-nothing=True'
expect 'other-no-raw-blocked=True'
expect 'mixed-pending=True'
expect 'mixed-other=True'
expect 'noblock-no-probe=True'
expect 'pending-no-upgraded-claim=True'
expect 'idle-says-nothing=True'
expect 'idle-sweep-quiet=True'
expect 'fail-warns=True'
expect 'fail-exit=5'
expect 'log-header=True'
expect 'log-has-noise-too=True'
expect 'docker-pending-winget=4.94.0'
expect 'docker-pending-choco=4.95.0'
expect 'docker-pending-none=[]'
expect 'stop-graceful=True'
expect 'stop-used-cli=desktop stop'
expect 'stop-no-kill=True'
expect 'stop-forced=True'
expect 'stop-forced-killed=4242'
expect 'offer-not-running=True|prompts=0'
expect 'offer-no-prompt=False|prompts=0|says=True'
expect 'offer-non-interactive=False|prompts=0'
expect 'offer-declined=False|prompts=1|stops=0'
expect 'offer-default-is-no=False|stops=0'
expect 'offer-accepted=True|stops=1|says=True'
expect 'offer-stop-failed=False|warns=True'
expect 'no-vscode-no-mention=True'
expect 'vs-accepted=True|events=vscode:close:7001,vscode:close:7002,docker:stop|left=0'
expect 'vs-prompt-says=True'
expect 'vs-no-host-note=True'
expect 'vs-confirms=True'
expect 'vs-declined=False|events=|left=2'
expect 'vs-no-prompt=False|events=|left=2'
expect 'vs-hosting=True|events=vscode:close:7002,docker:stop|left=7001'
expect 'vs-hosting-says=True'
expect 'vs-only-host=True|events=docker:stop|left=1'
expect 'vs-only-host-no-close-line=True'
expect 'vs-stubborn=True|events=vscode:close:7001,vscode:close:7002,kill:7001,kill:7002,docker:stop|left=0'
pass

# --- wiring: Docker is dealt with before the choco sweep, and winget runs through the summary ---
du="$repo_root/scripts/dotupgrade.ps1"
dock_line="$(grep -n 'Get-DockerDesktopUpgrade' "$du" | head -1 | cut -d: -f1)"
choco_line="$(grep -n 'Invoke-ChocoUpgradeAll -Arguments' "$du" | head -1 | cut -d: -f1)"
if [ -z "$dock_line" ] || [ -z "$choco_line" ] || [ "$dock_line" -ge "$choco_line" ]; then
    fail "dotupgrade.ps1 must check Docker Desktop BEFORE the choco sweep"
fi
grep -Fq 'Get-ChocoUpgradeArgument -KeepDockerDesktop:$dockerKept' "$du" || fail "dotupgrade.ps1 must exclude Docker Desktop from the sweep when it was kept running"
grep -Fq 'Invoke-WingetUpgradeAll' "$du" || fail "dotupgrade.ps1 must run winget through Invoke-WingetUpgradeAll"
if grep -Eq '^[[:space:]]*&[[:space:]]+winget[[:space:]]+upgrade --all' "$du"; then fail "dotupgrade.ps1 must not call the raw winget sweep"; fi
pass

finish
