#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# A Windows `dot up` that reinstalled 27 winget packages (2026-10-11, slow ISP) took 11m48s and
# printed "Timings: choco packages 10m14s": the winget section had no timing mark of its own, so
# its time was counted as choco's, and nothing printed between one install line and the next.
#   - the winget section gets its own mark ('winget packages');
#   - the install loop runs under the heartbeat and names the packages that took 30 s or more;
#   - the helpers live in scripts/lib/ps-heartbeat.ps1: dot upgrade's ps-common.ps1 dot-sources it,
#     the installer (one self-contained rendered script) inlines it with {{ include }}.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-heartbeat.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-heartbeat.ps1 must exist"
grep -Fq 'include "scripts/lib/ps-heartbeat.ps1"' "$tmpl" || fail "the installer must include scripts/lib/ps-heartbeat.ps1"
grep -Fq "ps-heartbeat.ps1" "$repo_root/scripts/lib/ps-common.ps1" || fail "ps-common.ps1 must dot-source ps-heartbeat.ps1 so dot upgrade keeps its heartbeat"
if grep -Eq '^function (Open|Close)-DotHeartbeat' "$repo_root/scripts/lib/ps-common.ps1"; then
    fail "the heartbeat helpers must live in ps-heartbeat.ps1 only (two copies drift)"
fi
mark_line="$(grep -n "Add-DotTimingMark -Name 'winget packages'" "$tmpl" | head -n 1 | cut -d: -f1)"
sweep_line="$(grep -n 'if (\$wingetPackages.Count -gt 0) {' "$tmpl" | head -n 1 | cut -d: -f1)"
if [ -z "$mark_line" ] || [ -z "$sweep_line" ] || [ "$mark_line" -ge "$sweep_line" ]; then
    fail "the winget section must start with its own timing mark (mark line '${mark_line:-none}', sweep line '${sweep_line:-none}')"
fi
grep -Fq 'Open-DotHeartbeat -Tool winget' "$tmpl" || fail "the winget install loop must run under the heartbeat"
grep -Fq 'Close-DotHeartbeat -Beat $wingetBeat' "$tmpl" || fail "the heartbeat must be closed (in a finally)"
grep -Fq 'Write-DotPackageTiming -Tool winget' "$tmpl" || fail "the slow installs must be named afterwards"
pass

# --- the helpers, executed ---------------------------------------------------------------------
command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (helpers run under PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Timing, [string]$Lib, [string]$Log)
$ErrorActionPreference = 'Stop'
# the same two files, in the same order, the installer inlines and ps-common dot-sources
. $Timing
. $Lib
$t0 = [DateTime]::UtcNow
$rows = New-Object System.Collections.Generic.List[object]
$rows.Add([pscustomobject]@{ Name = 'quick.pkg'; Start = $t0; DownloadEnd = $null; End = $t0.AddSeconds(8) })
$rows.Add([pscustomobject]@{ Name = 'slow.pkg'; Start = $t0; DownloadEnd = $null; End = $t0.AddSeconds(95) })
Write-DotPackageTiming -Tool winget -Package $rows -LogPath $Log
$env:DOT_HEARTBEAT_SECONDS = '1'
$beat = Open-DotHeartbeat -Tool winget
$beat.State.Package = 'big.pkg'
Start-Sleep -Milliseconds 2600
Close-DotHeartbeat -Beat $beat
$env:DOT_HEARTBEAT_SECONDS = '0'
$off = Open-DotHeartbeat -Tool winget
if ($off.Runspace) { Write-Output 'off-has-runspace' } else { Write-Output 'off-no-runspace' }
Close-DotHeartbeat -Beat $off
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Timing "$(winpath "$repo_root/scripts/lib/ps-timing.ps1")" -Lib "$(winpath "$lib")" -Log "$(winpath "$tmp/up.log")" 2>&1 | tr -d '\r')" || fail "the helpers must run: $out"
case "$out" in *'winget packages: slow.pkg 1m35s'*) pass ;; *) fail "the slow install must be named with its time: $out" ;; esac
case "$out" in *quick.pkg*) fail "an install under 30 s must not be listed: $out" ;; *) pass ;; esac
case "$out" in *'winget is working on big.pkg ('*' so far)...'*) pass ;; *) fail "the heartbeat must name the package that is running: $out" ;; esac
case "$out" in *off-no-runspace*) pass ;; *) fail "DOT_HEARTBEAT_SECONDS=0 must start no heartbeat: $out" ;; esac
grep -Fq 'winget packages: slow.pkg 1m35s' "$tmp/up.log" || fail "the slow installs must also go to the log"
pass

finish
