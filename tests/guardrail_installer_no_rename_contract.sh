#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the extracted PowerShell runs in its own process
set -euo pipefail

# The Windows installer used to MOVE the installed guardrail.exe aside before every run
# (guardrail.exe.old-<stamp>) and then let the upstream installer download the same
# release again. Two costs: the swap resets guardrail's evidence window ("hook registered
# but NEVER OBSERVED FIRING" after every dot up), and because the binary was gone the
# upstream installer took its fresh-download path instead of its update path, which is
# the sanctioned replacement (it does nothing when the tag already matches, replaces a
# running binary itself, and keeps the previous one for rollback).
#
# Invoke-GuardrailInstaller is extracted from the rendered template and EXECUTED with the
# network and the upstream installer stubbed. Left alone, an installed binary must stay
# exactly where it is and the upstream installer must be handed the pinned tag and state.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":false,"remote_access_server":false,"guardrail":true,"dev_desktop":false,"vscode_settings":false'
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{$groups},\"accounts\":[]}" \
    <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/installer.ps1"
[ -s "$tmp/installer.ps1" ] || fail 'the installer did not render'

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Rendered, [string]$HomeDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = Get-Content -LiteralPath $Rendered
$start = ($lines | Select-String -Pattern '^function Invoke-GuardrailInstaller \{' | Select-Object -First 1).LineNumber - 1
$end = $start
while ($lines[$end] -ne '}') { $end++ }
Invoke-Expression (($lines[$start..$end]) -join "`n")

# The installer runs the upstream installer through Invoke-GuardrailInstallerProcess (inlined
# from scripts/lib/ps-skills.ps1 together with the hide-list pattern and Write-GuardrailFilteredLine
# it calls): bring in everything from the pattern's declaration through that function's end.
$filterStart = ($lines | Select-String -Pattern '^\$script:GuardrailHidden = 0' | Select-Object -First 1).LineNumber - 1
$filterEnd = ($lines | Select-String -Pattern '^function Invoke-GuardrailInstallerProcess \{' | Select-Object -First 1).LineNumber - 1
while ($lines[$filterEnd] -ne '}') { $filterEnd++ }
Invoke-Expression (($lines[$filterStart..$filterEnd]) -join "`n")

# Windows always has %TEMP%; Linux pwsh does not.
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
$guardrailVersion = 'v9.9.9-test'
$guardrailRepo = 'example/guardrail'
# The installer builds this path with a backslash literal; build it the same way here so
# the harness agrees with it on every platform (on Linux that is one file name in $HOME).
$bin = Join-Path $HOME ".local\bin\guardrail.exe"
$binDir = Split-Path -Parent $bin
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Set-Content -LiteralPath $bin -Value 'installed-binary' -Encoding ascii
$legacy = "$bin.old-20260101000000"
Set-Content -LiteralPath $legacy -Value 'legacy set-aside copy' -Encoding ascii

# The download job is replaced by a stub that "downloads" a fake upstream installer and its
# checksum. Invoke-GuardrailInstaller now runs that installer through Invoke-GuardrailInstallerProcess,
# a REAL child process (that is the entire point of the fix this guards: it bypasses PowerShell's
# own native-command pipeline capture), so it can no longer be intercepted by a same-named
# PowerShell function the way the old `& powershell ...` pipeline could. The fake installer records
# its own invocation instead, into a marker file named over the environment (processes inherit the
# environment, not session variables).
function Invoke-WithTimeout {
    param([string]$Description, [int]$Seconds, [scriptblock]$Action, [switch]$NoStream)
    $fake = Join-Path $env:GUARDRAIL_TMP 'install.ps1'
    Set-Content -LiteralPath $fake -Value '($args -join " ") | Set-Content -LiteralPath $env:GUARDRAIL_TEST_SEEN -Encoding ascii; exit 0' -Encoding ascii
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fake).Hash
    Set-Content -LiteralPath (Join-Path $env:GUARDRAIL_TMP 'SHA256SUMS') -Value "$hash  install.ps1" -Encoding ascii
}
$env:GUARDRAIL_TEST_SEEN = Join-Path $env:TEMP ("guardrail-test-seen-" + [guid]::NewGuid().ToString('N') + '.txt')

Invoke-GuardrailInstaller -State enabled | Out-Null

$seen = if (Test-Path -LiteralPath $env:GUARDRAIL_TEST_SEEN) { Get-Content -LiteralPath $env:GUARDRAIL_TEST_SEEN -Raw } else { '' }
$siblings = @(Get-ChildItem -LiteralPath $binDir -File -Force | Where-Object { $_.Name -like '*guardrail.exe.old-*' -and $_.FullName -ne $legacy })
Write-Output ("binary-in-place=" + (Test-Path -LiteralPath $bin))
Write-Output ("binary-content=" + ((Get-Content -LiteralPath $bin) -join ''))
Write-Output ("moved-aside=" + $siblings.Count)
Write-Output ("upstream-called=" + ($seen -match '-Version v9\.9\.9-test' -and $seen -match '-State enabled'))
Write-Output ("legacy-swept=" + (-not (Test-Path -LiteralPath $legacy)))
Remove-Item -LiteralPath $env:GUARDRAIL_TEST_SEEN -ErrorAction SilentlyContinue
PSEOF

home="$tmp/home"
mkdir -p "$home"

# Invoke-GuardrailInstallerProcess starts 'powershell' as a REAL OS process (.NET
# Process.Start, resolved by PATH like any other bare command) - that bypass is the entire
# point of the fix this test guards, but it means a same-named PowerShell FUNCTION can no
# longer stand in for a missing `powershell` executable the way it could before. Real Windows
# always has powershell.exe; this harness runs through cross-platform pwsh, including on Linux
# CI, where no file named `powershell` exists at all. A one-line shim gives PATH resolution a
# real, executable `powershell` everywhere pwsh itself exists, by forwarding to it verbatim.
shim_dir="$tmp/shim"
mkdir -p "$shim_dir"
printf '#!/bin/sh\nexec pwsh "$@"\n' >"$shim_dir/powershell"
chmod +x "$shim_dir/powershell"

# `|| true`: a harness that throws must show its output in the failure, not end the test silently.
out="$(HOME="$home" USERPROFILE="$home" PATH="$shim_dir:$PATH" pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Rendered "$(winpath "$tmp/installer.ps1")" -HomeDir "$(winpath "$home")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }

expect 'binary-in-place=True'
expect 'binary-content=installed-binary'
expect 'moved-aside=0'
expect 'upstream-called=True'
# The leftover copies the OLD scheme made are still cleaned up. On Linux pwsh the
# backslash paths are plain file names in one directory, so the sweep cannot see them.
if [ "${OS:-}" = Windows_NT ]; then expect 'legacy-swept=True'; fi

finish
