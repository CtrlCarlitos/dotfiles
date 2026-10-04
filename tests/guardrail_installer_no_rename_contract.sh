#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the extracted PowerShell runs in its own process
set -euo pipefail

# The Windows installer used to MOVE the installed guardrail.exe aside before every run
# (guardrail.exe.old-<stamp>) and then let the upstream installer download the same
# release again. Two costs: the swap resets guardrail's evidence window ("hook registered
# but NEVER OBSERVED FIRING" after every dot up), and because the binary was gone the
# upstream installer took its fresh-download path instead of `guardrail update`, which is
# the sanctioned replacement (it does nothing when the tag already matches, replaces a
# running binary itself, and keeps the previous one for `guardrail rollback`).
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

$guardrailVersion = 'v9.9.9-test'
$guardrailRepo = 'example/guardrail'
$binDir = Join-Path $HomeDir '.local\bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
$bin = Join-Path $binDir 'guardrail.exe'
Set-Content -LiteralPath $bin -Value 'installed-binary' -Encoding ascii
$legacy = Join-Path $binDir 'guardrail.exe.old-20260101000000'
Set-Content -LiteralPath $legacy -Value 'legacy set-aside copy' -Encoding ascii

# The download job is replaced by a stub that "downloads" a fake upstream installer and
# its checksum; the upstream installer itself is a function named like the executable.
function Invoke-WithTimeout {
    param([string]$Description, [int]$Seconds, [scriptblock]$Action, [switch]$NoStream)
    $fake = Join-Path $env:GUARDRAIL_TMP 'install.ps1'
    Set-Content -LiteralPath $fake -Value 'exit 0' -Encoding ascii
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $fake).Hash
    Set-Content -LiteralPath (Join-Path $env:GUARDRAIL_TMP 'SHA256SUMS') -Value "$hash  install.ps1" -Encoding ascii
}
$script:seen = ''
function powershell { $script:seen = ($args -join ' '); $global:LASTEXITCODE = 0 }

Invoke-GuardrailInstaller -State enabled | Out-Null

Write-Output ("binary-in-place=" + (Test-Path -LiteralPath $bin))
Write-Output ("binary-content=" + ((Get-Content -LiteralPath $bin) -join ''))
Write-Output ("moved-aside=" + @(Get-ChildItem -LiteralPath $binDir -Filter 'guardrail.exe.old-*' -File | Where-Object { $_.Name -ne 'guardrail.exe.old-20260101000000' }).Count)
Write-Output ("upstream-called=" + ($script:seen -match '-Version v9\.9\.9-test' -and $script:seen -match '-State enabled'))
Write-Output ("legacy-swept=" + (-not (Test-Path -LiteralPath $legacy)))
PSEOF

home="$tmp/home"
mkdir -p "$home"
out="$(HOME="$home" USERPROFILE="$home" pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Rendered "$(winpath "$tmp/installer.ps1")" -HomeDir "$(winpath "$home")" 2>&1 | tr -d '\r')"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }

expect 'binary-in-place=True'
expect 'binary-content=installed-binary'
expect 'moved-aside=0'
expect 'upstream-called=True'
# The leftover copies the OLD scheme made are still cleaned up. On Linux pwsh the
# backslash paths are plain file names in one directory, so the sweep cannot see them.
if [ "${OS:-}" = Windows_NT ]; then expect 'legacy-swept=True'; fi

finish
