#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# Windows `dot up` printed claude's whole `claude mcp get serena` report (scope, status, type,
# command, args, "To remove this server, run ...") every time, because the probe was written
# `claude mcp get serena 2>$null`: that hides stderr only, and the report is stdout. The probe
# only needs the exit code. The statement is EXTRACTED from the rendered installer and run
# against a fake `claude` that prints like the real one, so a regression shows up as output.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v chezmoi >/dev/null 2>&1 || skip 'chezmoi not installed'
command -v pwsh >/dev/null 2>&1 || skip 'pwsh not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

groups='"core":true,"modern_cli":true,"fonts":true,"agent_toolkit":true,"opencode_cli":true,"opencode_desktop":false,"claude_cli":true,"claude_desktop":false,"chatgpt_cli":true,"chatgpt_desktop":false,"antigravity_cli":true,"antigravity_desktop":false,"remote_access":true,"remote_access_server":true,"guardrail":false,"dev_desktop":true,"vscode_settings":false'
render --override-data "{\"chezmoi\":{\"os\":\"windows\"},\"packages\":{$groups},\"accounts\":[]}" \
    <"$repo_root/run_onchange_install_packages.ps1.tmpl" | tr -d '\r' >"$tmp/installer.ps1"
[ -s "$tmp/installer.ps1" ] || fail 'the installer did not render'

probe="$(grep -m1 'claude mcp get serena' "$tmp/installer.ps1" | sed 's/^[[:space:]]*//')"
[ -n "$probe" ] || fail "the serena probe (claude mcp get serena) is gone from the installer"
printf '%s\n' "$probe" >"$tmp/probe-line.ps1"

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$ProbeFile)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:claudeExit = 0
function claude {
    'serena:'; '  Scope: User config (available in all your projects)'; '  Status: Connected'
    '  Type: stdio'; 'To remove this server, run: claude mcp remove serena -s user'
    Write-Error 'stderr noise' -ErrorAction Continue
    $global:LASTEXITCODE = $script:claudeExit
}
# Dot-sourced so the statement's `$claudeHasSerena = ...` lands in THIS scope; everything it
# prints is redirected to a file, which must stay empty.
$probe = [scriptblock]::Create((Get-Content -Raw -LiteralPath $ProbeFile))
$sink = Join-Path ([IO.Path]::GetTempPath()) ('probe-' + [guid]::NewGuid().ToString('N') + '.txt')
$claudeHasSerena = $false
$script:claudeExit = 0
. $probe *> $sink
Write-Output ('registered-flag=' + $claudeHasSerena)
Write-Output ('registered-silent=' + ((Get-Content -Raw -LiteralPath $sink -ErrorAction SilentlyContinue) -eq $null))
Remove-Item -LiteralPath $sink -ErrorAction SilentlyContinue
$claudeHasSerena = $false
$script:claudeExit = 1
. $probe *> $sink
Write-Output ('missing-flag=' + $claudeHasSerena)
Write-Output ('missing-silent=' + ((Get-Content -Raw -LiteralPath $sink -ErrorAction SilentlyContinue) -eq $null))
Remove-Item -LiteralPath $sink -ErrorAction SilentlyContinue
PSEOF

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -ProbeFile "$(winpath "$tmp/probe-line.ps1")" 2>&1 | tr -d '\r' || true)"
expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500))"; }
expect 'registered-flag=True'
expect 'registered-silent=True'
expect 'missing-flag=False'
expect 'missing-silent=True'
pass

finish
