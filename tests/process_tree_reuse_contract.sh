#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell text is literal
set -euo pipefail

# Windows reuses process ids, and a process keeps its parent's id after that parent exits.
# `taskkill /T` follows those ids: on 2026-10-08 a Windows Terminal started at 01:14 by a
# long-gone launcher listed a Claude Code session started hours later as its "parent" (the
# session had been given the launcher's old id), so stopping that session could have taken
# the whole terminal - every tab - with it. Get-ProcessTreeId / Stop-ProcessTree
# (scripts/lib/ps-common.ps1) replace `taskkill /T`. EXECUTED against a fake process table:
#   - a child counts only when it started at or after its parent (the reused-id terminal and
#     everything under it stay out); unknown start times count as not a child;
#   - the order is children first, the root last; a self-parented row (System Idle) ends;
#   - Stop-ProcessTree stops exactly that list, in that order;
#   - no PowerShell script still calls `taskkill ... /T`.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

hits="$(git -C "$repo_root" ls-files 'scripts/*.ps1' 'scripts/**/*.ps1' | while IFS= read -r f; do
    grep -nE '^[^#]*taskkill[^#]*/T' "$repo_root/$f" | sed "s|^|$f:|" || true
done)"
[ -z "$hits" ] || fail "taskkill /T follows reused parent ids - use Stop-ProcessTree:
$hits"
pass

if ! command -v pwsh >/dev/null 2>&1; then
    printf 'note: pwsh not installed - executed checks skipped\n'
    finish
    exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$t0 = [datetime]'2026-10-08 19:00:00'
function Row($id, $parent, $name, $created) { [pscustomobject]@{ Id = $id; ParentId = $parent; Name = $name; Path = ''; CommandLine = ''; Created = $created } }
$table = @(
    (Row 0 0 'System Idle Process' $null),
    (Row 100 1 'claude.exe' $t0),
    (Row 101 100 'serena.exe' $t0.AddSeconds(5)),
    (Row 102 101 'python.exe' $t0.AddSeconds(6)),
    (Row 103 100 'node.exe' $t0.AddSeconds(7)),
    # the reused id: Windows Terminal started long BEFORE pid 100 came to be Claude Code
    (Row 200 100 'WindowsTerminal.exe' $t0.AddHours(-18)),
    (Row 201 200 'wsl.exe' $t0.AddSeconds(30)),
    # no start time readable: not provably a child
    (Row 104 100 'mystery.exe' $null)
)
Write-Output ('tree=' + ((Get-ProcessTreeId -Id 100 -Table $table) -join ','))
Write-Output ('idle=' + ((Get-ProcessTreeId -Id 0 -Table $table) -join ','))
$global:stops = @()
# $global:, not $table: inside Get-ProcessTreeId the name $table is its own (empty) parameter
$global:fakeTable = $table
function Get-ProcessTable { $global:fakeTable }
function Stop-Process { param([int]$Id, [switch]$Force) $global:stops += $Id }
Stop-ProcessTree -Id 100
Write-Output ('stopped=' + ($global:stops -join ','))
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" </dev/null 2>&1 | tr -d '\r')"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300))"; }
# breadth-first 100,101,103,102 reversed: the deepest first, the root last
expect 'tree=102,103,101,100'
expect 'idle=0'
expect 'stopped=102,103,101,100'
pass

finish
