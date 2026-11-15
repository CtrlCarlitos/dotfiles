#!/usr/bin/env bash
set -euo pipefail

# The package catalog's PowerShell Gallery modules (field `psgallery`:
# PSScriptAnalyzer) go through Install-PSGalleryModule
# (scripts/lib/ps-psgallery.ps1): `dot up` installs a missing one, `dot upgrade`
# updates an installed one that is behind. The work runs in a powershell.exe
# child so the copy lands in Windows PowerShell 5.1's per-user folder, which
# pwsh 7 also searches - an Install-Module from pwsh 7 lands where 5.1 cannot see
# it.
#
# Executed under StrictMode on pwsh and, where it exists, Windows PowerShell
# 5.1. `powershell.exe` is a function here that decodes -EncodedCommand and runs
# the child script in-process against stubbed Gallery cmdlets, so the real
# child code is what runs, with no network:
#   a. missing, dot up: installed at the Gallery's latest, -Scope CurrentUser;
#   b. present, dot up: left alone, and the Gallery is not asked;
#   c. behind, dot upgrade: upgraded;  d. current, dot upgrade: nothing installed;
#   e. missing, dot upgrade: not installed (dot up's job);
#   f. Install-Module throws: a warning and 'failed', never a throw;
#   g. the child sees 5.1's module path, and the caller's is restored after;
#   h. a name that is not a module name never reaches the child.
# And the wiring: the catalog record, the installer's include and modern_cli
# call, ps-common.ps1's load, and dot upgrade's step.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

shells=()
command -v pwsh >/dev/null 2>&1 && shells+=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
[ "${#shells[@]}" -gt 0 ] || skip 'no PowerShell installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
# The stubbed world: $have is the installed version ('' = none), $latest the Gallery's.
$script:have = ''; $script:latest = '1.25.0'; $script:installFails = $false
$script:calls = @(); $script:childModulePath = ''
function powershell.exe {
    $i = [array]::IndexOf($args, '-EncodedCommand')
    $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($args[$i + 1]))
    $script:childModulePath = $env:PSModulePath
    & ([scriptblock]::Create($text))
}
function Get-Module { if ($script:have) { [pscustomobject]@{ Name = 'PSScriptAnalyzer'; Version = [version]$script:have } } }
function Get-PackageProvider { [pscustomobject]@{ Name = 'NuGet'; Version = [version]'2.8.5.208' } }
function Install-PackageProvider { $script:calls += 'Install-PackageProvider' }
function Find-Module { $script:calls += 'Find-Module'; [pscustomobject]@{ Version = $script:latest } }
function Install-Module {
    param($Name, $RequiredVersion, $Repository, $Scope, [switch]$Force, [switch]$AllowClobber, [switch]$SkipPublisherCheck)
    if ($script:installFails) { throw 'gallery unreachable' }
    $script:calls += "Install-Module $Name $RequiredVersion $Scope"
}
function Run([string]$Case, [string]$Have, [switch]$Upgrade, [string]$Name = 'PSScriptAnalyzer') {
    $script:have = $Have; $script:calls = @()
    $host_ = @(Install-PSGalleryModule -Name $Name -Upgrade:$Upgrade 6>&1 | ForEach-Object { "$_" })
    $word = $host_[-1]; $printed = ($host_ | Select-Object -SkipLast 1) -join '/'
    Write-Output ("$Case=$word|$printed|" + ($script:calls -join ','))
}
$env:PSModulePath = 'SENTINEL-PWSH7-PATH'
Run 'a' ''
Write-Output ('g-child=' + $script:childModulePath)
Write-Output ('g-after=' + $env:PSModulePath)
Run 'b' '1.25.0'
Run 'c' '1.24.0' -Upgrade
Run 'd' '1.25.0' -Upgrade
Run 'e' '' -Upgrade
$script:installFails = $true
Run 'f' ''
$script:installFails = $false
Run 'h' '' -Name 'x; Remove-Item'
PSEOF

for sh in "${shells[@]}"; do
    out="$("$sh" -NoProfile -ExecutionPolicy Bypass -File "$(ps_path "$sh" "$tmp/harness.ps1")" \
        -Lib "$(ps_path "$sh" "$repo_root/scripts/lib/ps-psgallery.ps1")" 2>&1 | tr -d '\r' || true)"
    expect() { # $1 = exact line
        printf '%s\n' "$out" | grep -Fxq -- "$1" || fail "$sh: expected '$1' (output: $(printf '%s' "$out" | tr '\n' '|'))"
    }
    expect 'a=installed|  Installed PSScriptAnalyzer 1.25.0 (PowerShell Gallery)|Find-Module,Install-Module PSScriptAnalyzer 1.25.0 CurrentUser'
    expect 'b=present||'
    expect 'c=upgraded|  PSScriptAnalyzer upgraded 1.24.0 -> 1.25.0|Find-Module,Install-Module PSScriptAnalyzer 1.25.0 CurrentUser'
    expect 'd=current|  PSScriptAnalyzer is current (1.25.0)|Find-Module'
    expect 'e=absent||'
    expect 'f=failed|  Warning: PSScriptAnalyzer (PowerShell Gallery) failed - gallery unreachable - continuing|Find-Module'
    expect "h=failed|  Warning: 'x; Remove-Item' is not a PowerShell module name - skipping|"
    expect 'g-after=SENTINEL-PWSH7-PATH'
    child="$(printf '%s\n' "$out" | sed -n 's/^g-child=//p')"
    case "$child" in *SENTINEL*) fail "$sh: g: the child must not inherit the caller's module path ($child)" ;; esac
    case "$child" in *WindowsPowerShell*Modules*) pass ;; *) fail "$sh: g: the child must get 5.1's module path (got '$child')" ;; esac
done

# Wiring.
cat_file="$repo_root/.chezmoidata/packages.yaml"
grep -Fq 'psgallery: PSScriptAnalyzer' "$cat_file" || fail "the catalog must carry PSScriptAnalyzer under psgallery"
require "$repo_root/run_onchange_install_packages.ps1.tmpl" '{{ include "scripts/lib/ps-psgallery.ps1" }}'
require "$repo_root/scripts/lib/ps-common.ps1" "'ps-psgallery.ps1'"
require "$repo_root/scripts/dotupgrade.ps1" 'Install-PSGalleryModule -Name $psGalleryModule -Upgrade'
if command -v chezmoi >/dev/null 2>&1; then
    : >"$tmp/empty.toml"
    for on in true false; do
        chezmoi execute-template --config "$tmp/empty.toml" --source "$repo_root" \
            --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{\"modern_cli\":$on}}" \
            < "$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/modern-$on.ps1"
    done
    require "$tmp/modern-true.ps1" "\$psGalleryModules = @('PSScriptAnalyzer' -split ' '"
    forbid "$tmp/modern-false.ps1" "\$psGalleryModules = @("
else
    skip_part 'chezmoi not installed - render check skipped'
fi

finish
