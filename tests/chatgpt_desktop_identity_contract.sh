#!/usr/bin/env bash
set -euo pipefail

# ChatGPT Work/Codex identity contract, EXECUTED (#135): the installer's
# chatgpt_desktop block is rendered and run against a stubbed winget, and the
# assertions read the stub's argv log - the right app id (9PLM9XGG6VKS) via
# the msstore source, skipped when already installed, a clean warning when
# winget is missing, and the ChatGPT Classic product (9NT1R1C2HH7J) never
# passed to winget. What used to be whole-line greps of the template is now
# behaviour; the remaining source grep below only forbids the Classic install
# idiom. Docs-side identity rows moved to tests/docs_contracts.sh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (rendering requires it)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

rendered="$tmp/installer.ps1"
render_to "$rendered" ps1 '{"chatgpt_desktop": true}'
[ -s "$rendered" ] || fail "ps1 installer did not render"

# The Classic app must never be installed or removed from here. Whole-file
# forbid: the only legitimate mention is the explanatory comment.
if grep -Fq 'winget install --id 9NT1R1C2HH7J' "$rendered"; then
    fail "rendered installer must not install ChatGPT Classic (9NT1R1C2HH7J)"
else
    pass
fi

# Extract the block: start anchor is unique in the render; the end is the
# first line that is EXACTLY `}` (a bare `} elseif ...` / `} else {` would
# otherwise truncate the block).
start="$(grep -nF 'if (Get-AppxPackage -Name "OpenAI.Codex"' "$rendered" | head -1 | cut -d: -f1)"
[ -n "$start" ] || fail "rendered installer: chatgpt_desktop block not found (gate broken?)"
end="$(awk -v s="$start" 'NR > s && $0 == "}"{print NR; exit}' "$rendered")"
[ -n "$end" ] || fail "rendered installer: chatgpt_desktop block end not found"

# winget stub: logs argv; behavior steered with WINGET_FAIL (exit code).
# Created AFTER the missing-winget scenario so that one sees a real absence.

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
wlog="$tmp/winget.log"
# The stub bakes its ABSOLUTE log path in its body (per-OS spelling for the
# binary pwsh will resolve); the fixture reads that exact baked literal as an
# argument - env-carried paths with a stray backslash split the writer and
# the reader onto two different files on Linux.
case "${OSTYPE:-}" in
    msys*|cygwin*) wlog_arg="$(cygpath -w "$wlog")" ;;
    *)             wlog_arg="$wlog" ;;
esac
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end, $logPath, $mode = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$block = Slice $lines $start $end

function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }

# Get-AppxPackage is a cmdlet, not a binary: stub it per scenario.
if ($mode -eq 'installed') {
    function Get-AppxPackage { param($Name) [pscustomobject]@{ Name = $Name } }
} else {
    function Get-AppxPackage { param($Name) $null }
}
# Invoke-WithTimeout: run the action inline, keep the exit-code throw contract.
function Invoke-WithTimeout {
    param([string]$Description, [int]$Seconds, [scriptblock]$Action, [switch]$NoStream)
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "winget exited with code $LASTEXITCODE" }
}

switch ($mode) {
    'absent' {
        Invoke-Expression $block
        $log = Get-Content $logPath
        if (-not ($log -match '--id 9PLM9XGG6VKS')) { Fail "winget argv must carry the Work/Codex store id; saw: $log" }
        if (-not ($log -match '--source msstore')) { Fail 'winget must install from the msstore source' }
    }
    'installed' {
        Invoke-Expression $block
        if (Test-Path $logPath) { Fail 'winget must not be invoked when the app is already installed' }
    }
    'nowinget' {
        # No stub on the restricted PATH: the block must warn, not throw.
        Invoke-Expression $block
    }
    'wingetfail' {
        try { Invoke-Expression $block } catch { Fail "a winget failure must warn-and-continue, not throw: $_" }
    }
    default { Fail "unknown mode: $mode" }
}
POWERSHELL

check_log() { # $1 = fixture log, $2 = label - the fixture's FAIL lines decide
    if grep -q 'FAIL' "$1"; then fail "$2: $(cat "$1")"; else pass; fi
}
run_block() { # $1 = mode, $2 = outfile; WINGET_FAIL via env
    local mode="$1" outfile="$2"
    PATH="$bin:/usr/bin:/bin" WINGET_FAIL="${WINGET_FAIL:-}" \
        "$(command -v pwsh)" -NoProfile -File "$fixture" "$rendered" "$start" "$end" "$wlog_arg" "$mode" \
        >"$outfile" 2>&1
}

# winget missing: no stub on the restricted PATH - the block must warn.
run_block nowinget "$tmp/nowinget.log" || fail "missing-winget scenario failed: $(cat "$tmp/nowinget.log")"
grep -Fq 'winget not found - cannot install ChatGPT Work/Codex' "$tmp/nowinget.log" ||
    fail "a missing winget must be reported"

cat >"$bin/winget.cmd" <<EOF
@echo off
echo %* >> "$wlog_arg"
if not "%WINGET_FAIL%"=="" exit /b %WINGET_FAIL%
exit /b 0
EOF
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n[ -n "${WINGET_FAIL:-}" ] && exit "\$WINGET_FAIL"\nexit 0\n' "$wlog" >"$bin/winget"
        chmod +x "$bin/winget"
        ;;
esac

: >"$wlog"
run_block absent "$tmp/absent.log" || fail "absent-app scenario failed: $(cat "$tmp/absent.log")"
grep -Fq 'Installing ChatGPT Work/Codex (winget msstore)...' "$tmp/absent.log" ||
    fail "the install must be announced"
check_log "$tmp/absent.log" "absent-app"

rm -f "$wlog"
run_block installed "$tmp/installed.log" || fail "already-installed scenario failed: $(cat "$tmp/installed.log")"
grep -Fq 'ChatGPT Work/Codex already installed' "$tmp/installed.log" ||
    fail "the already-installed branch must say so"
check_log "$tmp/installed.log" "already-installed"

rm -f "$wlog"
WINGET_FAIL=3 run_block wingetfail "$tmp/wingetfail.log" ||
    fail "winget-failure scenario failed: $(cat "$tmp/wingetfail.log")"
grep -Fq 'Failed to install ChatGPT Work/Codex' "$tmp/wingetfail.log" ||
    fail "a winget failure must warn-and-continue (the installer must not die here)"

# CI parity: the full-install workflow verifies the same identity.
require "$repo_root/.github/workflows/full-install-test.yml" 'OpenAI.Codex'

rm -f "$fixture"
finish
