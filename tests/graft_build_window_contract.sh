#!/usr/bin/env bash
# shellcheck disable=SC2016  # PowerShell text is literal
set -euo pipefail

# graft's index refresh (dist/claude/sync-run.js) runs `graft build` with execFileSync from a
# detached, consoleless process and without windowsHide, so Windows gave the build a console of
# its own: with Windows Terminal as the default terminal, a "node.exe" Terminal window flashed
# at the end of every agent turn that edited files (captured 2026-10-07, graft 0.21.1).
# Repair-GraftBuildWindow (scripts/lib/ps-skills.ps1) adds windowsHide: true to that one call
# until graft ships the fix. This pins, EXECUTED against fixture copies of the file:
#   a. the 0.21.1 line          -> patched, windowsHide present, the rest byte-identical
#   b. run again                -> ok (idempotent), file unchanged
#   c. graft changed the line   -> changed, file untouched
#   d. graft hides it itself    -> ok, file untouched
#   e. no sync-run.js           -> absent
# and that `dot up` (installer) and `dot upgrade` run it on every pass.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

grep -Fq 'Write-GraftBuildWindowResult -Result (Repair-GraftBuildWindow)' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "installer: Repair-GraftBuildWindow must run on every pass"
grep -Fq '{{ include "scripts/lib/ps-skills.ps1" }}' "$repo_root/run_onchange_install_packages.ps1.tmpl" ||
    fail "installer: ps-skills.ps1 (where Repair-GraftBuildWindow lives) must be inlined"
grep -Fq 'Write-GraftBuildWindowResult -Result (Repair-GraftBuildWindow)' "$repo_root/scripts/update_ai_tools.ps1" ||
    fail "update_ai_tools.ps1: Repair-GraftBuildWindow must run after the graft step"
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
param([string]$Lib, [string]$Root)
Set-StrictMode -Version Latest
. $Lib
function Fixture($name, $line) {
    $dir = Join-Path $Root $name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'dist\claude') | Out-Null
    $text = "import { execFileSync } from 'node:child_process';`n    $line`nexport function runSync(dir) {}`n"
    [IO.File]::WriteAllText((Join-Path $dir 'dist\claude\sync-run.js'), $text)
    return $dir
}
function Body($dir) { [IO.File]::ReadAllText((Join-Path $dir 'dist\claude\sync-run.js')) }
$orig = "execFileSync(process.execPath, args, { cwd: dir, stdio: 'ignore', timeout: 120000 });"
$a = Fixture 'a' $orig
$before = Body $a
Write-Output ('a=' + (Repair-GraftBuildWindow -GraftRoot $a))
$after = Body $a
Write-Output ('a-hidden=' + $after.Contains("{ cwd: dir, stdio: 'ignore', timeout: 120000, windowsHide: true }"))
Write-Output ('a-rest-same=' + ($after.Replace(', windowsHide: true', '') -eq $before))
Write-Output ('b=' + (Repair-GraftBuildWindow -GraftRoot $a) + '|' + ((Body $a) -eq $after))
$c = Fixture 'c' "execFileSync(process.execPath, args, { cwd: dir, stdio: 'ignore', timeout: 300000 });"
$cBefore = Body $c
Write-Output ('c=' + (Repair-GraftBuildWindow -GraftRoot $c) + '|' + ((Body $c) -eq $cBefore))
$d = Fixture 'd' "execFileSync(process.execPath, args, { cwd: dir, stdio: 'ignore', windowsHide: true });"
$dBefore = Body $d
Write-Output ('d=' + (Repair-GraftBuildWindow -GraftRoot $d) + '|' + ((Body $d) -eq $dBefore))
Write-Output ('e=' + (Repair-GraftBuildWindow -GraftRoot (Join-Path $Root 'nothing-here')))
Write-Output ('msg-patched=' + ((Write-GraftBuildWindowResult -Result 'patched' 6>&1 | Out-String) -match 'no longer opens a terminal window'))
Write-Output ('msg-ok-silent=' + [string]::IsNullOrWhiteSpace((Write-GraftBuildWindowResult -Result 'ok' 6>&1 | Out-String)))
PSEOF
out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-skills.ps1")" -Root "$(winpath "$tmp")" 2>&1 | tr -d '\r')"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
expect 'a=patched'
expect 'a-hidden=True'
expect 'a-rest-same=True'
expect 'b=ok|True'
expect 'c=changed|True'
expect 'd=ok|True'
expect 'e=absent'
expect 'msg-patched=True'
expect 'msg-ok-silent=True'
pass

finish
