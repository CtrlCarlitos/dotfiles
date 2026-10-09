#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# `dot upgrade` reinstalled things that were already current: the codex `npm install -g`
# (~9 s) on every run. The Windows decision logic is EXECUTED here with a fake npm:
#   Test-NpmGlobalCurrent    installed (npm ls -g) == registry (npm view)
#   Get-ChocoUpgradeArgument the `choco upgrade all` argument list
# Anything unknown - empty answers, an unreachable registry - means "not current", so the
# install still happens exactly as before.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:ls = $null
$script:view = $null
function npm { if ($args[0] -eq 'ls') { $script:ls } elseif ($args[0] -eq 'view') { $script:view } }
function Case($label, $lsOut, $viewOut, $pkg = '@openai/codex') {
    $script:ls = $lsOut
    $script:view = $viewOut
    $r = Test-NpmGlobalCurrent -Package $pkg
    Write-Output ("$label=" + $r + ' ' + $script:NpmCurrentVersion)
}
$json = '{"dependencies":{"@openai/codex":{"version":"9.9.9"}}}'
Case 'current' $json '9.9.9'
Case 'stale' $json '9.9.10'
Case 'not-installed' '{}' '9.9.9'
Case 'no-ls-output' $null '9.9.9'
Case 'registry-silent' $json $null
Case 'whitespace' $json "9.9.9`n"
Case 'other-package' '{"dependencies":{"left-pad":{"version":"1.0.0"}}}' '9.9.9'

# Get-ChocoUpgradeArgument: choco's `claude` package (Claude Desktop) ends its installer
# with `taskkill /F /IM claude.exe /T`, which kills EVERY claude.exe - Claude Code
# sessions included. While one runs, that package is left out of the sweep.
$script:procs = @()
function Get-Process { param([Parameter(Position = 0)][string[]]$Name) foreach ($n in $Name) { $script:procs | Where-Object { $_.ProcessName -eq $n } } }
# A scratch Chocolatey lib: both packages installed there unless removed below.
$lib = Join-Path ([IO.Path]::GetTempPath()) ('choco-lib-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path (Join-Path $lib 'claude'), (Join-Path $lib 'docker-desktop') | Out-Null
$script:procs = @()
Write-Output ('choco-idle=' + ((Get-ChocoUpgradeArgument -ChocoLib $lib) -join ' '))
$script:procs = @([pscustomobject]@{ ProcessName = 'claude'; Path = 'C:\x\.local\bin\claude.exe' })
Write-Output ('choco-claude-running=' + ((Get-ChocoUpgradeArgument -ChocoLib $lib) -join ' '))
$script:procs = @([pscustomobject]@{ ProcessName = 'codex'; Path = 'C:\x\codex.exe' })
Write-Output ('choco-other-agent=' + ((Get-ChocoUpgradeArgument -ChocoLib $lib) -join ' '))
# Docker Desktop kept running (its installer cannot replace a running app): left out too.
$script:procs = @()
Write-Output ('choco-keep-docker=' + ((Get-ChocoUpgradeArgument -KeepDockerDesktop -ChocoLib $lib) -join ' '))
$script:procs = @([pscustomobject]@{ ProcessName = 'claude'; Path = 'C:/x/.local/bin/claude.exe' })
Write-Output ('choco-claude-and-docker=' + ((Get-ChocoUpgradeArgument -KeepDockerDesktop -ChocoLib $lib) -join ' '))
# Both moved to winget (no lib folder): nothing to exclude, or Chocolatey warns "not found".
Remove-Item -Recurse -Force (Join-Path $lib 'claude'), (Join-Path $lib 'docker-desktop')
Write-Output ('choco-winget-owned=' + ((Get-ChocoUpgradeArgument -KeepDockerDesktop -ChocoLib $lib) -join ' '))
Remove-Item -Recurse -Force $lib
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }

expect 'current=True 9.9.9'
expect 'stale=False '
expect 'not-installed=False '
expect 'no-ls-output=False '
expect 'registry-silent=False '
expect 'whitespace=True 9.9.9'
expect 'other-package=False '
expect 'choco-idle=upgrade all -y --no-progress'
expect 'choco-claude-running=upgrade all -y --no-progress --except=claude'
expect 'choco-keep-docker=upgrade all -y --no-progress --except=docker-desktop'
expect 'choco-claude-and-docker=upgrade all -y --no-progress --except=claude,docker-desktop'
expect 'choco-other-agent=upgrade all -y --no-progress'
expect 'choco-winget-owned=upgrade all -y --no-progress'
pass

finish
