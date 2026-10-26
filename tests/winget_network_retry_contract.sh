#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317  # PowerShell text is literal; the PowerShell below runs in its own process
set -euo pipefail

# A fresh install on LAB-DOT-WIN-HOM (#434 Run 8, 2026-10-25) left Go missing: one winget call failed in
# under a second with 0x80072EE7 (InternetOpenUrl, name not resolved) while the installs either side of it
# succeeded. The loop printed the exit code and went on, the run ended "[v] Done!", and nothing would ever
# retry it: this installer is run_onchange, so the next `dot up` does not rerun it, and `winget upgrade
# --all` (dot upgrade) never installs a missing package.
#   - a network-class winget failure is retried once, after a pause (Invoke-DotWingetInstall);
#   - any other failure, a timeout or an unknown code is not retried;
#   - what still failed is named at the end, with the command that reruns the installer.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmpl="$repo_root/run_onchange_install_packages.ps1.tmpl"
lib="$repo_root/scripts/lib/ps-winget-retry.ps1"

# --- wiring (works without pwsh) -----------------------------------------------------------------
[ -f "$lib" ] || fail "scripts/lib/ps-winget-retry.ps1 must exist"
require "$tmpl" 'include "scripts/lib/ps-winget-retry.ps1"'
require "$tmpl" 'Invoke-DotWingetInstall -Id $wingetId'
# the job reports winget's exit code back (a streamed job's own exit code is lost)
require "$tmpl" '$env:WINGET_RC_FILE'
require "$tmpl" '$wingetFailed += $wingetId'
require "$tmpl" 'Write-DotWingetFailedNote -Failed $wingetFailed'
note_line="$(grep -n 'Write-DotWingetFailedNote -Failed' "$tmpl" | head -n 1 | cut -d: -f1 || true)"
done_line="$(grep -n 'Write-Host "Package installation complete!"' "$tmpl" | head -n 1 | cut -d: -f1 || true)"
if [ -z "$note_line" ] || [ -z "$done_line" ] || [ "$note_line" -le "$done_line" ]; then
    fail "the failed-package note must follow 'Package installation complete!' (note '${note_line:-none}', done '${done_line:-none}')"
fi
pass

# --- the helpers, executed ----------------------------------------------------------------------
command -v pwsh >/dev/null 2>&1 || { printf 'SKIP (helpers run under PowerShell): pwsh not installed\n'; finish; exit 0; }
[ -f "$lib" ] || { finish; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $Lib
function Start-Sleep { param([int]$Seconds) $script:Slept += $Seconds }

# Each case hands Invoke-DotWingetInstall a fake attempt that returns the next code from the list.
function Case($label, [object[]]$codes) {
    $script:Codes = $codes; $script:Calls = 0; $script:Slept = 0
    $said = (Invoke-DotWingetInstall -Id 'GoLang.Go' -RetryDelaySeconds 15 -Attempt {
        $code = $script:Codes[$script:Calls]; $script:Calls++; $code
    } 6>&1 | ForEach-Object { "$_" })
    $result = @($said | Where-Object { $_ -notmatch '^\s' -and $_ -ne '' })
    $printed = @($said | Where-Object { $_ -match '^\s' }) -join ' '
    Write-Output ("$label calls=$($script:Calls) slept=$($script:Slept) result=$($result -join ',') said=[$printed]")
}
Case 'ok' @(0)
Case 'dns-then-ok' @(-2147012889, 0)
Case 'dns-twice' @(-2147012889, -2147012889)
Case 'timeout-code' @(-2147012894, 0)
Case 'cannot-connect' @(-2147012867, 0)
Case 'reset' @(-2147012865, 0)
# 0x8A150014 = no package found: winget answered, so asking again cannot help
Case 'not-found' @(-1978335212, 0)
Case 'plain-fail' @(1, 0)
# the job timed out or never wrote its exit code: unknown, not retried
Case 'unknown' @($null, 0)

Write-Output ("name-ee7=" + (Get-DotWingetNetworkError -ExitCode -2147012889))
Write-Output ("name-zero=" + [bool](Get-DotWingetNetworkError -ExitCode 0))
Write-Output ("name-null=" + [bool](Get-DotWingetNetworkError -ExitCode $null))

$none = (Write-DotWingetFailedNote -Failed @() -InstallerKey 'C:/Users/lab/install_packages.ps1' 6>&1 | ForEach-Object { "$_" }) -join ' '
Write-Output "note-none=[$none]"
$some = (Write-DotWingetFailedNote -Failed @('GoLang.Go', 'Hashicorp.Terraform') -InstallerKey 'C:/Users/lab/install_packages.ps1' 6>&1 | ForEach-Object { "$_" }) -join ' '
Write-Output "note-some=[$some]"
Write-Output 'harness-done'
PSEOF

shells=(pwsh)
command -v powershell.exe >/dev/null 2>&1 && shells+=(powershell.exe)
for sh in "${shells[@]}"; do
    out="$("$sh" -NoProfile -NonInteractive -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$lib")" 2>&1 | tr -d '\r')" || fail "$sh: the harness must run: $out"
    # check LABEL CALLS SLEPT RESULT [SAID]: attempts made, seconds paused, the code returned, and a fixed
    # substring of what it printed (none given: it must print nothing)
    check() {
        local got want="$1 calls=$2 slept=$3 result=$4 said=["
        got="$(printf '%s\n' "$out" | grep "^$1 " || true)"
        case "$got" in
            "$want"*) ;;
            *) fail "$sh: $1: expected '$want...' (got: '${got:-no line}')"; return ;;
        esac
        if [ -n "${5:-}" ]; then
            case "$got" in *"$5"*) pass ;; *) fail "$sh: $1: expected the output to say '$5' (got: '$got')" ;; esac
        else
            case "$got" in *"said=[]") pass ;; *) fail "$sh: $1: expected no output (got: '$got')" ;; esac
        fi
    }
    check ok 1 0 0
    check dns-then-ok 2 15 0 'could not reach the network (0x80072EE7'
    check dns-twice 2 15 -2147012889 'trying once more in 15s'
    check timeout-code 2 15 0 '0x80072EE2'
    check cannot-connect 2 15 0 '0x80072EFD'
    check reset 2 15 0 '0x80072EFF'
    check not-found 1 0 -1978335212
    check plain-fail 1 0 1
    check unknown 1 0 ''
    expect() { case "$out" in *"$1"*) pass ;; *) fail "$sh: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-900))" ;; esac; }
    expect 'name-ee7=0x80072EE7'
    expect 'name-zero=False'
    expect 'name-null=False'
    expect 'note-none=[]'
    expect 'GoLang.Go, Hashicorp.Terraform'
    expect 'chezmoi state delete --bucket=entryState --key=C:/Users/lab/install_packages.ps1'
    expect 'harness-done'
done

finish
