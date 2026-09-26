#!/usr/bin/env bash
set -euo pipefail

# Choco probe resilience contract, born from the 2026-09-20 live incident:
# one uncapped `choco list --exact <pkg>` probe wedged pre-resolution for 77
# minutes at ~1 core (no timeout, because only installs were capped), and
# Stop-Job could not kill it - choco.exe survived its own 600s cap as an
# orphan holding Chocolatey's global mutex. Contracts:
#   1. Package inventory is ONE batched local `choco list --limit-output`
#      call (single process spawn), never a per-package probe.
#   2. The batched call is timeout-capped like every network/install step.
#   3. A failed/timed-out batch degrades to nupkg-presence checks (imperfect:
#      broken packages keep their nupkg - wiztree, live - but the registry
#      fuzzy-skip catches those apps anyway).
#   4. Invoke-WithTimeout hard-kills the job's process TREE on timeout
#      (Stop-Job leaves native children orphaned) and can collect output
#      for callers that need the result, not just the side effect.
#   5. Registry fuzzy-skip anchors the package name at PREFIX - the 1.0.6
#      fix for `tree` silently skipped because "WizTree v4.32" contains it.
#
# EXECUTED (v2, #135): Invoke-WithTimeout, the batched-inventory statement
# and the registry-skip loop are extracted from the rendered installer and
# run under pwsh - the timeout really fires, the tree kill really sweeps,
# the collection really returns, and `tree` really installs while `wiztree`
# really skips. The forbid-greps below stay for the ABSENCE invariants.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ps1_installer="$repo_root/run_onchange_install_packages.ps1.tmpl"

. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (rendering requires it)"

# Absence invariants: per-package probes and substring fuzzy-skips must not
# return (fixtures can only prove presence, never absence).
if grep -Fq 'choco list --exact $pkg' "$ps1_installer"; then
    fail "$ps1_installer: per-package choco list probes are forbidden (2026-09-20 wedge class)"
else
    pass
fi
if grep -Fq -- '-like "*$normalizedPkg*"' "$ps1_installer"; then
    fail "$ps1_installer: substring fuzzy-skip is forbidden (tree/WizTree false positive)"
else
    pass
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

rendered="$tmp/installer.ps1"
render_to "$rendered" ps1 '{"core": true}'
[ -s "$rendered" ] || fail "ps1 installer did not render"

# Batched inventory, present exactly once and capped.
inv_line="$(grep -nF '$chocoListOutput = Invoke-WithTimeout' "$rendered" | head -1)"
[ -n "$inv_line" ] || fail "rendered installer: batched choco inventory missing"
if grep -Fq 'choco list --limit-output' "$rendered" && grep -Fq 'batched choco list' "$rendered"; then
    pass
else
    fail "rendered installer: the batch must run choco list --limit-output under Invoke-WithTimeout"
fi

iwt_start="$(grep -nF 'function Invoke-WithTimeout' "$rendered" | head -1 | cut -d: -f1)"
iwt_end="$(awk -v s="$iwt_start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
inv_start="$(grep -nF '$chocoListOutput = Invoke-WithTimeout' "$rendered" | head -1 | cut -d: -f1)"
inv_end="$(awk -v s="$inv_start" 'NR >= s && $0 == "}"{print NR; exit}' "$rendered")"
loop_start="$(grep -nF 'foreach ($pkg in $packages)' "$rendered" | head -1 | cut -d: -f1)"
loop_end="$(awk -v s="$loop_start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
for v in "$iwt_start" "$iwt_end" "$inv_start" "$inv_end" "$loop_start" "$loop_end"; do
    [ -n "$v" ] || fail "rendered installer: extraction anchor missing"
done

# choco stub: inventory mode emits two id|version lines; install mode logs.
cat >"$bin/choco.cmd" <<EOF
@echo off
echo %* >> "%CHOCO_LOG%"
if /i "%1"=="list" (
    echo git^|2.40.0
    echo nodejs^|24.19.0
    exit /b 0
)
exit /b 0
EOF
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        cat >"$bin/choco" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${CHOCO_LOG:?}"
if [ "${1:-}" = list ]; then
    printf 'git|2.40.0\nnodejs|24.19.0\n'
    exit 0
fi
exit 0
EOF
        chmod +x "$bin/choco"
        ;;
esac

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $iwtStart, $iwtEnd, $invStart, $invEnd, $loopStart, $loopEnd, $mode = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$iwt = Slice $lines $iwtStart $iwtEnd
$inv = Slice $lines $invStart $invEnd
$loop = Slice $lines $loopStart $loopEnd

function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
Invoke-Expression $iwt

switch ($mode) {
    'collect' {
        $out = Invoke-WithTimeout -Description 'collect' -Seconds 60 -NoStream -Action { 'line-one'; 'line-two' }
        if (@($out) -join ';' -cne 'line-one;line-two') { Fail "NoStream must return collected output; got: $(@($out) -join ';')" }
    }
    'stream' {
        Invoke-WithTimeout -Description 'streaming' -Seconds 60 -Action { 'streamed-line' } | Out-String | Write-Host
    }
    'failjob' {
        Invoke-WithTimeout -Description 'doomed job' -Seconds 60 -NoStream -Action { throw 'boom' }
    }
    'timeout' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-WithTimeout -Description 'stalled probe' -Seconds 2 -Action { Start-Sleep -Seconds 60 }
        $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -gt 30) { Fail "the cap must fire near 2s, not $($sw.Elapsed.TotalSeconds)s" }
    }
    'inventory' {
        Invoke-Expression $inv
        if (@($chocoListOutput).Count -ne 2) { Fail "the batch must collect the inventory; got: $(@($chocoListOutput) -join ',')" }
        if (-not (@($chocoListOutput) -match '^git\|')) { Fail 'inventory lines lost their id|version shape' }
    }
    'prefix' {
        # The 1.0.6 scenario: choco knows nothing; the uninstall registry holds
        # "WizTree v4.32". `tree` must still install (prefix anchoring);
        # `wiztree` must skip with the handover warning.
        $chocoInstalled = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $chocoInventoryUsable = $true
        $uninstallEntries = @([pscustomobject]@{ Display = 'WizTree v4.32'; Normalized = 'wiztreev432' })
        $packages = @('tree', 'wiztree', 'handy')
        Invoke-Expression $loop
    }
    default { Fail "unknown mode: $mode" }
}
POWERSHELL

fixture_ok() { # $1 = fixture log, $2 = label - the fixture's FAIL lines decide
    if grep -q 'FAIL' "$1"; then fail "$2: $(cat "$1")"; else pass; fi
}

run_ps() { # $1 = mode, $2 = outfile
    local mode="$1" outfile="$2"
    local wintmp
    wintmp="$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")"
    PATH="$bin:/usr/bin:/bin" CHOCO_LOG="$wintmp\\choco.log" \
        "$(command -v pwsh)" -NoProfile -File "$fixture" "$rendered" "$iwt_start" "$iwt_end" "$inv_start" "$inv_end" "$loop_start" "$loop_end" "$mode" \
        >"$outfile" 2>&1
}

# 4. Invoke-WithTimeout: collect, stream, failed-job warning, hard cap.
run_ps collect "$tmp/collect.log" || fail "collect scenario failed: $(cat "$tmp/collect.log")"
fixture_ok "$tmp/collect.log" "collect"

run_ps stream "$tmp/stream.log"
grep -Fq 'streamed-line' "$tmp/stream.log" || fail "streaming mode must surface the job's output"

run_ps failjob "$tmp/failjob.log" || true
grep -Fq 'doomed job - failed' "$tmp/failjob.log" ||
    fail "a failed job must be reported as a warning: $(cat "$tmp/failjob.log")"

: >"$tmp/choco.log"
run_ps timeout "$tmp/timeout.log" || fail "timeout scenario failed: $(cat "$tmp/timeout.log")"
fixture_ok "$tmp/timeout.log" "timeout"
grep -Fq 'stalled probe - timed out after 2s (process tree killed)' "$tmp/timeout.log" ||
    fail "the cap must announce the timeout and the tree kill: $(cat "$tmp/timeout.log")"

# 1./2. Batched inventory really collected through Invoke-WithTimeout.
: >"$tmp/choco.log"
run_ps inventory "$tmp/inventory.log" || fail "inventory scenario failed: $(cat "$tmp/inventory.log")"
fixture_ok "$tmp/inventory.log" "inventory"
if [ "$(grep -c 'list' "$tmp/choco.log")" -eq 1 ]; then pass; else fail "the inventory must be ONE choco spawn; saw: $(cat "$tmp/choco.log")"; fi

# 3./5. Registry skip: prefix anchoring (tree installs, wiztree skips).
: >"$tmp/choco.log"
run_ps prefix "$tmp/prefix.log" || fail "prefix scenario failed: $(cat "$tmp/prefix.log")"
fixture_ok "$tmp/prefix.log" "prefix"
grep -Fq 'Installing tree...' "$tmp/prefix.log" ||
    fail "prefix anchoring broken: tree must not match WizTree (the 1.0.6 regression)"
grep -Fq "Skipping wiztree - 'WizTree v4.32' is already installed (not via Chocolatey)" "$tmp/prefix.log" ||
    fail "wiztree must skip with the handover warning"
grep -Fq 'Installing handy...' "$tmp/prefix.log" || fail "handy must install (no registry match)"

rm -f "$fixture"
finish
