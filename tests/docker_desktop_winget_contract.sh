#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell source and template text are literal
set -euo pipefail

# Docker Desktop on Windows is winget's (Docker.DockerDesktop, Docker's own EXE installer), not
# Chocolatey's: the Chocolatey package installs Docker's MSI, lagged Docker's releases (4.93.0
# while 4.94.0 was out) and `winget upgrade` refuses a Chocolatey copy ("install technology is
# different"). This pins:
#   - the catalog names no Chocolatey package for it;
#   - the installer installs it through winget and never replaces a Chocolatey copy itself
#     (uninstalling that can take the data disk with it - the move is manual, in docs);
#   - Get-DockerDesktopOwner tells choco / winget / not installed apart (executed, fakes);
#   - a Docker Desktop kept running is pinned for the winget sweep and unpinned after, and a
#     pin the operator already had is left alone (executed, fakes);
#   - dot upgrade wires both and says when a machine still has the Chocolatey copy.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"
du="$repo_root/scripts/dotupgrade.ps1"

# --- catalog and installer ----------------------------------------------------------------------
rec="$(awk '/^    - id: docker-desktop$/ {f=1; next} f && /^    - id: / {exit} f' "$repo_root/.chezmoidata/packages.yaml")"
if printf '%s\n' "$rec" | grep -q '^      choco:'; then fail "catalog: docker-desktop must not name a Chocolatey package (winget owns it on Windows)"; fi
printf '%s\n' "$rec" | grep -Fq 'cask: docker' || fail "catalog: macOS keeps the docker cask"
grep -Fq 'winget install --id Docker.DockerDesktop --exact --source winget' "$ps_t" || fail "installer: Docker Desktop must be installed through winget"
if grep -Eq 'choco (uninstall|install)[^\n]*docker-desktop' "$ps_t"; then fail "installer: must never install or uninstall Chocolatey's docker-desktop itself"; fi
awk '/chocoDockerList -match/{a=NR} /winget install --id Docker.DockerDesktop/{b=NR} END{exit !(a && b && a<b)}' "$ps_t" ||
    fail "installer: a Chocolatey copy must be detected before any winget install"
pass

# --- dot upgrade wiring ---------------------------------------------------------------------------
grep -Fq "if (\$dockerOwner -eq 'choco')" "$du" || fail "dotupgrade.ps1 must say when Docker Desktop is still Chocolatey's"
grep -Fq "if (\$dockerKept) { \$wingetHold += 'Docker.DockerDesktop' }" "$du" || fail "dotupgrade.ps1 must hold a kept-running Docker Desktop out of the winget sweep"
grep -Fq "\$wingetHold += 'Anthropic.Claude'" "$du" || fail "dotupgrade.ps1 must hold Claude Desktop out of the winget sweep while a claude.exe runs"
grep -Fq -- '-HoldId $wingetHold' "$du" || fail "dotupgrade.ps1 must pass the hold to Invoke-WingetUpgradeAll"
grep -Fq -- 'Get-DockerDesktopUpgrade -Owner $dockerOwner' "$du" || fail "dotupgrade.ps1 must probe only the manager that owns Docker Desktop"
pass

# --- executed: owner probe and the winget hold ---------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Log)
Set-StrictMode -Version Latest
. $Lib
$script:chocoOut = @(); $script:wingetList = @(); $script:pins = @(); $script:calls = @()
$script:chocoCalls = 0
function choco { $script:chocoCalls++; $script:chocoOut | ForEach-Object { $_ }; $global:LASTEXITCODE = 0 }
function winget {
    $line = ($args -join ' ')
    if ($args[0] -eq 'list') { $script:wingetList | ForEach-Object { $_ }; $global:LASTEXITCODE = 0; return }
    if ($args[0] -eq 'pin' -and $args[1] -eq 'list') { $script:pins | ForEach-Object { $_ }; $global:LASTEXITCODE = 0; return }
    $script:calls += $line
    $global:LASTEXITCODE = 0
}
# Chocolatey's ownership comes from its lib folder (instant), never a `choco list` (~1.9 s)
$lib = Join-Path ([IO.Path]::GetTempPath()) ('choco-lib-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path (Join-Path $lib 'docker-desktop') | Out-Null
$script:chocoCalls = 0
$script:wingetList = @('Docker Desktop Docker.DockerDesktop 4.93.0 4.94.0 winget')
Write-Output ('owner-choco=' + (Get-DockerDesktopOwner -ChocoLib $lib))
Remove-Item -Recurse -Force (Join-Path $lib 'docker-desktop')
Write-Output ('owner-winget=' + (Get-DockerDesktopOwner -ChocoLib $lib))
$script:wingetList = @('No installed package found matching input criteria.')
Write-Output ('owner-none=[' + (Get-DockerDesktopOwner -ChocoLib $lib) + ']')
Write-Output ('owner-no-choco-call=' + $script:chocoCalls)
Remove-Item -Recurse -Force $lib

# only the owner is probed for a pending Docker Desktop upgrade
$script:calls = @(); $script:chocoCalls = 0
$null = Get-DockerDesktopUpgrade -Owner 'winget'
Write-Output ('probe-winget-owner=' + $script:chocoCalls + '|' + @($script:calls | Where-Object { $_ -match '^upgrade --id Docker' }).Count)
$script:calls = @(); $script:chocoCalls = 0
$null = Get-DockerDesktopUpgrade -Owner 'choco'
Write-Output ('probe-choco-owner=' + $script:chocoCalls + '|' + @($script:calls | Where-Object { $_ -match '^upgrade --id Docker' }).Count)

$script:calls = @()
$null = Invoke-WingetUpgradeAll -LogPath $Log -HoldId @('Docker.DockerDesktop')
Write-Output ('hold=' + (($script:calls | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ','))
Write-Output ('hold-id=' + ([bool]($script:calls | Where-Object { $_ -match '^pin add --id Docker\.DockerDesktop --exact' })) + '|' + ([bool]($script:calls | Where-Object { $_ -match '^pin remove --id Docker\.DockerDesktop --exact' })))
$script:calls = @(); $script:pins = @('Docker Desktop Docker.DockerDesktop 4.93.0')
$null = Invoke-WingetUpgradeAll -LogPath $Log -HoldId @('Docker.DockerDesktop')
Write-Output ('own-pin=' + (($script:calls | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ','))
$script:calls = @(); $script:pins = @()
$null = Invoke-WingetUpgradeAll -LogPath $Log
Write-Output ('no-hold=' + (($script:calls | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' }) -join ','))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -Log "$(winpath "$tmp/upgrade.log")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'owner-choco=choco'
    expect 'owner-winget=winget'
    expect 'owner-none=[]'
    expect 'owner-no-choco-call=0'
    expect 'probe-winget-owner=0|1'
    expect 'probe-choco-owner=1|0'
    expect 'hold=pin add,upgrade --all,pin remove,upgrade --include-unknown'
    expect 'hold-id=True|True'
    expect 'own-pin=upgrade --all,upgrade --include-unknown'
    expect 'no-hold=upgrade --all,upgrade --include-unknown'
    pass
else
    printf 'note: pwsh not installed - executed checks skipped\n'
fi

finish
