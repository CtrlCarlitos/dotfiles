#!/usr/bin/env bash
set -euo pipefail

# A run_onchange_install_packages.ps1 runs top to bottom, so a function must be DEFINED
# before the first top-level statement that calls it. The skills helpers
# (scripts/lib/ps-skills.ps1) were inlined near the skills section while the agent-browser
# step, hundreds of lines above, called Write-AgentBrowserDoctorSummary: on Windows
# `dot up` aborted with "The term 'Write-AgentBrowserDoctorSummary' is not recognized"
# (the earlier tests extracted each function on its own and never saw the order).
#
# The installer is RENDERED and parsed with PowerShell's own parser (no execution): every
# script-level function must come before any call to it that runs at script level (calls
# inside another function's body run later and are not judged here).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":true,"dev_desktop":true,"vscode_settings":true'
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{$groups},\"accounts\":[]}" \
    <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/installer.ps1"
[ -s "$tmp/installer.ps1" ] || fail 'the installer did not render'

cat >"$tmp/check.ps1" <<'PSEOF'
param([string]$Rendered)
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Rendered, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { Write-Output "PARSE-ERROR $($errors[0].Message) line $($errors[0].Extent.StartLineNumber)"; exit 0 }

function Test-InsideFunction($node) {
    for ($p = $node.Parent; $p; $p = $p.Parent) {
        if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $true }
    }
    return $false
}

$defs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
    Where-Object { -not (Test-InsideFunction $_) }
$defined = 0
foreach ($def in $defs) {
    $defined++
    $early = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq $def.Name -and
            $n.Extent.StartOffset -lt $def.Extent.StartOffset }, $true) |
        Where-Object { -not (Test-InsideFunction $_) }
    foreach ($call in $early) {
        Write-Output "EARLY $($def.Name): called at line $($call.Extent.StartLineNumber), defined at line $($def.Extent.StartLineNumber)"
    }
}
Write-Output "FUNCTIONS $defined"
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/check.ps1")" -Rendered "$(winpath "$tmp/installer.ps1")" 2>&1 | tr -d '\r')"

printf '%s\n' "$out" | grep -q '^PARSE-ERROR' && fail "the rendered installer does not parse: $(printf '%s' "$out" | grep '^PARSE-ERROR' | head -1)"
n="$(printf '%s\n' "$out" | sed -n 's/^FUNCTIONS //p')"
[ "${n:-0}" -ge 20 ] || fail "expected the rendered installer to define 20+ script-level functions (parser found: ${n:-0}) - is the parse broken?"
early="$(printf '%s\n' "$out" | grep '^EARLY ' || true)"
[ -z "$early" ] || fail "functions called at script level before they are defined (the run aborts with 'not recognized'):
$early"
pass

finish
