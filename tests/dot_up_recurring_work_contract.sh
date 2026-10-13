#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# What a no-op Windows `dot up` still spent (2026-10-12, degraded link): `npm view npm version` 41 s,
# the OpenCode section's `npm install superpowers@git+...` (a git clone) 25 s, `serena init` 15 s,
# `agent-browser install` and its verification 12 s - all to find nothing to do, every run. Now:
#   - the npm registry question is bounded (one try, ten seconds) and asked at most once a day per npm
#     version (a stamp under dotfiles\checks, scripts/lib/ps-skills.ps1);
#   - the OpenCode Superpowers install, `serena init` and agent-browser's browser setup run only when
#     their result is missing (`dot upgrade` refreshes them); the setup is stamped with the version.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
skills="$repo_root/scripts/lib/ps-skills.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
grep -Fq 'npm view npm version --fetch-retries=0 --fetch-timeout=10000' "$tmpl" || fail "the npm registry question must be bounded (--fetch-retries=0 --fetch-timeout=10000)"
grep -Fq "Test-DotCheckRecent -Name 'npm-registry'" "$tmpl" || fail "the npm registry question must be remembered for a day"
grep -Fq "Test-Path -LiteralPath (Join-Path \$ocConfigDir 'node_modules\\superpowers\\package.json')" "$tmpl" || fail "the OpenCode Superpowers npm install must run only when it is missing"
grep -Fq 'Test-Path -LiteralPath "$env:USERPROFILE\.serena\serena_config.yml"' "$tmpl" || fail "serena init must run only while Serena has no config"
grep -Fq "Get-DotCheckValue -Name 'agent-browser-setup'" "$tmpl" || fail "agent-browser's browser setup must be stamped with the version"
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# the real function text, sliced from the template (it holds no template actions)
tr -d '\r' <"$tmpl" | awk '/^function Invoke-NpmUpgradeOnce \{/{f=1} f{print} f && /^\}$/{exit}' >"$tmp/npm-fn.ps1"
[ -s "$tmp/npm-fn.ps1" ] || fail "could not extract Invoke-NpmUpgradeOnce from the installer"

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Skills, [string]$Fn, [string]$State)
$ErrorActionPreference = 'Stop'
$env:XDG_STATE_HOME = $State
. $Skills
function Out($label, $value) { Write-Output ("$label=$value") }

# the stamp helpers
Out 'absent' (Test-DotCheckRecent -Name 'probe')
Write-DotCheckStamp -Name 'probe' -Value '1.2.3'
Out 'fresh' (Test-DotCheckRecent -Name 'probe')
Out 'value' (Get-DotCheckValue -Name 'probe')
(Get-Item -LiteralPath (Get-DotCheckStampPath -Name 'probe')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-30)
Out 'old' (Test-DotCheckRecent -Name 'probe')
Out 'old-but-longer-window' (Test-DotCheckRecent -Name 'probe' -Hours 48)
(Get-Item -LiteralPath (Get-DotCheckStampPath -Name 'probe')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(5)
Out 'future' (Test-DotCheckRecent -Name 'probe')
Out 'missing-value' ('[' + (Get-DotCheckValue -Name 'nothing') + ']')

# the npm question
$script:viewCalls = @()
$script:installs = 0
$script:latest = '10.9.0'
function npm {
    if ($args[0] -eq '-v') { '10.9.0'; return }
    if ($args[0] -eq 'view') { $script:viewCalls += ($args -join ' '); $script:latest; return }
    if ($args[0] -eq 'install') { $script:installs++ }
}
function Invoke-Quietly { param([string]$Description, [scriptblock]$Action) & $Action }
function Add-DotTimingMark { param($Name) $script:DotTimingLast = $Name }
$script:DotTimingLast = 'Node.js'
. $Fn
function Run { $script:NpmUpgraded = $false; (Invoke-NpmUpgradeOnce *>&1 | Out-String).Trim() }

Remove-Item -LiteralPath (Get-DotCheckStampPath -Name 'npm-registry') -ErrorAction SilentlyContinue
$first = Run
Out 'first-asks' $script:viewCalls.Count
Out 'first-bounded' ($script:viewCalls[0] -match '--fetch-retries=0 --fetch-timeout=10000')
Out 'first-says-current' ($first -match 'npm is current \(10\.9\.0\)')
$script:viewCalls = @()
$second = Run
Out 'second-asks' $script:viewCalls.Count
Out 'second-says' ($second -match 'checked within the last day')
Out 'section-resumes' $script:DotTimingLast
# another npm version invalidates the stamp
Write-DotCheckStamp -Name 'npm-registry' -Value '10.8.0'
$script:viewCalls = @()
$null = Run
Out 'other-version-asks' $script:viewCalls.Count
# behind: asked, upgraded, no stamp
Remove-Item -LiteralPath (Get-DotCheckStampPath -Name 'npm-registry') -ErrorAction SilentlyContinue
$script:latest = '11.0.0'
$script:installs = 0
$null = Run
Out 'behind-installs' $script:installs
Out 'behind-no-stamp' (-not (Test-DotCheckRecent -Name 'npm-registry'))
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Skills "$(winpath "$skills")" -Fn "$(winpath "$tmp/npm-fn.ps1")" -State "$(winpath "$tmp/state")" 2>&1 | tr -d '\r')" || fail "the harness must run: $out"
expect() { if printf '%s\n' "$out" | grep -Fxq "$1"; then pass; else fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))"; fi; }
expect 'absent=False'
expect 'fresh=True'
expect 'value=1.2.3'
expect 'old=False'
expect 'old-but-longer-window=True'
expect 'future=False'
expect 'missing-value=[]'
expect 'first-asks=1'
expect 'first-bounded=True'
expect 'first-says-current=True'
expect 'second-asks=0'
expect 'second-says=True'
expect 'section-resumes=Node.js'
expect 'other-version-asks=1'
expect 'behind-installs=1'
expect 'behind-no-stamp=True'

finish
