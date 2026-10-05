#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the extracted PowerShell runs in its own process
set -euo pipefail

# The Windows installer printed three "Post-Install" notes on EVERY run, true or not:
# "Launch Docker Desktop once to accept the EULA", "enable WSL Integration for <every
# distro>", and "Sign in to Tailscale manually" - plus "SSH service activation ... manual".
# On a machine where Docker answers, Tailscale is connected and sshd runs, that is noise
# that trains you to skip the one note that matters. Each note now prints only when its
# probe says it still applies, and a probe that cannot tell (a tool missing, a command that
# hangs or fails) prints the note: a hidden problem is worse than a repeated reminder.
#
# The functions are extracted from the RENDERED template and EXECUTED with the probes
# replaced, and the real probes are exercised against real (pwsh) child processes.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false'
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{$groups},\"accounts\":[]}" \
    <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/installer.ps1"
[ -s "$tmp/installer.ps1" ] || fail 'the installer did not render'

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Rendered, [string]$Pwsh)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$lines = Get-Content -LiteralPath $Rendered
function Get-Fn([string]$name) {
    $start = ($lines | Select-String -Pattern "^function $name \{" | Select-Object -First 1).LineNumber - 1
    $end = $start
    while ($lines[$end] -ne '}') { $end++ }
    ($lines[$start..$end]) -join "`n"
}
$names = 'Test-CommandSucceeds', 'Test-DockerEngineUp', 'Get-DockerWslGap', 'Get-DockerWslDistro', 'Write-DockerPostInstallNote',
         'Test-TailscaleConnected', 'Write-RemoteAccessPostInstallNote', 'Test-SshServerRunning', 'Write-SshPostInstallNote'
foreach ($n in $names) { Invoke-Expression (Get-Fn $n) }

function Out-Notes([scriptblock]$Run) { (& $Run *>&1 | Out-String) }

# --- Test-CommandSucceeds against real child processes ---------------------------------
Write-Output ('cmd-ok=' + (Test-CommandSucceeds -Executable $Pwsh -Arguments @('-NoProfile', '-Command', 'exit 0')))
Write-Output ('cmd-fail=' + (Test-CommandSucceeds -Executable $Pwsh -Arguments @('-NoProfile', '-Command', 'exit 3')))
Write-Output ('cmd-missing=' + (Test-CommandSucceeds -Executable 'definitely-not-a-command-xyz' -Arguments @('x')))
$sw = [Diagnostics.Stopwatch]::StartNew()
$hang = Test-CommandSucceeds -Executable $Pwsh -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSeconds 3
$sw.Stop()
Write-Output ('cmd-hang=' + $hang)
Write-Output ('cmd-hang-bounded=' + ($sw.Elapsed.TotalSeconds -lt 20))

# --- Docker notes ------------------------------------------------------------------------
function Test-DockerEngineUp { $script:dockerUp }
function Get-DockerWslDistro { $script:distros }

$script:distros = @('Ubuntu-24.04', 'Ubuntu-20.04')
$settings = Join-Path ([IO.Path]::GetTempPath()) ('docker-settings-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $settings 'Docker') | Out-Null
$env:APPDATA = $settings
function Set-DockerSettings($json) { Set-Content -LiteralPath (Join-Path $settings 'Docker\settings-store.json') -Value $json -Encoding ascii }

# engine answers; default distro integrated by default; the older distro is not integrated
$script:dockerUp = $true
Set-DockerSettings '{"IntegratedWslDistros":[],"EnableIntegrationWithDefaultWslDistro":true}'
$o = Out-Notes { Write-DockerPostInstallNote }
Write-Output ('docker-up-no-eula=' + (-not ($o -match 'EULA')))
Write-Output ('docker-gap-lists-old=' + ($o -match 'Ubuntu-20\.04'))
Write-Output ('docker-gap-skips-default=' + (-not ($o -match 'Ubuntu-24\.04')))

# every distro integrated (explicit list): no integration note at all
Set-DockerSettings '{"IntegratedWslDistros":["Ubuntu-24.04","Ubuntu-20.04"],"EnableIntegrationWithDefaultWslDistro":false}'
$o = Out-Notes { Write-DockerPostInstallNote }
Write-Output ('docker-all-integrated-silent=' + (-not ($o -match 'WSL Integration' -or $o -match 'EULA')))

# engine down: the EULA note comes back
$script:dockerUp = $false
$o = Out-Notes { Write-DockerPostInstallNote }
Write-Output ('docker-down-eula=' + ($o -match 'EULA'))

# settings unreadable: cannot tell, so every distro is reported
Remove-Item -LiteralPath (Join-Path $settings 'Docker\settings-store.json') -Force
$script:dockerUp = $true
$o = Out-Notes { Write-DockerPostInstallNote }
Write-Output ('docker-unknown-reports-all=' + ($o -match 'Ubuntu-24\.04' -and $o -match 'Ubuntu-20\.04'))

# no distro at all: the install-a-distro advice stays
$script:distros = @()
$o = Out-Notes { Write-DockerPostInstallNote }
Write-Output ('docker-no-distro-advice=' + ($o -match 'No WSL distro detected'))

# --- Tailscale / SSH -----------------------------------------------------------------------
function Test-TailscaleConnected { $script:tailscale }
$script:tailscale = $true
Write-Output ('tailscale-connected-silent=' + ((Out-Notes { Write-RemoteAccessPostInstallNote }).Trim() -eq ''))
$script:tailscale = $false
$o = Out-Notes { Write-RemoteAccessPostInstallNote }
Write-Output ('tailscale-down-note=' + ($o -match 'Sign in to Tailscale'))

function Get-Service { param($Name, $ErrorAction) $script:svc }
$script:svc = [pscustomobject]@{ Status = 'Running' }
Write-Output ('ssh-running-silent=' + ((Out-Notes { Write-SshPostInstallNote }).Trim() -eq ''))
$script:svc = [pscustomobject]@{ Status = 'Stopped' }
Write-Output ('ssh-stopped-note=' + ((Out-Notes { Write-SshPostInstallNote }) -match 'sshd'))
$script:svc = $null
Write-Output ('ssh-missing-note=' + ((Out-Notes { Write-SshPostInstallNote }) -match 'sshd'))
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Rendered "$(winpath "$tmp/installer.ps1")" -Pwsh "$(command -v pwsh)" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600))"; }

expect 'cmd-ok=True'
expect 'cmd-fail=False'
expect 'cmd-missing=False'
expect 'cmd-hang=False'
expect 'cmd-hang-bounded=True'
expect 'docker-up-no-eula=True'
expect 'docker-gap-lists-old=True'
expect 'docker-gap-skips-default=True'
expect 'docker-all-integrated-silent=True'
expect 'docker-down-eula=True'
expect 'docker-unknown-reports-all=True'
expect 'docker-no-distro-advice=True'
expect 'tailscale-connected-silent=True'
expect 'tailscale-down-note=True'
expect 'ssh-running-silent=True'
expect 'ssh-stopped-note=True'
expect 'ssh-missing-note=True'

finish
