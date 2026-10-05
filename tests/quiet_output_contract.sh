#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2030,SC2031  # the sourced library and pwsh consume these
set -euo pipefail

# Noise cut from `dot up` / `dot upgrade` (2026-10-05 logs) without hiding anything that
# needs attention:
#   1. agent-browser's `doctor --json` printed a ~3 KB single-line blob on every run, on
#      both machines. Now: "agent-browser doctor: N pass, N warn, N fail" plus one line per
#      warn/fail check. Output that is not the expected JSON is printed raw, never dropped.
#   2. fetch_and_verify's curl printed two progress tables per run (WSL log). Now -sS: quiet,
#      still reports errors.
#   3. Windows reinstalled Claude Code with the full installer on every `dot upgrade`,
#      although `claude update` exists and the Unix twin already tries it first.
# Both languages are EXECUTED.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

lib="$repo_root/scripts/lib/agent-skills.sh"

# --- 2. curl is quiet ---------------------------------------------------------------------
if grep -nE 'curl -fLo' "$lib" >/dev/null; then fail "fetch_and_verify still uses a progress-printing curl (-fLo); use -fsSL -o"; else pass; fi
grep -Fq 'curl -fsSL -o "$dest/SHA256SUMS"' "$lib" || fail "fetch_and_verify must fetch SHA256SUMS with curl -fsSL -o"

# --- 1. agent-browser doctor summary (bash) -------------------------------------------------
if command -v jq >/dev/null 2>&1; then
    cat >"$tmp/ab-ok" <<'EOF'
#!/bin/sh
printf '%s\n' '{"checks":[{"category":"Environment","id":"env.version","message":"CLI version 0.38.2","status":"pass"},{"category":"Chrome","id":"chrome.installed","message":"Chrome is missing","status":"warn","fix":"agent-browser install"},{"category":"Providers","id":"p","message":"no key","status":"info"}],"success":true,"summary":{"fail":0,"pass":1,"warn":1}}'
EOF
    cat >"$tmp/ab-bad" <<'EOF'
#!/bin/sh
printf '%s\n' 'this is not json'
exit 4
EOF
    chmod +x "$tmp/ab-ok" "$tmp/ab-bad"
    # shellcheck source=/dev/null
    run_doctor() { ( . "$lib"; agent_browser_doctor "$1" ) 2>&1; }
    out="$(run_doctor "$tmp/ab-ok")"
    printf '%s\n' "$out" | grep -Fxq 'agent-browser doctor: 1 pass, 1 warn, 0 fail' || fail "doctor summary line missing (got: $out)"
    printf '%s\n' "$out" | grep -Fq 'warn: Chrome is missing' || fail "a warn check must be listed (got: $out)"
    printf '%s\n' "$out" | grep -Fq 'fix: agent-browser install' || fail "the fix hint must be listed (got: $out)"
    if printf '%s\n' "$out" | grep -Fq '"checks"'; then fail "the raw JSON must not be printed"; else pass; fi
    if printf '%s\n' "$out" | grep -Fq 'no key'; then fail "info checks are not worth a line"; else pass; fi
    set +e
    out="$(run_doctor "$tmp/ab-bad")"
    rc=$?
    set -e
    printf '%s\n' "$out" | grep -Fq 'this is not json' || fail "unexpected output must be printed raw, not dropped (got: $out)"
    [ "$rc" -ne 0 ] || fail "doctor's exit status must be passed through (got 0)"
else
    printf 'SKIP (doctor summary, bash): jq not installed\n'
fi

# --- PowerShell: summary, skills messages, Claude Code update ----------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$SkillsLib, [string]$CommonLib, [string]$UserDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserDir
. $SkillsLib
. $CommonLib

function Capture([scriptblock]$Run) { (& $Run *>&1 | Out-String) }

# --- agent-browser doctor summary ---
$json = '{"checks":[{"category":"Environment","id":"env.version","message":"CLI version 0.38.2","status":"pass"},{"category":"Chrome","id":"chrome.installed","message":"Chrome is missing","status":"warn","fix":"agent-browser install"},{"category":"Providers","id":"p","message":"no key","status":"info"}],"success":true,"summary":{"fail":0,"pass":1,"warn":1}}'
$o = Capture { Write-AgentBrowserDoctorSummary -Output @($json) }
Write-Output ('doctor-summary=' + ($o -match 'agent-browser doctor: 1 pass, 1 warn, 0 fail'))
Write-Output ('doctor-warn-listed=' + ($o -match 'warn: Chrome is missing' -and $o -match 'fix: agent-browser install'))
Write-Output ('doctor-no-raw-json=' + (-not ($o -match '"checks"')))
Write-Output ('doctor-no-info=' + (-not ($o -match 'no key')))
$o = Capture { Write-AgentBrowserDoctorSummary -Output @('this is not json') }
Write-Output ('doctor-raw-fallback=' + ($o -match 'this is not json'))
$o = Capture { Write-AgentBrowserDoctorSummary -Output @() }
Write-Output ('doctor-empty-silent=' + ($o.Trim() -eq ''))

# --- Invoke-SkillsSource messages: one line per source, "<label>: up to date" or ": installed" ---
function Get-SkillsRemoteHead { param([string]$Repo) return 'abc123' }
foreach ($d in '.claude', '.agents') {
    New-Item -Force -ItemType Directory (Join-Path $UserDir "$d\skills\s1") | Out-Null
    Set-Content -LiteralPath (Join-Path $UserDir "$d\skills\s1\SKILL.md") -Value ''
}
$script:ranInstall = 0
$o = Capture { Invoke-SkillsSource -Label 'my skill' -Repo 'o/r' -Skills 's1' -Agents @('claude-code') -Install { $script:ranInstall++; $true } }
Write-Output ('skills-installed-line=' + ($o -match 'my skill: installed'))
$o = Capture { Invoke-SkillsSource -Label 'my skill' -Repo 'o/r' -Skills 's1' -Agents @('claude-code') -Install { $script:ranInstall++; $true } }
Write-Output ('skills-uptodate-line=' + ($o -match 'my skill: up to date'))
Write-Output ('skills-uptodate-no-install=' + ($script:ranInstall -eq 1))

# --- Invoke-ClaudeCodeUpdate: claude update first, the full installer only when it fails ---
$script:claudeExit = 0
$script:installerRuns = 0
function claude { param() $global:LASTEXITCODE = $script:claudeExit }
function powershell { $script:installerRuns++; $global:LASTEXITCODE = 0 }
Invoke-ClaudeCodeUpdate -InstallerUrl 'https://example.test/install.ps1' | Out-Null
Write-Output ('claude-update-ok-no-installer=' + ($script:installerRuns -eq 0))
$script:claudeExit = 1
Invoke-ClaudeCodeUpdate -InstallerUrl 'https://example.test/install.ps1' | Out-Null
Write-Output ('claude-update-failed-runs-installer=' + ($script:installerRuns -eq 1))
$script:installerRuns = 0
$o = Capture { Invoke-ClaudeCodeUpdate -InstallerUrl '' }
Write-Output ('claude-update-failed-no-url=' + ($script:installerRuns -eq 0 -and $o -match 'installer URL unavailable'))
PSEOF
    mkdir -p "$tmp/home"
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -SkillsLib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -CommonLib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" -UserDir "$(winpath "$tmp/home")" 2>&1 | tr -d '\r' || true)"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }
    expect 'doctor-summary=True'
    expect 'doctor-warn-listed=True'
    expect 'doctor-no-raw-json=True'
    expect 'doctor-no-info=True'
    expect 'doctor-raw-fallback=True'
    expect 'doctor-empty-silent=True'
    expect 'skills-installed-line=True'
    expect 'skills-uptodate-line=True'
    expect 'skills-uptodate-no-install=True'
    expect 'claude-update-ok-no-installer=True'
    expect 'claude-update-failed-runs-installer=True'
    expect 'claude-update-failed-no-url=True'
else
    printf 'SKIP (PowerShell part): pwsh not installed\n'
fi

finish
