#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Measured 2026-10-12 on the Windows host: every `winget list --id X --exact` costs ~2.3 s and every
# `choco list --exact X` ~1.7 s, whatever the answer. The installer already holds one inventory of
# each, yet the desktop-app section (Chrome, Win-CodexBar, Docker Desktop, Meld) asked per app again:
# about 14 s of every no-op `dot up`. And a `dot upgrade` with nothing to upgrade printed five lines of
# choco boilerplate around our own "Nothing to upgrade" line. Both executed here against stubs:
#   - Test-DotWingetInstalled / Test-DotChocoPackage answer from the inventory (no live call on a hit, and
#     none for choco while its listing is usable) and fall back to the live query otherwise;
#   - the choco sweep drops only choco's own opening and closing lines.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-package-inventory.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-package-inventory.ps1 must exist"
grep -Fq 'include "scripts/lib/ps-package-inventory.ps1"' "$tmpl" || fail "the installer must include scripts/lib/ps-package-inventory.ps1"
grep -Fq 'Register-DotPackageInventory -Choco $chocoInstalled' "$tmpl" || fail "the installer must publish the choco inventory"
grep -Fq 'Register-DotPackageInventory -Winget $wingetInventory' "$tmpl" || fail "the installer must publish the winget inventory"
for app in Google.Chrome Finesssee.Win-CodexBar Docker.DockerDesktop Meld.Meld; do
    grep -Fq "Test-DotWingetInstalled '$app'" "$tmpl" || fail "the installer must look $app up through the inventory"
    if grep -Fq "winget list --id $app" "$tmpl"; then fail "the installer must not run its own 'winget list --id $app' (use Test-DotWingetInstalled)"; fi
done
for pkg in googlechrome docker-desktop meld; do
    grep -Fq "Test-DotChocoPackage '$pkg'" "$tmpl" || fail "the installer must look $pkg up through the inventory"
    if grep -Fq "choco list --limit-output --exact $pkg" "$tmpl"; then fail "the installer must not run its own 'choco list --exact $pkg' (use Test-DotChocoPackage)"; fi
done
pass

# --- executed -----------------------------------------------------------------------------------
command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (helpers run under PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Common)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Lib
$script:calls = New-Object System.Collections.Generic.List[string]
function winget { $script:calls.Add('winget ' + ($args -join ' ')); if ("$args" -match 'Live\.Only') { 'Name Id Version'; 'Live Live.Only 1.0' } }
function choco { $script:calls.Add('choco ' + ($args -join ' ')); if ("$args" -match 'liveonly') { 'liveonly|1.0' } }
function Out($label, $value) { Write-Output ("$label=$value") }

# nothing published yet: every question is a live one
Out 'wg-cold' (Test-DotWingetInstalled 'Live.Only'); Out 'calls-cold' $script:calls.Count
$script:calls.Clear()

$inv = "Name        Id              Version`nGoogle Chrome Google.Chrome    1.0 winget`n"
$set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
[void]$set.Add('meld')
Register-DotPackageInventory -Winget $inv -Choco $set -ChocoUsable $true

Out 'wg-hit' (Test-DotWingetInstalled 'Google.Chrome')
Out 'calls-after-hit' $script:calls.Count
Out 'wg-miss-live-yes' (Test-DotWingetInstalled 'Live.Only')
Out 'calls-after-miss' $script:calls.Count
$script:calls.Clear()
Out 'wg-miss-live-no' (Test-DotWingetInstalled 'Not.There')
$script:calls.Clear()

Out 'ch-owned' (Test-DotChocoPackage 'MELD')
Out 'ch-not-owned' (Test-DotChocoPackage 'googlechrome')
Out 'calls-choco-usable' $script:calls.Count

# a failed batched listing: ask live
Register-DotPackageInventory -Choco $set -ChocoUsable $false
Out 'ch-live-yes' (Test-DotChocoPackage 'liveonly')
Out 'ch-live-no' (Test-DotChocoPackage 'other')
Out 'calls-choco-unusable' $script:calls.Count

# the quiet sweep
$ErrorActionPreference = 'Continue'
. $Common
function choco {
    if ("$args" -match 'upgrade') {
        ''
        'Upgrading the following packages:'
        'all'
        'By upgrading, you accept licenses for the packages.'
        ''
        if ($env:FAKE_CHOCO -eq 'failure') {
            'pkgbad v1.0 [Approved]'
            'The upgrade of pkgbad failed.'
            'Chocolatey upgraded 0/2 packages. 1 packages failed.'
        } else { 'Chocolatey upgraded 0/2 packages.' }
        ' See the log for details (C:\ProgramData\chocolatey\logs\chocolatey.log).'
        'git|2.1|2.1|false'
        'curl|8.0|8.0|false'
        $global:LASTEXITCODE = 0
    }
}
$log = Join-Path $env:TEMP ("choco-quiet-{0}.log" -f [guid]::NewGuid())
$quiet = (Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'all') -LogPath $log *>&1 | Out-String)
Out 'quiet-has-summary' ($quiet -match 'Nothing to upgrade \(2 packages checked\)')
Out 'quiet-no-header' (-not ($quiet -match 'Upgrading the following packages'))
Out 'quiet-no-licence' (-not ($quiet -match 'By upgrading, you accept'))
Out 'quiet-no-count' (-not ($quiet -match 'Chocolatey upgraded'))
Out 'quiet-no-pointer' (-not ($quiet -match 'See the log for details'))
Out 'quiet-no-bare-all' (-not ($quiet -match '(?m)^\s*all\s*$'))
Out 'quiet-log-keeps-all' ((Get-Content -Raw -LiteralPath $log) -match 'Chocolatey upgraded 0/2 packages\.')
$env:FAKE_CHOCO = 'failure'
$loud = (Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'all') -LogPath $log *>&1 | Out-String)
Out 'failure-shown' ($loud -match 'Chocolatey upgraded 0/2 packages\. 1 packages failed\.')
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$lib")" -Common "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { case "$out" in *"$1"*) pass ;; *) fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))" ;; esac; }
expect 'wg-cold=True'
expect 'calls-cold=1'
expect 'wg-hit=True'
expect 'calls-after-hit=0'
expect 'wg-miss-live-yes=True'
expect 'calls-after-miss=1'
expect 'wg-miss-live-no=False'
expect 'ch-owned=True'
expect 'ch-not-owned=False'
expect 'calls-choco-usable=0'
expect 'ch-live-yes=True'
expect 'ch-live-no=False'
expect 'calls-choco-unusable=2'
for key in quiet-has-summary quiet-no-header quiet-no-licence quiet-no-count quiet-no-pointer quiet-no-bare-all quiet-log-keeps-all failure-shown; do
    expect "$key=True"
done

finish
