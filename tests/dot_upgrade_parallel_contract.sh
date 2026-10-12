#!/usr/bin/env bash
# shellcheck disable=SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# The AI-tool half of a Windows `dot upgrade` took 1m43s (2026-10-12) because its steps ran one after
# another: Playwright 18 s, agent-browser 13 s, Serena 13 s, Superpowers 12 s, Claude Code 9 s,
# Superpowers (OpenCode) 7 s - all waiting on the network. scripts/lib/ps-background.ps1 starts a second
# copy of update_ai_tools.ps1 for the steps that touch nothing else, and the main run replays each copy's
# output at the step's own place, so the output reads as it always did. Pinned here:
#   - which sections are guarded and when their copies start (the Claude Code and OpenCode ones wait for
#     the guardrail installer, which edits the same config files);
#   - EXECUTED against a fixture script: the sections overlap in time, their output comes back in the
#     original order with colours, a dead copy falls back to running in place, and
#     DOT_PARALLEL_AI_TOOLS=0 runs everything in order in one process.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

updater="$repo_root/scripts/update_ai_tools.ps1"
lib="$repo_root/scripts/lib/ps-background.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-background.ps1 must exist"
grep -Fq "ps-background.ps1" "$repo_root/scripts/lib/ps-common.ps1" || fail "ps-common.ps1 must load ps-background.ps1"
grep -Fq 'param([string]$OnlySection' "$updater" || fail "update_ai_tools.ps1 must take -OnlySection"
for section in 'Claude Code' 'Superpowers (OpenCode)' 'Playwright Chromium' 'agent-browser' 'mobile_dev' 'Serena'; do
    mark="$(grep -nF "Add-DotTimingMark -Name '$section'" "$updater" | head -n 1 | cut -d: -f1)"
    [ -n "$mark" ] || fail "update_ai_tools.ps1: no '$section' section"
    next="$((mark + 1))"
    guard="$(sed -n "${next}p" "$updater" | tr -d '\r')"
    [ "$guard" = "if (-not (Show-DotBackgroundSection '$section')) {" ] || fail "update_ai_tools.ps1: '$section' must open with its Show-DotBackgroundSection guard (got: $guard)"
done
pass
grep -Fq 'Invoke-DotBackgroundUnit -Script $PSCommandPath -Section @('"'"'Playwright Chromium'"'"', '"'"'agent-browser'"'"')' "$updater" || fail "Playwright and agent-browser must share one copy (agent-browser reuses its Chromium)"
for section in "'Serena'" "'mobile_dev'" "'Claude Code'" "'Superpowers (OpenCode)'"; do
    grep -Fq "Invoke-DotBackgroundUnit -Script \$PSCommandPath -Section @($section)" "$updater" || fail "update_ai_tools.ps1: no copy started for $section"
done
line_of() { grep -nF "$1" "$updater" | head -n 1 | cut -d: -f1; }
antigravity_mark="$(line_of "Add-DotTimingMark -Name 'Superpowers (Antigravity)'")"
guardrail_end="$(line_of '# guardrail-section: end')"
for early in "Section @('Serena')" "Section @('mobile_dev')" "Section @('Playwright Chromium', 'agent-browser')"; do
    at="$(line_of "$early")"
    if [ -z "$at" ] || [ "$at" -ge "$antigravity_mark" ]; then fail "the copy for $early must start before the Antigravity step"; fi
done
for late in "Section @('Claude Code')" "Section @('Superpowers (OpenCode)')"; do
    at="$(line_of "$late")"
    if [ -z "$at" ] || [ "$at" -le "$guardrail_end" ]; then fail "the copy for $late must start after the guardrail installer (it edits the same config)"; fi
done
pass

command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (executed part needs PowerShell): pwsh not installed\n'; finish; exit 0; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- the record trip: what a background copy prints is what the main run shows -------------------------
cat >"$tmp/records.ps1" <<'PSEOF'
param([string]$Lib)
$ErrorActionPreference = 'Stop'
. $Lib
function Out($label, $value) { Write-Output ("$label=$value") }
$writer = New-Object System.IO.StringWriter
$previous = [Console]::Out
[Console]::SetOut($writer)
try {
    Write-DotBackgroundHost 'plain'
    Write-DotBackgroundHost 'two words' -ForegroundColor Yellow
    Write-DotBackgroundHost 'no end' -NoNewline -ForegroundColor Cyan
    Write-DotBackgroundHost "first`nsecond"
    Write-DotBackgroundHost 'a', 'b' -Separator '-'
} finally { [Console]::SetOut($previous) }
$script:seen = New-Object System.Collections.Generic.List[string]
function Write-Host {
    param([Parameter(Position = 0)]$Object, $ForegroundColor, [switch]$NoNewline)
    $script:seen.Add(('[{0}|{1}]{2}' -f $ForegroundColor, [bool]$NoNewline, ("$Object" -replace "`n", '\n')))
}
foreach ($line in ($writer.ToString() -split "`r?`n" | Where-Object { $_ })) { Write-DotBackgroundRecord -Line $line }
Out 'records' ($script:seen -join ' ')
PSEOF
rec_out="$(pwsh -NoProfile -File "$(winpath "$tmp/records.ps1")" -Lib "$(winpath "$lib")" 2>&1 | tr -d '\r')" || fail "the record harness must run: $rec_out"
case "$rec_out" in
    *'records=[|False]plain [Yellow|False]two words [Cyan|True]no end [|False]first\nsecond [|False]a-b'*) pass ;;
    *) fail "records must round-trip colour, no-newline and line breaks (got: $rec_out)" ;;
esac

# --- sections run side by side, shown in order -------------------------------------------------------
# A fixture of the same shape as update_ai_tools.ps1: marks, guarded sections, the real dispatcher block.
dispatcher="$(awk '/^if \(\$OnlySection\) \{/{f=1} f{print} f && /^\}$/{exit}' "$updater" | tr -d '\r' | grep -v 'ps-skills.ps1')"
[ -n "$dispatcher" ] || fail "could not extract the -OnlySection dispatcher from update_ai_tools.ps1"
timing_lib="$repo_root/scripts/lib/ps-timing.ps1"
make_fixture() { # $1 = path, $2 = the lines that start the copies
    {
        printf '%s\n' "param([string]\$OnlySection = '')"
        printf '%s\n' ". '$(winpath "$lib")'"
        printf '%s\n' ". '$(winpath "$timing_lib")'"
        printf '%s\n' "\$script:DotBackgroundLog = '$(winpath "$tmp/upgrade.log")'"
        printf '%s\n' 'function Stop-ProcessTree { param([int]$Id) Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue }'
        printf '%s\n' "function Stamp([string]\$What) { Write-Output ('stamp ' + \$What + ' ' + [DateTime]::UtcNow.Ticks) }"
        printf '%s\n' "$dispatcher"
        printf '%s\n' "Write-Host 'first-serial' -ForegroundColor Cyan"
        printf '%s\n' "$2"
        cat <<'PSEOF'
Add-DotTimingMark -Name 'A'
if (-not (Show-DotBackgroundSection 'A')) {
    Stamp 'A-start'
    Write-Host 'A heading' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    'A plain native-style line'
    Stamp 'A-end'
}
Add-DotTimingMark -Name 'B'
if (-not (Show-DotBackgroundSection 'B')) {
    Write-Host 'B first half' -NoNewline
    Write-Host ' and second half'
}
Add-DotTimingMark -Name 'C'
if (-not (Show-DotBackgroundSection 'C')) {
    Stamp 'C-start'
    Write-Host 'C heading' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    Stamp 'C-end'
}
Add-DotTimingMark -Name 'last'
Write-Host 'last-serial'
PSEOF
    } >"$1"
}
units='$null = Invoke-DotBackgroundUnit -Script $PSCommandPath -Section @('"'A', 'B'"')
$null = Invoke-DotBackgroundUnit -Script $PSCommandPath -Section @('"'C'"')'
make_fixture "$tmp/fixture.ps1" "$units"
export HOME="$tmp/home"; mkdir -p "$HOME"
run_fixture() { pwsh -NoProfile -File "$(winpath "$1")" 2>&1 | tr -d '\r'; }
stamp() { printf '%s\n' "$1" | sed -n "s/^stamp $2 //p"; }
expected='first-serial|A heading|A plain native-style line|B first half and second half|C heading|last-serial|'

parallel_out="$(run_fixture "$tmp/fixture.ps1")"
order="$(printf '%s\n' "$parallel_out" | grep -v '^stamp ' | tr '\n' '|')"
[ "$order" = "$expected" ] || fail "the output must read in the serial order (got: $order)"
pass
a_start="$(stamp "$parallel_out" A-start)"; a_end="$(stamp "$parallel_out" A-end)"
c_start="$(stamp "$parallel_out" C-start)"; c_end="$(stamp "$parallel_out" C-end)"
if [ -n "$a_end" ] && [ -n "$c_end" ] && [ "$c_start" -lt "$a_end" ] && [ "$a_start" -lt "$c_end" ]; then pass; else fail "sections A and C must overlap in time (A $a_start..$a_end, C $c_start..$c_end)"; fi
if grep -Fq 'background A + B ran' "$tmp/upgrade.log" 2>/dev/null; then pass; else fail "each copy's own time must be logged"; fi

# knob off: everything in this process, one after another
serial_out="$(DOT_PARALLEL_AI_TOOLS=0 run_fixture "$tmp/fixture.ps1")"
order="$(printf '%s\n' "$serial_out" | grep -v '^stamp ' | tr '\n' '|')"
[ "$order" = "$expected" ] || fail "DOT_PARALLEL_AI_TOOLS=0 must print the same output (got: $order)"
a_end="$(stamp "$serial_out" A-end)"; c_start="$(stamp "$serial_out" C-start)"
if [ -n "$a_end" ] && [ -n "$c_start" ] && [ "$c_start" -ge "$a_end" ]; then pass; else fail "DOT_PARALLEL_AI_TOOLS=0 must run the sections one after another"; fi

# a copy that cannot do its work (its script is missing): the sections run in place
broken_units='$null = Invoke-DotBackgroundUnit -Script (Join-Path $PSScriptRoot '"'no-such-script.ps1'"') -Section @('"'A', 'B'"')
$null = Invoke-DotBackgroundUnit -Script $PSCommandPath -Section @('"'C'"')'
make_fixture "$tmp/broken.ps1" "$broken_units"
broken_out="$(run_fixture "$tmp/broken.ps1")"
case "$broken_out" in
    *'running it here'*'A heading'*'A plain native-style line'*'B first half and second half'*'C heading'*'last-serial'*) pass ;;
    *) fail "a copy that dies must leave its sections to run in place, and say so (got: $broken_out)" ;;
esac

finish
