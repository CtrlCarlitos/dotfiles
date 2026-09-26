#!/usr/bin/env bash
set -euo pipefail

# CodexBar install contract, EXECUTED (#135):
#   1. The macOS dev_desktop cask list RENDERS from the package catalog
#      (#83) with codexbar in it - asserted on the rendered darwin installer,
#      not on the catalog text, so a catalog rename that loses codexbar fails
#      here exactly where a real apply would break.
#   2. The Windows Win-CodexBar winget block runs against a stubbed winget:
#      install only after `winget list` does not report it, always
#      --exact --source winget (the manifest pins the URL/SHA - a fuzzy or
#      direct-download fallback must never return).
# Docs-side rows (tool-parity, package-groups) moved to tests/docs_contracts.sh.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip "chezmoi not installed (rendering requires it)"
command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed (the Windows block needs it)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"

# --- 1. macOS: the rendered cask list carries codexbar -------------------------
darwin_render="$tmp/installer-darwin.sh"
render_to "$darwin_render" darwin '{"dev_desktop": true}'
[ -s "$darwin_render" ] || fail "darwin installer did not render"
# The dev_desktop cask loop renders the catalog's cask names as brew arguments.
cask_line="$(grep -F 'for cask in' "$darwin_render" | head -1)"
grep -Fq 'codexbar' <<<"$cask_line" ||
    fail "darwin dev_desktop cask list lost codexbar: $cask_line"

# --- 2. Windows: the winget block, executed -------------------------------------
ps1_rendered="$tmp/installer.ps1"
render_to "$ps1_rendered" ps1 '{"dev_desktop": true}'
[ -s "$ps1_rendered" ] || fail "ps1 installer did not render"

# The Win-CodexBar block follows its own static comment; locate the block by
# that comment, then the first col-0 `}` after it.
codexbar_comment="$(grep -nF 'Win-CodexBar is the native Windows CodexBar implementation' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$codexbar_comment" ] || fail "rendered installer: Win-CodexBar comment not found"
start="$(grep -nF 'if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {' "$ps1_rendered" |
    awk -v c="$codexbar_comment" -F: '$1 > c {print $1; exit}')"
[ -n "$start" ] || fail "rendered installer: Win-CodexBar block not found"
end="$(awk -v s="$start" 'NR > s && $0 == "}"{print NR; exit}' "$ps1_rendered")"
[ -n "$end" ] || fail "rendered installer: Win-CodexBar block end not found"

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end, $mode = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$block = Slice $lines $start $end

function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }
function Invoke-WithTimeout {
    param([string]$Description, [int]$Seconds, [scriptblock]$Action, [switch]$NoStream)
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "winget exited with code $LASTEXITCODE" }
}

switch ($mode) {
    'absent' {
        Invoke-Expression $block
        $log = Get-Content $env:WINGET_LOG
        if (-not ($log -match 'list --id Finesssee.Win-CodexBar --exact')) { Fail "the presence probe must be --exact on the id; saw: $log" }
        if (-not ($log -match 'install --id Finesssee.Win-CodexBar --exact --source winget')) { Fail "install must be --exact --source winget; saw: $log" }
    }
    'present' {
        Invoke-Expression $block
        if ($log -match 'install --id') { Fail 'winget install ran although the list probe matched' }
    }
    'nowinget' {
        Invoke-Expression $block
    }
    default { Fail "unknown mode: $mode" }
}
POWERSHELL

run_block() { # $1 = mode, $2 = list-output, $3 = outfile
    local mode="$1" listout="$2" outfile="$3"
    local wintmp
    wintmp="$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")"
    PATH="$bin:/usr/bin:/bin" WINGET_LOG="$wintmp\\winget.log" WINGET_LIST_OUT="$listout" \
        "$(command -v pwsh)" -NoProfile -File "$fixture" "$ps1_rendered" "$start" "$end" "$mode" \
        >"$outfile" 2>&1
}

# winget missing first (no stub yet): must warn, not throw.
run_block nowinget "" "$tmp/nowinget.log" || fail "missing-winget scenario failed: $(cat "$tmp/nowinget.log")"
grep -Fq 'winget not found - cannot install Win-CodexBar' "$tmp/nowinget.log" ||
    fail "a missing winget must be reported"

cat >"$bin/winget.cmd" <<EOF
@echo off
echo %* >> "%WINGET_LOG%"
if /i "%1"=="list" (
    echo %WINGET_LIST_OUT%
    exit /b 0
)
exit /b 0
EOF
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *)
        cat >"$bin/winget" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${WINGET_LOG:?}"
if [ "${1:-}" = list ]; then
    printf '%s\n' "${WINGET_LIST_OUT:-}"
    exit 0
fi
exit 0
EOF
        chmod +x "$bin/winget"
        ;;
esac

fixture_ok() { # $1 = fixture log, $2 = label - the fixture's FAIL lines decide
    if grep -q 'FAIL' "$1"; then fail "$2: $(cat "$1")"; else pass; fi
}

run_block absent "no-match" "$tmp/absent.log" || fail "absent scenario failed: $(cat "$tmp/absent.log")"
grep -Fq 'Installing Win-CodexBar (winget)...' "$tmp/absent.log" || fail "the install must be announced"
fixture_ok "$tmp/absent.log" "absent"

run_block present "Finesssee.Win-CodexBar 1.2.3" "$tmp/present.log" ||
    fail "already-installed scenario failed: $(cat "$tmp/present.log")"
grep -Fq 'Win-CodexBar already installed' "$tmp/present.log" || fail "the presence branch must say so"
fixture_ok "$tmp/present.log" "present"

rm -f "$fixture"
finish
