#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# One registry question inside a real Windows `dot up` took 41 s and 48 s (2026-10-12) - not the fetch (a
# 10-second limit did not cut it) and not npm alone (0.64 s and 2.7 s at the prompt). The "is it current"
# checks no longer start npm: the installed version is a package.json under the global prefix, the latest
# version one HTTPS request to the registry's /latest document with a hard time limit
# (scripts/lib/ps-npm-registry.ps1). Whatever it cannot say - a registry set in the environment or ~\.npmrc,
# a failed request - is left to npm as before. Executed here against fixtures and a stubbed request.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

lib="$repo_root/scripts/lib/ps-npm-registry.ps1"
tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
common="$repo_root/scripts/lib/ps-common.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-npm-registry.ps1 must exist"
grep -Fq 'include "scripts/lib/ps-npm-registry.ps1"' "$tmpl" || fail "the installer must include ps-npm-registry.ps1"
grep -Fq 'ps-npm-registry.ps1' "$common" || fail "ps-common.ps1 must load ps-npm-registry.ps1"
grep -Fq "Get-NpmLatestVersion -Package 'npm'" "$tmpl" || fail "the installer's npm check must ask the registry directly first"
grep -Fq "Add-DotTimingMark -Name 'npm version'" "$tmpl" || fail "the installer must time the npm version read on its own"
grep -Fq "Add-DotTimingMark -Name 'npm registry check'" "$tmpl" || fail "the installer must time the registry question on its own"
grep -Fq 'Get-NpmLatestVersion -Package $Package' "$common" || fail "Test-NpmGlobalCurrent must ask the registry directly first"
grep -Fq "Add-DotTimingMark -Name 'Serena: uv'" "$tmpl" || fail "the Serena section must be timed in parts"
grep -Fq "Add-DotTimingMark -Name 'Serena: claude registration'" "$tmpl" || fail "the Serena section must be timed in parts"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

tr -d '\r' <"$tmpl" >"$tmp/installer.lf"
awk '/^function Invoke-NpmUpgradeOnce \{/{f=1} f{print} f && /^\}$/{exit}' "$tmp/installer.lf" >"$tmp/npm-fn.ps1"
[ -s "$tmp/npm-fn.ps1" ] || fail "could not extract Invoke-NpmUpgradeOnce from the installer"

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Common, [string]$Skills, [string]$Fn, [string]$Work)
$ErrorActionPreference = 'Stop'
$env:DOT_NPM_DIRECT = '1'
$env:XDG_STATE_HOME = Join-Path $Work 'state'
$fakeHome = Join-Path $Work 'home'
New-Item -ItemType Directory -Force -Path $fakeHome | Out-Null
$env:USERPROFILE = $fakeHome
$env:APPDATA = Join-Path $Work 'appdata'
foreach ($name in 'npm_config_prefix', 'NPM_CONFIG_PREFIX', 'npm_config_registry', 'NPM_CONFIG_REGISTRY') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
. $Lib
function Out($label, $value) { Write-Output ("$label=$value") }

function New-Pkg([string]$Root, [string]$Name, [string]$Version) {
    $dir = Join-Path $Root 'node_modules'
    foreach ($part in ($Name -split '/')) { $dir = Join-Path $dir $part }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'package.json'), ('{"name":"' + $Name + '","version":"' + $Version + '"}'))
}
$prefix = Join-Path $Work 'prefix'
$nodeDir = Join-Path $Work 'nodejs'
New-Pkg $prefix '@openai/codex' '0.162.1'
New-Pkg $prefix 'markdownlint-cli2' '0.23.3'
New-Pkg $nodeDir 'npm' '10.0.0'
New-Pkg $prefix 'npm' '12.2.0'

# installed versions: scoped names, the first root that has it, a miss, a broken file
Out 'installed-scoped' (Get-NpmInstalledVersion -Package '@openai/codex' -Root @($prefix))
Out 'installed-plain' (Get-NpmInstalledVersion -Package 'markdownlint-cli2' -Root @($prefix))
Out 'installed-first-root' (Get-NpmInstalledVersion -Package 'npm' -Root @($prefix, $nodeDir))
Out 'installed-second-root' (Get-NpmInstalledVersion -Package 'npm' -Root @((Join-Path $Work 'empty'), $nodeDir))
Out 'installed-miss' ('[' + (Get-NpmInstalledVersion -Package 'nothing-here' -Root @($prefix)) + ']')
[IO.File]::WriteAllText((Join-Path $prefix 'node_modules\markdownlint-cli2\package.json'), '{ not json')
Out 'installed-broken' ('[' + (Get-NpmInstalledVersion -Package 'markdownlint-cli2' -Root @($prefix)) + ']')
New-Pkg $prefix 'markdownlint-cli2' '0.23.3'
$env:DOT_NPM_DIRECT = '0'
Out 'installed-off' ('[' + (Get-NpmInstalledVersion -Package 'npm' -Root @($prefix)) + ']')
$env:DOT_NPM_DIRECT = '1'

# which prefix: the environment and ~\.npmrc
$env:npm_config_prefix = 'C:\from-env'
Out 'root-env' ((Get-NpmGlobalRoot) -contains 'C:\from-env')
Remove-Item Env:\npm_config_prefix
[IO.File]::WriteAllLines((Join-Path $fakeHome '.npmrc'), @('; a comment', 'prefix=${APPDATA}\npm-global'))
Out 'root-npmrc' (@(Get-NpmGlobalRoot | Where-Object { $_ -like '*appdata*npm-global' }).Count -gt 0)

# which registry: the public one, or "ask npm"
[IO.File]::WriteAllLines((Join-Path $fakeHome '.npmrc'), @('prefix=x'))
Out 'registry-default' (Get-NpmRegistryTarget -Package 'npm')
[IO.File]::WriteAllLines((Join-Path $fakeHome '.npmrc'), @('registry=https://registry.npmjs.org/'))
Out 'registry-explicit-public' (Get-NpmRegistryTarget -Package 'npm')
[IO.File]::WriteAllLines((Join-Path $fakeHome '.npmrc'), @('registry=https://npm.corp.example/'))
Out 'registry-corporate' ('[' + (Get-NpmRegistryTarget -Package 'npm') + ']')
[IO.File]::WriteAllLines((Join-Path $fakeHome '.npmrc'), @('@openai:registry=https://npm.corp.example/'))
Out 'registry-scope-hit' ('[' + (Get-NpmRegistryTarget -Package '@openai/codex') + ']')
Out 'registry-scope-miss' (Get-NpmRegistryTarget -Package 'markdownlint-cli2')
Remove-Item (Join-Path $fakeHome '.npmrc')
$env:npm_config_registry = 'https://mirror.example/'
Out 'registry-env' ('[' + (Get-NpmRegistryTarget -Package 'npm') + ']')
Remove-Item Env:\npm_config_registry

# the latest version: the request, its answer, its failure
$script:requests = @()
$script:answer = [pscustomobject]@{ name = 'x'; version = '12.3.0' }
function Invoke-NpmRegistryRequest { param([string]$Uri, [int]$TimeoutSeconds = 10) $script:requests += "$Uri|$TimeoutSeconds"; return $script:answer }
Out 'latest' (Get-NpmLatestVersion -Package 'npm')
Out 'latest-scoped-uri' ($script:requests[-1])
$script:answer = $null
Out 'latest-failed' ('[' + (Get-NpmLatestVersion -Package 'npm') + ']')
$script:requests = @()
$env:npm_config_registry = 'https://mirror.example/'
Out 'latest-custom-asks-nobody' ('[' + (Get-NpmLatestVersion -Package 'npm') + ']|' + $script:requests.Count)
Remove-Item Env:\npm_config_registry
$env:DOT_NPM_DIRECT = '0'
Out 'latest-off-asks-nobody' ('[' + (Get-NpmLatestVersion -Package 'npm') + ']|' + $script:requests.Count)
$env:DOT_NPM_DIRECT = '1'

# Test-NpmGlobalCurrent: no npm process at all when the file and the request can answer
$env:npm_config_prefix = $prefix
. $Common   # loads the library again: the request stub is put back below
function Invoke-NpmRegistryRequest { param([string]$Uri, [int]$TimeoutSeconds = 10) $script:requests += "$Uri|$TimeoutSeconds"; return $script:answer }
$script:npmCalls = 0
function npm { $script:npmCalls++; $global:LASTEXITCODE = 0 }
$script:answer = [pscustomobject]@{ version = '0.162.1' }
Out 'current' (Test-NpmGlobalCurrent '@openai/codex')
Out 'current-version' $script:NpmCurrentVersion
$script:answer = [pscustomobject]@{ version = '0.163.0' }
Out 'behind' (Test-NpmGlobalCurrent '@openai/codex')
Out 'behind-latest' $script:NpmLatestVersion
Out 'no-npm-process' $script:npmCalls

# the installer's npm check: file + request, then the day's stamp
$script:requests = @()
$script:answer = [pscustomobject]@{ version = '12.2.0' }
. $Skills
function Invoke-Quietly { param([string]$Description, [scriptblock]$Action) & $Action }
function Add-DotTimingMark { param($Name) $script:DotTimingLast = $Name }
$script:DotTimingLast = 'Node.js'
. $Fn
function Run { $script:NpmUpgraded = $false; (Invoke-NpmUpgradeOnce *>&1 | Out-String).Trim() }
$first = Run
Out 'installer-first-current' ($first -match 'npm is current \(12\.2\.0\)')
Out 'installer-first-requests' $script:requests.Count
Out 'installer-first-npm-calls' $script:npmCalls
$second = Run
Out 'installer-second-says' ($second -match 'checked within the last day')
Out 'installer-second-requests' $script:requests.Count
Out 'installer-section-resumes' $script:DotTimingLast
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$lib")" -Common "$(winpath "$common")" -Skills "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -Fn "$(winpath "$tmp/npm-fn.ps1")" -Work "$(winpath "$tmp/work")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { if printf '%s\n' "$out" | grep -Fxq "$1"; then pass; else fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))"; fi; }
expect 'installed-scoped=0.162.1'
expect 'installed-plain=0.23.3'
expect 'installed-first-root=12.2.0'
expect 'installed-second-root=10.0.0'
expect 'installed-miss=[]'
expect 'installed-broken=[]'
expect 'installed-off=[]'
expect 'root-env=True'
expect 'root-npmrc=True'
expect 'registry-default=https://registry.npmjs.org'
expect 'registry-explicit-public=https://registry.npmjs.org'
expect 'registry-corporate=[]'
expect 'registry-scope-hit=[]'
expect 'registry-scope-miss=https://registry.npmjs.org'
expect 'registry-env=[]'
expect 'latest=12.3.0'
expect 'latest-scoped-uri=https://registry.npmjs.org/npm/latest|10'
expect 'latest-failed=[]'
expect 'latest-custom-asks-nobody=[]|0'
expect 'latest-off-asks-nobody=[]|0'
expect 'current=True'
expect 'current-version=0.162.1'
expect 'behind=False'
expect 'behind-latest=0.163.0'
expect 'no-npm-process=0'
expect 'installer-first-current=True'
expect 'installer-first-requests=1'
expect 'installer-first-npm-calls=0'
expect 'installer-second-says=True'
expect 'installer-second-requests=1'
expect 'installer-section-resumes=Node.js'

finish
