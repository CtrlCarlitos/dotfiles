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
Write-Output ('graft-crlf=' + (Get-GraftCurrentVersion -VersionOutput "graft 0.21.1`r`nlatest: 0.21.1`r`n"))
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

finish
