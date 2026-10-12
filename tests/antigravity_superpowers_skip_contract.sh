#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# `dot upgrade` ran `agy plugin install` for Superpowers on every run: a fresh clone of the repository,
# 12 s in one run and 21 s in the next (2026-10-12), to learn that 7.0.0 was still 7.0.0. The step now
# compares the installed plugin's version with upstream's latest release (both already read for the
# report below it) and installs only when they differ or either is unreadable. The step's text is run
# here (Get-DotSectionText, the same slicer the background copies use) against a fake agy.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

updater="$repo_root/scripts/update_ai_tools.ps1"
grep -Fq 'Get-AntigravitySuperpowersVersion' "$updater" || fail "update_ai_tools.ps1 must read the installed Antigravity Superpowers version"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Updater, [string]$Background, [string]$Skills)
$ErrorActionPreference = 'Stop'
. $Background
. $Skills
$G = @{ sparkles = '*' }
$script:agyCalls = 0
function agy { $script:agyCalls++; $global:LASTEXITCODE = 0 }
$text = (Get-DotSectionText -Path $Updater -Name 'Superpowers (Antigravity)')['Superpowers (Antigravity)']
function Run([string]$Have, [string]$Want) {
    $script:have = $Have; $script:want = $Want; $script:agyCalls = 0
    function Get-AntigravitySuperpowersVersion { $script:have }
    function Get-SuperpowersLatestVersionCached { $script:want }
    $lines = @(. ([scriptblock]::Create($text)) 6>&1 | ForEach-Object { "$_" })
    return ('calls={0} {1}' -f $script:agyCalls, (($lines -join '|').Trim()))
}
Write-Output ('same=' + (Run '7.0.0' '7.0.0'))
Write-Output ('behind=' + (Run '6.4.2' '7.0.0'))
Write-Output ('unreadable-have=' + (Run '' '7.0.0'))
Write-Output ('unreachable-upstream=' + (Run '7.0.0' ''))
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Updater "$(winpath "$updater")" -Background "$(winpath "$repo_root/scripts/lib/ps-background.ps1")" -Skills "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { case "$out" in *"$1"*) pass ;; *) fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))" ;; esac; }
expect 'same=calls=0 '
expect 'is current (7.0.0)'
expect 'behind=calls=1 '
expect 'unreadable-have=calls=1 '
expect 'unreachable-upstream=calls=1 '

finish
