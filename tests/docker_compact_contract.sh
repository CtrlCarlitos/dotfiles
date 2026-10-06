#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell source and template text are literal
set -euo pipefail

# `dot docker-compact` (Windows): Docker Desktop's docker_data.vhdx never shrinks on its own.
# The command stops Docker (VS Code first), shuts WSL down and compacts the disk with
# Optimize-VHD, falling back to diskpart. This pins (executed against fakes):
#   - nothing is stopped or compacted without a y;
#   - VS Code is closed before Docker, then WSL is shut down, then the disk is compacted;
#   - Optimize-VHD first; diskpart only when it is missing or fails;
#   - a VS Code hosting this terminal is never closed;
#   - no disk means nothing to do;
# and the wiring: both PowerShell profiles dispatch it, the installer enables only the Hyper-V
# PowerShell module (never the Hyper-V platform, never with -All).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
ps_t="$repo_root/run_onchange_install_packages.ps1.tmpl"

# --- wiring -----------------------------------------------------------------------------------------
for p in "$repo_root/Documents/PowerShell/Microsoft.PowerShell_profile.ps1" "$repo_root/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1"; do
    grep -Fq "'docker-compact' { & (Join-Path \$repoScripts 'docker-compact.ps1') @rest }" "$p" || fail "$p: dot docker-compact is not dispatched"
    grep -Fq "'dot docker-compact'" "$p" || fail "$p: dot help does not list docker-compact"
done
[ -f "$repo_root/scripts/docker-compact.ps1" ] || fail "scripts/docker-compact.ps1 is missing"
grep -Fq 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -NoRestart' "$ps_t" ||
    fail "installer: the Hyper-V PowerShell module (Optimize-VHD) must be enabled when missing"
if grep -Eq 'Enable-WindowsOptionalFeature[^\n]*(Microsoft-Hyper-V-All|-FeatureName Microsoft-Hyper-V |-All)' "$ps_t"; then
    fail "installer: must never enable the Hyper-V platform (Docker runs on WSL 2)"
fi
pass

# --- executed ---------------------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$Dir)
Set-StrictMode -Version Latest
. $Lib
$disk = Join-Path $Dir 'docker_data.vhdx'
$script:events = @(); $script:answers = @(); $script:optimizeOk = $true; $script:optimizePresent = $true
$script:docker = @(); $script:vs = @()
function Read-Host { param($Prompt) $a = $script:answers[0]; $script:answers = @($script:answers | Select-Object -Skip 1); return $a }
function Get-VsCodeProcess { return @($script:vs) }
function Stop-VsCode { param($Process, $GraceSeconds) $script:events += 'vscode:' + (($Process | ForEach-Object { $_.Id }) -join '+'); return $true }
function Get-DockerDesktopProcess { return @($script:docker) }
function Stop-DockerDesktop { $script:events += 'docker:stop'; $script:docker = @(); return $true }
function wsl { $script:events += 'wsl:' + ($args -join ' ') }
function Invoke-OptimizeVhdCompact { param($Path) if (-not $script:optimizePresent) { return $false }; $script:events += 'optimize'; if ($script:optimizeOk) { Set-Content -LiteralPath $Path -Value 'x' }; return $script:optimizeOk }
function Invoke-DiskpartCompact { param($Path) $script:events += 'diskpart'; Set-Content -LiteralPath $Path -Value 'x'; return $true }
function Reset([string[]]$Answers) {
    Set-Content -LiteralPath $disk -Value ('y' * 4096)
    $script:events = @(); $script:answers = $Answers
    $script:docker = @([pscustomobject]@{ Id = 500 }); $script:vs = @([pscustomobject]@{ Id = 7 }, [pscustomobject]@{ Id = 8 })
}
function Line([string]$Label, $Result) { Write-Output ("$Label=" + $Result + '|' + ($script:events -join ',')) }

Reset @('n');  Line 'decline' (Invoke-DockerDiskCompact -Path $disk 6>$null)
Reset @('');   Line 'default' (Invoke-DockerDiskCompact -Path $disk 6>$null)
Reset @('y');  Line 'yes' (Invoke-DockerDiskCompact -Path $disk 6>$null)
Reset @();     Line 'flag' (Invoke-DockerDiskCompact -Path $disk -Yes 6>$null)
Reset @('y');  $script:optimizeOk = $false; Line 'optimize-fails' (Invoke-DockerDiskCompact -Path $disk 6>$null); $script:optimizeOk = $true
Reset @('y');  $script:optimizePresent = $false; Line 'no-optimize' (Invoke-DockerDiskCompact -Path $disk 6>$null); $script:optimizePresent = $true
Reset @('y');  Line 'host' (Invoke-DockerDiskCompact -Path $disk -ExcludeId @(8) 6>$null)
Reset @('y');  Line 'no-disk' (Invoke-DockerDiskCompact -Path (Join-Path $Dir 'missing.vhdx') 6>$null)
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -Dir "$(winpath "$tmp")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }
    expect 'decline=False|'
    expect 'default=False|'
    expect 'yes=True|vscode:7+8,docker:stop,wsl:--shutdown,optimize'
    expect 'flag=True|vscode:7+8,docker:stop,wsl:--shutdown,optimize'
    expect 'optimize-fails=True|vscode:7+8,docker:stop,wsl:--shutdown,optimize,diskpart'
    expect 'no-optimize=True|vscode:7+8,docker:stop,wsl:--shutdown,diskpart'
    expect 'host=True|vscode:7,docker:stop,wsl:--shutdown,optimize'
    expect 'no-disk=False|'
    pass
else
    printf 'note: pwsh not installed - executed checks skipped\n'
fi

finish
