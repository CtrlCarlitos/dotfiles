#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# `dot up` (2026-10-09) printed ~25 lines for `choco install nerd-fonts-FiraCode` and ~12 for
# `winget install charmbracelet.gum`, while every other step is one line. The installers still
# stream (a hung one must stay visible) but boilerplate is hidden, everything is kept in
# ~\.local\state\dotfiles\install.log, and anything that is not known success boilerplate - above
# all a failure - still shows. scripts/lib/ps-installer-output.ps1 is EXECUTED here on the real
# output from that run, through the same job-side filter the installer pipes into.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Home2)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib
Initialize-InstallerOutput -Root $Home2
Write-Output ('log-path=' + ($env:DOT_INSTALLER_LOG -like '*dotfiles*install.log'))

function Invoke-Filter([string[]]$Lines) { @($Lines | & ([scriptblock]::Create("$env:DOT_INSTALLER_FILTER"))) }

$choco = @(
    '    Chocolatey v2.7.4',
    '    3 validations performed. 2 success(es), 1 warning(s), and 0 error(s).',
    '',
    '    Validation Warnings:',
    '     - A pending system reboot request has been detected, however, this is',
    '       being ignored due to the current Chocolatey configuration.  If you',
    '       want to halt when this occurs, then either set the global feature',
    '       using:',
    '         choco feature enable --name="exitOnRebootDetected"',
    '       or pass the option --exit-when-reboot-detected.',
    '',
    '    Installing the following packages:',
    '    nerd-fonts-FiraCode',
    '    By installing, you accept licenses for the packages.',
    "    Downloading package from source 'https://community.chocolatey.org/api/v2/'",
    '',
    '    nerd-fonts-FiraCode v3.5.1 [Approved]',
    '    nerd-fonts-FiraCode package files install completed. Performing other installation steps.',
    '    Downloading nerd-fonts-FiraCode',
    "      from 'https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/FiraCode.zip'",
    '',
    '    Download of FiraCode.zip (27.28 MB) completed.',
    '    Hashes match.',
    '    Extracting C:\Users\x\AppData\Local\Temp\chocolatey\nerd-fonts-FiraCode\3.5.1\FiraCode.zip to C:\ProgramData\chocolatey\lib\nerd-fonts-FiraCode\tools...',
    '    C:\ProgramData\chocolatey\lib\nerd-fonts-FiraCode\tools',
    '    18 fonts installed',
    '     The install of nerd-fonts-FiraCode was successful.',
    "      Deployed to 'C:\ProgramData\chocolatey\lib\nerd-fonts-FiraCode\tools'",
    '',
    '    Chocolatey installed 1/1 packages.',
    '     See the log for details (C:\ProgramData\chocolatey\logs\chocolatey.log).'
)
$shown = Invoke-Filter $choco
Write-Output ('choco-shown=' + ($shown -join '|'))
Write-Output ('choco-reduced=' + ($shown.Count -le 5))

$bar = [string][char]0x2588 * 8
$winget = @(
    'Found gum [charmbracelet.gum] Version 2.0.1',
    'This application is licensed to you by its owner.',
    'Microsoft is not responsible for, nor does it grant any licenses to, third-party packages.',
    'Downloading https://github.com/charmbracelet/gum/releases/download/v2.0.1/gum_2.0.1_Windows_x86_64.zip',
    "  $bar  50%",
    '  12.3 MB / 45.6 MB',
    '  -',
    'Successfully verified installer hash',
    'Extracting archive...',
    'Successfully extracted archive',
    'Starting package install...',
    'Command line alias added: "gum"',
    'Successfully installed'
)
Write-Output ('winget-shown=' + ((Invoke-Filter $winget) -join '|'))

# Failures are never hidden
$failed = Invoke-Filter @('Chocolatey v2.7.4', 'Chocolatey installed 0/1 packages. ', 'Failures', ' - foo - foo not installed. An error occurred during installation:', 'Installer failed with exit code: 1', 'Setup has detected that Visual Studio Code is currently running.')
Write-Output ('failure-kept=' + (($failed -join '|') -match 'Installer failed with exit code: 1' -and ($failed -join '|') -match '0/1 packages' -and ($failed -join '|') -match 'not installed'))
Write-Output ('failure-banner-hidden=' + (-not (($failed -join '|') -match 'Chocolatey v2')))
Write-Output ('partial-success-kept=' + @(Invoke-Filter @('Chocolatey installed 1/2 packages.')).Count)

# Everything lands in the log, noise included
$logText = Get-Content -Raw -LiteralPath $env:DOT_INSTALLER_LOG
Write-Output ('log-has-noise=' + (($logText -match 'Hashes match') -and ($logText -match 'licensed to you')))
Write-Output ('log-has-signal=' + ($logText -match '18 fonts installed'))

# A log that cannot be written never costs output
$env:DOT_INSTALLER_LOG = Join-Path $Home2 'no\such\dir\x.log'
Write-Output ('log-unwritable-still-shows=' + ((Invoke-Filter @('18 fonts installed')) -join '|'))
$env:DOT_INSTALLER_LOG = ''
Write-Output ('log-empty-still-shows=' + ((Invoke-Filter @('18 fonts installed')) -join '|'))

# the reboot note is a plain function: it must at least run without throwing
Write-PendingRebootNote
Write-Output 'reboot-note-ran=True'
PSEOF

mkdir -p "$tmp/home"
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-installer-output.ps1")" -Home2 "$(winpath "$tmp/home")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))"; }

expect 'log-path=True'
expect 'choco-shown=    nerd-fonts-FiraCode|    nerd-fonts-FiraCode v3.5.1 [Approved]|    C:\ProgramData\chocolatey\lib\nerd-fonts-FiraCode\tools|    18 fonts installed'
expect 'choco-reduced=True'
expect 'winget-shown=Found gum [charmbracelet.gum] Version 2.0.1|Successfully installed'
expect 'failure-kept=True'
expect 'failure-banner-hidden=True'
expect 'partial-success-kept=1'
expect 'log-has-noise=True'
expect 'log-has-signal=True'
expect 'log-unwritable-still-shows=18 fonts installed'
expect 'log-empty-still-shows=18 fonts installed'
expect 'reboot-note-ran=True'
pass

# --- wiring: the template includes the helpers before use, and every installer goes through the filter ---
tpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
grep -Fq '{{ include "scripts/lib/ps-installer-output.ps1" }}' "$tpl" || fail "the installer must inline ps-installer-output.ps1"
grep -Fq 'Initialize-InstallerOutput' "$tpl" || fail "the installer must call Initialize-InstallerOutput"
grep -Fq 'Write-PendingRebootNote' "$tpl" || fail "the installer must say a pending restart once"
unfiltered="$(tr -d '\r' <"$tpl" | grep -E '^\s*(winget install|choco install)\b' | grep -v 'DOT_INSTALLER_FILTER' | grep -Ev -- '(--version=|\| Out-Null)' || true)"
[ -z "$unfiltered" ] || fail "these installer calls bypass the output filter: $unfiltered"
pass

finish
