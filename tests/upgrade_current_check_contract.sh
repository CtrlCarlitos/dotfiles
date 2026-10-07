#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# `dot upgrade` reinstalled things that were already current: `graft upgrade` (0.21.1 ->
# 0.21.1 took 41 s on WSL) and the codex `npm install -g` (~9 s), on every run. The unix
# updater now asks first (covered by tests/agent_tool_upgrade_contract.sh); this is the
# PowerShell twin's decision logic in scripts/lib/ps-common.ps1, EXECUTED with a fake npm:
#   Test-NpmGlobalCurrent  installed (npm ls -g) == registry (npm view)
#   Get-GraftCurrentVersion  `graft version` prints "graft X" and "latest: Y"
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

Write-Output ('graft-current=' + (Get-GraftCurrentVersion -VersionOutput "graft 0.21.1`nlatest: 0.21.1`n"))
Write-Output ('graft-stale=[' + (Get-GraftCurrentVersion -VersionOutput "graft 0.18.0`nlatest: 0.21.1`n") + ']')
Write-Output ('graft-offline=[' + (Get-GraftCurrentVersion -VersionOutput "graft 0.21.1`nlatest: unreachable (offline?)`n") + ']')
Write-Output ('graft-empty=[' + (Get-GraftCurrentVersion -VersionOutput '') + ']')
Write-Output ('graft-crlf=' + (Get-GraftCurrentVersion -VersionOutput "graft 0.21.1`r`nlatest on npm: 0.21.1 $([char]0x2713) up to date`r`n"))
# The ONLINE spelling, as graft 0.21.1 prints it (the offline one is 'latest: unreachable').
Write-Output ('graft-online=' + (Get-GraftCurrentVersion -VersionOutput "graft 0.21.1`nlatest on npm: 0.21.1 $([char]0x2713) up to date`n"))
Write-Output ('graft-online-stale=[' + (Get-GraftCurrentVersion -VersionOutput "graft 0.18.0`nlatest on npm: 0.21.1 (update available)`n") + ']')

# Invoke-GraftNpmInstall: `graft upgrade` fails on Windows (spawnSync npm ENOENT), so the
# npm install it wraps is run directly, with the allow-list in the environment only for
# the call, and npm's exit code handed back.
$script:npmCalls = @()
$script:npmExit = 0
function npm {
    # npm prints a summary line on stdout, like the real one ("changed 44 packages in 1m"): the
    # function must not let it leak into its return value.
    if ($args[0] -eq 'install') { $script:npmCalls += (($args -join ' ') + ' allow=' + $env:NPM_CONFIG_ALLOW_SCRIPTS); $global:LASTEXITCODE = $script:npmExit; 'changed 44 packages in 1m'; return }
    if ($args[0] -eq 'ls') { $script:ls } elseif ($args[0] -eq 'view') { $script:view }
}
$env:NPM_CONFIG_ALLOW_SCRIPTS = 'keep-me'
$exit = Invoke-GraftNpmInstall -AllowScripts 'tree-sitter-x,esbuild'
Write-Output ('graft-install-exit=' + $exit)
Write-Output ('graft-install-scalar=' + (($exit -is [int]) -and (@($exit).Count -eq 1)))
Write-Output ('graft-install-call=' + ($script:npmCalls -join '|'))
Write-Output ('graft-install-env-restored=' + $env:NPM_CONFIG_ALLOW_SCRIPTS)
Remove-Item Env:NPM_CONFIG_ALLOW_SCRIPTS -ErrorAction SilentlyContinue
$script:npmExit = 3
Write-Output ('graft-install-fail-exit=' + (Invoke-GraftNpmInstall -AllowScripts 'a'))
Write-Output ('graft-install-env-cleared=[' + $env:NPM_CONFIG_ALLOW_SCRIPTS + ']')

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
expect 'graft-current=0.21.1'
expect 'graft-stale=[]'
expect 'graft-offline=[]'
expect 'graft-empty=[]'
expect 'graft-crlf=0.21.1'
expect 'graft-online=0.21.1'
expect 'graft-online-stale=[]'
expect 'graft-install-exit=0'
expect 'graft-install-call=install -g @nanonets/graft@latest --loglevel=error --no-progress allow=tree-sitter-x,esbuild'
expect 'graft-install-env-restored=keep-me'
expect 'graft-install-fail-exit=3'
expect 'graft-install-env-cleared=[]'
expect 'choco-idle=upgrade all -y --no-progress'
expect 'choco-claude-running=upgrade all -y --no-progress --except=claude'
expect 'choco-keep-docker=upgrade all -y --no-progress --except=docker-desktop'
expect 'choco-claude-and-docker=upgrade all -y --no-progress --except=claude,docker-desktop'
expect 'graft-install-scalar=True'
expect 'choco-other-agent=upgrade all -y --no-progress'
expect 'choco-winget-owned=upgrade all -y --no-progress'

# On Windows `graft version` answers "latest: unreachable" (it cannot spawn npm.cmd), so the
# graft-text check alone never said "current" there and graft was reinstalled on every run.
# The updater falls back to asking npm directly before reinstalling.
ai_ps1="$repo_root/scripts/update_ai_tools.ps1"
grep -Fq "if (-not \$graftCurrent -and (Test-NpmGlobalCurrent '@nanonets/graft'))" "$ai_ps1" ||
    fail "update_ai_tools.ps1 must ask npm whether graft is current when graft version cannot"
awk '/Test-NpmGlobalCurrent .@nanonets\/graft./{a=NR} /Invoke-GraftNpmInstall -AllowScripts/{b=NR} END{exit !(a && b && a<b)}' "$ai_ps1" ||
    fail "the npm currency fallback must run before the graft reinstall"
pass

finish
