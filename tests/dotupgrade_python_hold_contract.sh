#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Found in a live `dot upgrade` (2026-10-10): `choco upgrade all` moved python, python3 and
# python315 from 3.14.8 to 3.15.0. A new Python minor breaks venvs, uv tools and pipx
# environments, so it is held out of the sweep (patch releases still flow) unless the operator
# sets DOTUPGRADE_PYTHON_MINOR=1. Executed against fake `choco outdated` lines.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
Remove-Item Env:DOTUPGRADE_PYTHON_MINOR -ErrorAction SilentlyContinue

$minor = @('python|3.14.8|3.15.0|false', 'python3|3.14.8|3.15.0|false', 'git|2.50.0|2.51.0|false')
Write-Output ('minor=' + ((Get-ChocoPythonMinorHold -OutdatedLine $minor) -join ','))
$patch = @('python|3.14.8|3.14.9|false', 'python314|3.14.8|3.14.9|false')
Write-Output ('patch=[' + ((Get-ChocoPythonMinorHold -OutdatedLine $patch) -join ',') + ']')
$junk = @('pythonista|1.0|2.0|false', 'python|||false', 'Chocolatey v2.5.0')
Write-Output ('junk=[' + ((Get-ChocoPythonMinorHold -OutdatedLine $junk) -join ',') + ']')

$lib = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $lib | Out-Null
$argsHeld = @(Get-ChocoUpgradeArgument -ChocoLib $lib -OutdatedLine $minor 6>$null)
Write-Output ('args=' + ($argsHeld -join ' '))
$env:DOTUPGRADE_PYTHON_MINOR = '1'
$argsTaken = @(Get-ChocoUpgradeArgument -ChocoLib $lib -OutdatedLine $minor 6>$null)
Write-Output ('taken=' + ($argsTaken -join ' '))
Remove-Item Env:DOTUPGRADE_PYTHON_MINOR
Remove-Item -Recurse -Force $lib
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))"; }

expect 'minor=python,python3'
expect 'patch=[]'
expect 'junk=[]'
expect 'args=upgrade all -y --no-progress --except=python,python3'
expect 'taken=upgrade all -y --no-progress'
pass

finish
