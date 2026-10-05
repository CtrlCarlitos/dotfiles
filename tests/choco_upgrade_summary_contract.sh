#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# `dot upgrade` printed ~100 lines of "<package> vX is the latest version available" on every
# run, burying the two or three packages that actually changed. choco's --limit-output
# prints one machine-readable line per package (name|installed|available|pinned); the
# sweep now hides those lines, still streams everything a package's own installer says
# (so a hung or prompting installer stays visible), keeps the FULL output in
# ~\.local\state\dotfiles\upgrade.log, and ends with a summary:
#   Nothing to upgrade (101 packages checked)    /    Upgraded 2 of 101: a (1 -> 2), b (3 -> 4)
# A non-zero exit prints the tail of the output so the failing package is on screen.
# The functions are EXECUTED against a fake choco.
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

$script:chocoLines = @()
$script:chocoExit = 0
$script:chocoArgs = ''
function choco { $script:chocoArgs = ($args -join ' '); $script:chocoLines | ForEach-Object { $_ }; $global:LASTEXITCODE = $script:chocoExit }

$log = Join-Path $LogDir 'upgrade.log'
function Run([string[]]$ChocoArgs) {
    $script:out = (& { $script:code = Invoke-ChocoUpgradeAll -Arguments $ChocoArgs -LogPath $log } *>&1 | Out-String)
}

# --- nothing to upgrade ---
$script:chocoLines = @('7zip|26.3.0|26.3.0|false', 'act-cli|0.2.89|0.2.89|false', 'git|2.56.0|2.56.0|false')
Run @('upgrade', 'all', '-y', '--no-progress')
Write-Output ('idle-summary=' + ($script:out -match 'Nothing to upgrade \(3 packages checked\)'))
Write-Output ('idle-hides-pipe-lines=' + (-not ($script:out -match '7zip\|')))
Write-Output ('idle-exit=' + $script:code)
Write-Output ('limit-output-passed=' + ($script:chocoArgs -match '--limit-output' -and $script:chocoArgs -match 'upgrade all -y --no-progress'))

# --- something upgraded, with the package's own installer chatter ---
$script:chocoLines = @('antigravity|2.18.1|2.19.1|false', 'Downloading antigravity 156.34 MB', 'Installing antigravity...', 'git|2.56.0|2.56.0|false', 'terraform|1.16.4|1.16.5|false')
Run @('upgrade', 'all', '-y', '--no-progress')
Write-Output ('upgrade-summary=' + ($script:out -match 'Upgraded 2 of 3: antigravity \(2\.18\.1 -> 2\.19\.1\), terraform \(1\.16\.4 -> 1\.16\.5\)'))
Write-Output ('chatter-stays-live=' + ($script:out -match 'Downloading antigravity' -and $script:out -match 'Installing antigravity\.\.\.'))
Write-Output ('upgrade-hides-up-to-date=' + (-not ($script:out -match 'git\|')))

# --- failure: tail of the output, exit code returned ---
$script:chocoLines = @('a|1|1|false', 'pkg-x|1|2|false', 'ERROR: pkg-x failed to install', 'The install of pkg-x was NOT successful.')
$script:chocoExit = 1
Run @('upgrade', 'all', '-y')
Write-Output ('fail-exit=' + $script:code)
Write-Output ('fail-warns=' + ($script:out -match 'choco exited 1'))
Write-Output ('fail-shows-tail=' + ($script:out -match 'pkg-x failed to install'))

# --- reboot-required codes are success ---
$script:chocoLines = @('a|1|1|false')
$script:chocoExit = 3010
Run @('upgrade', 'all', '-y')
Write-Output ('reboot-not-failure=' + (-not ($script:out -match 'choco exited') -and $script:out -match 'restart'))

# --- the full output, pipe lines included, is in the log ---
$logText = Get-Content -Raw -LiteralPath $log
Write-Output ('log-has-pipe-lines=' + ($logText -match 'antigravity\|2\.18\.1\|2\.19\.1'))
Write-Output ('log-has-chatter=' + ($logText -match 'Downloading antigravity'))
Write-Output ('log-has-header=' + ($logText -match '(?m)^=== .* choco upgrade all'))
PSEOF

mkdir -p "$tmp/log"
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -LogDir "$(winpath "$tmp/log")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }

expect 'idle-summary=True'
expect 'idle-hides-pipe-lines=True'
expect 'idle-exit=0'
expect 'limit-output-passed=True'
expect 'upgrade-summary=True'
expect 'chatter-stays-live=True'
expect 'upgrade-hides-up-to-date=True'
expect 'fail-exit=1'
expect 'fail-warns=True'
expect 'fail-shows-tail=True'
expect 'reboot-not-failure=True'
expect 'log-has-pipe-lines=True'
expect 'log-has-chatter=True'
expect 'log-has-header=True'

# --- wiring: dot upgrade uses it for the sweep and for the second opencode pass ---
grep -Fq 'Invoke-ChocoUpgradeAll -Arguments $chocoArguments' "$repo_root/scripts/dotupgrade.ps1" ||
    fail "dotupgrade.ps1 must run the sweep through Invoke-ChocoUpgradeAll"
grep -Fq "Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'opencode'" "$repo_root/scripts/update_ai_tools.ps1" ||
    fail "update_ai_tools.ps1 must run the opencode upgrade through Invoke-ChocoUpgradeAll"

finish
