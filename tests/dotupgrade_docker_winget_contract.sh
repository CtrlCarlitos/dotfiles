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
    else { $script:listing | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
}
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

$script:sweep = @()
$script:listing = @('No installed package found matching input criteria.')
Run { $script:code = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('idle-says-nothing=' + ($script:out -match 'Nothing to upgrade in winget'))

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
function Get-Process { param([Parameter(Position = 0)][string[]]$Name) if ($script:dockerUp) { [pscustomobject]@{ ProcessName = 'Docker Desktop'; Id = 4242 } } }
function docker { $script:dockerCalls += ($args -join ' '); if (-not $script:dockerStubborn) { $script:dockerUp = $false } }
$script:killed = @()
function Stop-AgentProcess { param($Process) $script:killed += $Process.Id; $script:dockerUp = $false; return $true }

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
function Stop-DockerDesktop { param([int]$TimeoutSeconds) $script:stopCalls++; return $script:stopResult }

function Offer { $script:prompts = 0; $script:stopCalls = 0; $script:out = (& { $script:r = Invoke-DockerDesktopStopOffer -Version '4.94.0' } *>&1 | Out-String) }

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
expect 'pending-no-upgraded-claim=True'
expect 'idle-says-nothing=True'
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
pass

# --- wiring: Docker is dealt with before the choco sweep, and winget runs through the summary ---
du="$repo_root/scripts/dotupgrade.ps1"
dock_line="$(grep -n 'Get-DockerDesktopUpgrade' "$du" | head -1 | cut -d: -f1)"
choco_line="$(grep -n 'Invoke-ChocoUpgradeAll -Arguments' "$du" | head -1 | cut -d: -f1)"
[ -n "$dock_line" ] && [ -n "$choco_line" ] && [ "$dock_line" -lt "$choco_line" ] \
    || fail "dotupgrade.ps1 must check Docker Desktop BEFORE the choco sweep"
grep -Fq 'Get-ChocoUpgradeArgument -KeepDockerDesktop:$dockerKept' "$du" || fail "dotupgrade.ps1 must exclude Docker Desktop from the sweep when it was kept running"
grep -Fq 'Invoke-WingetUpgradeAll' "$du" || fail "dotupgrade.ps1 must run winget through Invoke-WingetUpgradeAll"
if grep -Eq '^[[:space:]]*&[[:space:]]+winget[[:space:]]+upgrade --all' "$du"; then fail "dotupgrade.ps1 must not call the raw winget sweep"; fi
pass

finish
