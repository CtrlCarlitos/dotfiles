#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# A Windows `dot upgrade` took 23m30s, 21m26s of it one winget package (Ollama), while the ISP was
# degraded (2026-10-11). Nothing printed while the installer downloaded, and nothing said which
# package or which phase took the time. Three changes, all EXECUTED here against fakes:
#   - Invoke-WingetUpgradeAll prints a heartbeat while winget is quiet, naming the package;
#   - it lists the slow packages afterwards with their download and install times;
#   - `dot upgrade` times a 10 MB download first and says so when the link is under 50 Mbit/s
#     (DOT_SLOW_MBPS), offering to skip the big sweeps. --yes and an unanswered question continue.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- shell twin: scripts/lib/netspeed.sh -----------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
# fake curl: prints what the test put in $FAKE_CURL_OUT (curl's -w output), exits like curl does
printf '%s' "${FAKE_CURL_OUT:-}"
exit "${FAKE_CURL_RC:-0}"
EOF
chmod +x "$tmp/bin/curl"
cat >"$tmp/drive.sh" <<'EOF'
#!/bin/bash
. "$1/scripts/lib/timing.sh"
. "$1/scripts/lib/netspeed.sh"
net_speed_check
echo "choice=$NET_CHOICE"
EOF
sh_harness() {
    # <FAKE_CURL_OUT> [VAR=value...]: net_speed_check with no terminal (stdin closed)
    local fake="$1"
    shift
    env PATH="$tmp/bin:$PATH" FAKE_CURL_OUT="$fake" "$@" bash "$tmp/drive.sh" "$repo_root" </dev/null 2>&1
}
out="$(sh_harness '12500000|10000000')" # 12.5 MB/s = 100 Mbit/s
printf '%s\n' "$out" | grep -Fq 'Network speed: 100.0 Mbit/s.' || fail "shell: a fast link must be reported (got: $out)"
printf '%s\n' "$out" | grep -Fxq 'choice=continue' || fail "shell: a fast link must continue (got: $out)"
out="$(sh_harness '1250000|10000000')" # 10 Mbit/s
printf '%s\n' "$out" | grep -Fq 'Network is slow: 10.0 Mbit/s (under 50)' || fail "shell: a slow link must be named (got: $out)"
printf '%s\n' "$out" | grep -Fxq 'choice=continue' || fail "shell: with no terminal a slow link must still continue (got: $out)"
out="$(sh_harness '1250000|10000000' DOTUPGRADE_YES=1)"
printf '%s\n' "$out" | grep -Fq 'Continuing (unattended)' || fail "shell: --yes must continue on a slow link (got: $out)"
out="$(sh_harness '6250000|10000000' DOT_SLOW_MBPS=60)" # 50 Mbit/s under a 60 threshold
printf '%s\n' "$out" | grep -Fq 'Network is slow: 50.0 Mbit/s (under 60)' || fail "shell: DOT_SLOW_MBPS must set the threshold (got: $out)"
out="$(sh_harness '6250000|10000000')" # exactly 50: not slow
printf '%s\n' "$out" | grep -Fq 'Network speed: 50.0 Mbit/s.' || fail "shell: exactly the threshold is not slow (got: $out)"
out="$(sh_harness 'garbage')"
printf '%s\n' "$out" | grep -Fq 'could not be measured' || fail "shell: an unreadable result must say it could not measure (got: $out)"
printf '%s\n' "$out" | grep -Fxq 'choice=continue' || fail "shell: an unmeasurable link must never block (got: $out)"
out="$(sh_harness '0|0' FAKE_CURL_RC=28)" # offline: curl got nothing
printf '%s\n' "$out" | grep -Fq 'could not be measured' || fail "shell: zero bytes must say it could not measure (got: $out)"
out="$(sh_harness '1250000|10000000' DOT_SPEED_CHECK=0)"
printf '%s\n' "$out" | grep -Fxq 'choice=continue' || fail "shell: DOT_SPEED_CHECK=0 must continue (got: $out)"
if printf '%s\n' "$out" | grep -Fq 'Network'; then fail "shell: DOT_SPEED_CHECK=0 must print nothing (got: $out)"; fi
pass

# The answers need a terminal: util-linux script(1) gives the check a pty (Linux only).
if [ "$(uname -s)" = Linux ] && command -v script >/dev/null 2>&1; then
    ask() {
        printf '%s\n' "$1" | env PATH="$tmp/bin:$PATH" FAKE_CURL_OUT='1250000|10000000' DOTUPGRADE_PROMPT_TIMEOUT=5 \
            script -qec "bash $tmp/drive.sh $repo_root" /dev/null 2>&1 | tr -d '\r' | grep -oE 'choice=[a-z]+' | tail -n 1 || true
    }
    [ "$(ask s)" = 'choice=skip' ] || fail "shell: answering s must skip the sweep"
    [ "$(ask q)" = 'choice=stop' ] || fail "shell: answering q must stop"
    [ "$(ask '')" = 'choice=continue' ] || fail "shell: an empty answer must continue"
    pass
else
    printf 'SKIP (interactive answers): needs util-linux script(1) on Linux\n'
fi

# --- PowerShell twin ---------------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib, [string]$LogDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. $Lib

# ---- the network check -----------------------------------------------------------------------------
$script:curlOut = ''
$script:asked = 0
$script:answer = ''
function curl.exe { $script:curlOut }
function Read-DotAnswer { param([string]$Prompt) $script:asked++; return $script:answer }
function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String).Trim() }

$script:curlOut = '12500000|10000000'
Write-Output ('mbps=' + (Get-DotNetworkSpeed))
Write-Output ('fast=' + (Invoke-DotNetworkCheck) + '|asked=' + $script:asked)
$script:curlOut = '1250000|10000000'
$script:answer = 's'
$text = Capture { $script:r = Invoke-DotNetworkCheck }
Write-Output ('slow-skip=' + $script:r + '|' + ($text -match 'Network is slow: 10 Mbit/s \(under 50\)'))
$script:answer = 'q'; $null = Capture { $script:r = Invoke-DotNetworkCheck }; Write-Output ('slow-stop=' + $script:r)
$script:answer = ''; $null = Capture { $script:r = Invoke-DotNetworkCheck }; Write-Output ('slow-default=' + $script:r)
$script:answer = 'y'; $null = Capture { $script:r = Invoke-DotNetworkCheck }; Write-Output ('slow-yes=' + $script:r)
# --yes (DotAnswerYes): continues without asking, and says so in words that match THIS prompt's
# own c/s/q vocabulary - not Read-DotAnswer's generic "y" (right for y/N prompts, wrong here).
$script:DotAnswerYes = $true
$script:asked = 0
$text = Capture { $script:r = Invoke-DotNetworkCheck }
Write-Output ('slow-unattended=' + $script:r + '|asked=' + $script:asked + '|' + ($text -match 'Continuing \(unattended\)'))
Remove-Variable -Name DotAnswerYes -Scope Script
$env:DOT_SLOW_MBPS = '5'
$script:asked = 0; $null = Capture { $script:r = Invoke-DotNetworkCheck }; Write-Output ('threshold=' + $script:r + '|asked=' + $script:asked)
Remove-Item Env:DOT_SLOW_MBPS
$script:curlOut = 'garbage'
$text = Capture { $script:r = Invoke-DotNetworkCheck }
Write-Output ('unmeasurable=' + $text.Contains('could not be measured') + '|' + $script:r)
$script:curlOut = '1250000|10000000'
$env:DOT_SPEED_CHECK = '0'
$script:asked = 0; Write-Output ('off=' + (Invoke-DotNetworkCheck) + '|asked=' + $script:asked)
Remove-Item Env:DOT_SPEED_CHECK

# ---- the winget sweep: per-package time and the heartbeat ----------------------------------------------
$script:clock = [DateTime]::new(2026, 10, 11, 12, 0, 0, [DateTimeKind]::Utc)
function Get-DotTimingNow { return $script:clock }
function Tick([int]$Seconds) { $script:clock = $script:clock.AddSeconds($Seconds) }
$script:wingetSleep = 0
function winget {
    if ($args -contains '--all') {
        'Found Small [Vendor.Small] Version 1.0'; Tick 10; 'Successfully installed'
        '(1/2) Found Ollama [Ollama.Ollama] Version 0.40.3'
        'Downloading https://example.invalid/OllamaSetup.exe'
        Tick 1190
        'Successfully verified installer hash'
        'Starting package install...'
        Tick 71
        'Successfully installed'
        if ($script:wingetSleep -gt 0) { Start-Sleep -Seconds $script:wingetSleep }
        $global:LASTEXITCODE = 0
    }
    else { $global:LASTEXITCODE = 0 }
}
$log = Join-Path $LogDir 'upgrade.log'
$env:DOT_WINGET_HEARTBEAT_SECONDS = '0'
$text = Capture { $null = Invoke-WingetUpgradeAll -LogPath $log }
Write-Output ('slow-line=' + ($text -match 'winget packages: Ollama 21m01s \(download 19m50s, install 1m11s\)'))
Write-Output ('small-hidden=' + (-not ($text -match 'Small \d')))
$logText = Get-Content -Raw -LiteralPath $log
Write-Output ('log-line=' + ($logText -match '(?m)^=== \S+ winget packages: Ollama 21m01s'))
Write-Output ('log-stamped=' + ($logText -match '(?m)^\[\d\d:\d\d:\d\d\] Starting package install'))

# heartbeat: a winget that goes quiet for 3 s, beating every second, names the package. The beat is
# written straight to the console from its own runspace, so it lands on this process's stdout.
$env:DOT_WINGET_HEARTBEAT_SECONDS = '1'
$script:wingetSleep = 3
$null = Invoke-WingetUpgradeAll -LogPath $log
Write-Output 'heartbeat-done'

# ---- the choco sweep: the same two things, from choco's own lines ----------------------------------------
# (a dot upgrade spent 1m39s on one 15 MB chezmoi upgrade and nothing said where, 2026-10-11)
$script:chocoSleep = 0
function choco {
    'Upgrading the following packages:'
    'chezmoi v2.73.1 [Approved]'
    'Downloading chezmoi 64 bit'
    Tick 80
    'Download of chezmoi_2.73.1_windows_amd64.zip (15.59 MB) completed.'
    Tick 19
    'The upgrade of chezmoi was successful.'
    'quickpkg v1.0 [Approved]'
    Tick 4
    'The upgrade of quickpkg was successful.'
    'chezmoi|2.73.0|2.73.1|false'
    if ($script:chocoSleep -gt 0) { Start-Sleep -Seconds $script:chocoSleep }
    $global:LASTEXITCODE = 0
}
$env:DOT_HEARTBEAT_SECONDS = '0'
$text = Capture { $null = Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'all', '-y') -LogPath $log }
Write-Output ('choco-line=' + ($text -match 'choco packages: chezmoi 1m39s \(download 1m20s, install 19s\)'))
Write-Output ('choco-quick-hidden=' + (-not ($text -match 'quickpkg \d')))
Write-Output ('choco-log=' + ((Get-Content -Raw -LiteralPath $log) -match '(?m)^=== \S+ choco packages: chezmoi 1m39s'))
$env:DOT_HEARTBEAT_SECONDS = '1'
$script:chocoSleep = 3
$null = Invoke-ChocoUpgradeAll -Arguments @('upgrade', 'all', '-y') -LogPath $log
Write-Output 'choco-heartbeat-done'
Remove-Item Env:DOT_HEARTBEAT_SECONDS

# ---- the session scan names the winget listing when it is slow --------------------------------------------
function Get-StoppableAgentProcess { return @() }
function Get-AgentDesktopApp { return @([pscustomobject]@{ Label = 'Ollama'; Processes = @(); Service = ''; UpgradeId = 'Ollama.Ollama' }) }
function Get-WingetPendingId { Start-Sleep -Milliseconds 3300; return , @() }
function Get-OrphanAgentHelper { return @() }
function Test-InteractiveConsole { return $false }
$text = Capture { $null = Invoke-LiveSessionStop -Name @('claude') }
Write-Output ('scan-names-listing=' + ($text -match 'desktop apps 3\.\ds \(winget listing 3\.\ds\)'))

# ---- a session whose StartTime cannot be read still gets one, from the process table --------------------------
function Get-ProcessTable { return @([pscustomobject]@{ Id = 4242; ParentId = 1; Name = 'agy.exe'; Path = ''; CommandLine = ''; Created = [datetime]'2026-10-11T13:09:00' }) }
$noStart = New-Object psobject -Property @{ ProcessName = 'agy'; Id = 4242 }
$noStart | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'access denied' }
Write-Output ('start-fallback=' + (Format-LiveProcess $noStart))
$unknown = New-Object psobject -Property @{ ProcessName = 'agy'; Id = 9999 }
$unknown | Add-Member -MemberType ScriptProperty -Name StartTime -Value { throw 'access denied' }
Write-Output ('start-unknown=' + (Format-LiveProcess $unknown))
Write-Output 'scan-done'
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -LogDir "$(winpath "$tmp")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600))"; }
    expect 'mbps=100'
    expect 'fast=continue|asked=0'
    expect 'slow-skip=skip|True'
    expect 'slow-stop=stop'
    expect 'slow-default=continue'
    expect 'slow-yes=continue'
    expect 'slow-unattended=continue|asked=0|True'
    expect 'threshold=continue|asked=0'
    expect 'unmeasurable=True|continue'
    expect 'off=continue|asked=0'
    expect 'slow-line=True'
    expect 'small-hidden=True'
    expect 'log-line=True'
    expect 'log-stamped=True'
    printf '%s\n' "$out" | grep -Eq '^  winget is working on Ollama \([0-9]+m[0-9]{2}s so far\)\.\.\.$' || fail "PowerShell: the heartbeat must name the package while winget is quiet (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-600))"
    expect 'heartbeat-done'
    expect 'choco-line=True'
    expect 'choco-quick-hidden=True'
    expect 'choco-log=True'
    printf '%s\n' "$out" | grep -Eq '^  choco is working on [a-z]+ \([0-9]+m[0-9]{2}s so far\)\.\.\.$' || fail "PowerShell: the choco heartbeat must name the package while choco is quiet (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-700))"
    expect 'choco-heartbeat-done'
    expect 'scan-names-listing=True'
    expect 'start-fallback=agy (pid 4242, started 13:09)'
    expect 'start-unknown=agy (pid 9999)'
    expect 'scan-done'
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

# --- wiring --------------------------------------------------------------------------------------------
du="$repo_root/scripts/dotupgrade.ps1"
ds="$repo_root/scripts/dotupgrade.sh"
grep -Fq 'Invoke-DotNetworkCheck' "$du" || fail "dotupgrade.ps1 must run the network check"
grep -Fq 'lib/netspeed.sh' "$ds" || fail "dotupgrade.sh must source lib/netspeed.sh"
check_line="$(grep -n '^[$]networkChoice = Invoke-DotNetworkCheck' "$du" | head -1 | cut -d: -f1)"
sweep_line="$(grep -n 'Invoke-ChocoUpgradeAll' "$du" | head -1 | cut -d: -f1)"
if [ -z "$check_line" ] || [ -z "$sweep_line" ] || [ "$check_line" -ge "$sweep_line" ]; then fail "dotupgrade.ps1: the network check must come before the choco sweep"; fi
[ "$(grep -c 'skipPackageSweeps' "$du")" -ge 5 ] || fail "dotupgrade.ps1: skip must gate choco, winget and both running-app offers"
check_line="$(grep -n '^net_speed_check' "$ds" | head -1 | cut -d: -f1)"
sweep_line="$(grep -n 'apt-get' "$ds" | head -1 | cut -d: -f1)"
if [ -z "$check_line" ] || [ -z "$sweep_line" ] || [ "$check_line" -ge "$sweep_line" ]; then fail "dotupgrade.sh: the network check must come before the apt sweep"; fi
pass

finish
