#!/usr/bin/env bash
set -euo pipefail

# Under `Set-StrictMode -Version Latest`, READING a variable that was never set is a
# terminating error. The Windows installer runs under it, and #231 added a once-per-run
# guard in Install-Node:
#
#     if (-not $script:NpmUpgraded -and (Get-Command npm ...)) { $script:NpmUpgraded = $true; ... }
#
# with no initialiser, so the first `dot up` that reached Install-Node failed with
# "The variable '$script:NpmUpgraded' cannot be retrieved because it has not been set".
# CI never saw it: its Windows jobs run with every package group off, so Install-Node
# never executes there.
#
# This holds the whole class, not the one line: every `$script:Name` that is READ must
# be assigned at script scope (outside any function) BEFORE the function that reads it
# is defined. Checked with PowerShell's own parser on the RENDERED installer and on the
# plain scripts that set strict mode. The checker is itself verified on known-bad and
# known-good fixtures first, so it cannot quietly start accepting everything.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'
command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/check.ps1" <<'PSEOF'
param([string[]]$File)
$FnAst = [System.Management.Automation.Language.FunctionDefinitionAst]
$VarAst = [System.Management.Automation.Language.VariableExpressionAst]
$AssignAst = [System.Management.Automation.Language.AssignmentStatementAst]
function Test-IsAssignTarget($v) { ($v.Parent -is $AssignAst) -and ($v.Parent.Left -eq $v) }
function Get-OuterFunction($n) {
    $found = $null
    for ($a = $n.Parent; $a; $a = $a.Parent) { if ($a -is $FnAst) { $found = $a } }
    return $found
}
foreach ($f in $File) {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
    if ($errs.Count -gt 0) { "$f : does not parse ($($errs.Count) errors)"; continue }
    $vars = $ast.FindAll({ param($n) $n -is $VarAst -and $n.VariablePath.IsScript }, $true)
    foreach ($v in $vars) {
        if (Test-IsAssignTarget $v) { continue }
        $name = $v.VariablePath.UserPath -replace '^script:', ''
        $fn = Get-OuterFunction $v
        $anchor = if ($fn) { $fn.Extent.StartOffset } else { $v.Extent.StartOffset }
        $initialised = $vars | Where-Object {
            (Test-IsAssignTarget $_) -and
            ($_.VariablePath.UserPath -replace '^script:', '') -eq $name -and
            -not (Get-OuterFunction $_) -and
            $_.Extent.StartOffset -lt $anchor
        }
        if (-not $initialised) {
            $where = if ($fn) { "in function $($fn.Name)" } else { 'at script scope' }
            "$f : `$script:$name is read at line $($v.Extent.StartLineNumber) ($where) with no script-scope assignment before it"
        }
    }
}
PSEOF

run_check() { pwsh -NoProfile -File "$(winpath "$tmp/check.ps1")" "$@" | tr -d '\r'; }

# --- the checker, on fixtures ------------------------------------------------------------
cat >"$tmp/bad-function.ps1" <<'EOF'
Set-StrictMode -Version Latest
function Install-Thing {
    if (-not $script:Once) { $script:Once = $true }
}
Install-Thing
EOF
cat >"$tmp/bad-late-init.ps1" <<'EOF'
Set-StrictMode -Version Latest
function Install-Thing { if (-not $script:Once) { $script:Once = $true } }
$script:Once = $false
Install-Thing
EOF
cat >"$tmp/bad-toplevel-read.ps1" <<'EOF'
Set-StrictMode -Version Latest
if ($script:Flag) { 'x' }
$script:Flag = $true
EOF
cat >"$tmp/good.ps1" <<'EOF'
Set-StrictMode -Version Latest
$script:Once = $false
function Install-Thing {
    if (-not $script:Once) { $script:Once = $true }
}
Install-Thing
EOF
for bad in bad-function bad-late-init bad-toplevel-read; do
    out="$(run_check "$(winpath "$tmp/$bad.ps1")")"
    if grep -Fq 'no script-scope assignment before it' <<<"$out"; then pass; else
        fail "the checker must flag $bad.ps1 (got: ${out:-nothing})"
    fi
done
out="$(run_check "$(winpath "$tmp/good.ps1")")"
[ -z "$out" ] || fail "the checker must accept an initialised variable (got: $out)"

# --- the real scripts -------------------------------------------------------------------------
groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":false,"remote_access_server":false,"guardrail":true,"dev_desktop":false,"vscode_settings":false'
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{$groups},\"accounts\":[]}" \
    <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/installer.ps1"
[ -s "$tmp/installer.ps1" ] || fail 'the installer did not render'

targets=("$(winpath "$tmp/installer.ps1")")
for s in "$repo_root"/scripts/*.ps1; do
    if grep -q 'Set-StrictMode' "$s"; then targets+=("$(winpath "$s")"); fi
done
out="$(run_check "${targets[@]}")"
if [ -z "$out" ]; then pass; else
    fail "script-scope variables read without an initialiser (a strict-mode failure on the first run):
$out"
fi

# --- the failing path, EXECUTED ------------------------------------------------------------
# The static rule above is the class; this runs the actual function that broke. Install-Node
# is extracted from the rendered installer and called twice under Set-StrictMode -Version
# Latest with only the external commands stubbed: it must not throw, and the npm upgrade
# must run once (the guard's whole purpose: four groups call Install-Node and each repeat
# cost 8-40 s). Run on pwsh and, where present, Windows PowerShell 5.1 - the installer's
# real interpreter.
cat >"$tmp/run-install-node.ps1" <<'PSEOF'
param([string]$Rendered)
$lines = Get-Content -LiteralPath $Rendered
function Get-FunctionText($name) {
    $start = ($lines | Select-String -Pattern "^function $name \{" | Select-Object -First 1).LineNumber - 1
    $end = $start
    while ($lines[$end] -ne '}') { $end++ }
    ($lines[$start..$end]) -join "`n"
}
$start = ($lines | Select-String -Pattern '^function Install-Node \{' | Select-Object -First 1).LineNumber - 1
# Install-Node delegates the once-per-run npm upgrade to Invoke-NpmUpgradeOnce.
$fn = (Get-FunctionText 'Invoke-NpmUpgradeOnce') + "`n" + (Get-FunctionText 'Install-Node')
$init = ($lines[0..$start] | Where-Object { $_ -match '^\$script:NpmUpgraded\s*=' }) -join "`n"
Set-StrictMode -Version Latest
$script:calls = 0
function Get-Command { $true }
function node { 'v99.0.0' }
# npm reports an older version than the registry, so the upgrade is due (once).
function npm { if ($args[0] -eq 'view') { '99.0.0' } else { '1.0.0' } }
function Invoke-Quietly { param($Description, $Action) $script:calls++ }
if ($init) { Invoke-Expression $init }
Invoke-Expression $fn
try { Install-Node; Install-Node; "OK upgrades=$script:calls" } catch { "FAIL $($_.Exception.Message)" }
PSEOF
for ps in pwsh powershell; do
    command -v "$ps" >/dev/null 2>&1 || continue
    out="$("$ps" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$tmp/run-install-node.ps1")" "$(winpath "$tmp/installer.ps1")" 2>&1 | tr -d '\r' | tail -n 1)"
    if [ "$out" = 'OK upgrades=1' ]; then pass; else
        fail "$ps: Install-Node must run twice under strict mode and upgrade npm once (got: $out)"
    fi
done

finish
