#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # PowerShell text is literal; dot_ask writes the named variable
set -euo pipefail

# A dot upgrade sat 26 minutes on "Stop them so everything upgrades now?" while its operator
# was out (2026-10-07: "your answers 25m54s" of a 27m26s run). This pins, EXECUTED:
#   1. bash dot_ask (scripts/lib/timing.sh): "y" without reading under --yes
#      (DOTUPGRADE_YES=1); the typed answer when there is one; after DOTUPGRADE_PROMPT_TIMEOUT
#      seconds the empty answer - every question's safe default - and a line saying so;
#      dot_ask_hint shows the wait (" (60s)"), nothing under --yes or with 0 (no timeout);
#   2. PowerShell Read-DotAnswer (scripts/lib/ps-common.ps1): "y" without asking under
#      `dot upgrade --yes` ($script:DotAnswerYes); otherwise the answer read; the timeout parse;
#   3. both dot upgrade scripts take --yes, every prompt goes through the timed reader, and
#      the PowerShell flag is script-scoped (an env var would outlive an interrupted run in
#      the operator's shell and answer later questions).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 3. wiring -------------------------------------------------------------------------------
grep -Fq -- '-y | --yes) export DOTUPGRADE_YES=1 ;;' "$repo_root/scripts/dotupgrade.sh" || fail "dotupgrade.sh: --yes is not handled"
grep -Fq "'^(-y|--yes|-Yes)\$' { \$script:DotAnswerYes = \$true }" "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1: --yes must set the script-scope flag"
if grep -Fq 'DOTUPGRADE_YES' "$repo_root/scripts/dotupgrade.ps1" "$repo_root/scripts/lib/ps-common.ps1"; then
    fail "PowerShell: --yes must not be an environment variable (it would outlive an interrupted run)"
fi
if grep -nE '^\s*read -r (answer|each)' "$repo_root/scripts/dotupgrade.sh"; then fail "dotupgrade.sh: a prompt still reads without the timeout (use dot_ask)"; fi
grep -Fq 'dot_ask answer' "$repo_root/scripts/lib/docker-vscode.sh" || fail "docker-vscode.sh: the Docker prompt must use dot_ask"
pass

# --- 1. bash dot_ask -------------------------------------------------------------------------
ask() { # env assignments via the caller; $1 = stdin text ("" = an open pipe that sends nothing)
    local feed="$1"
    if [ -n "$feed" ]; then
        printf '%s\n' "$feed" | bash -c '. "$1"; dot_ask got; printf "[%s]" "$got"' _ "$repo_root/scripts/lib/timing.sh" 2>"$tmp/err"
    else
        # stdin stays open but silent for 5 s: only the timeout can end the read
        (sleep 5) | bash -c '. "$1"; dot_ask got; printf "[%s]" "$got"' _ "$repo_root/scripts/lib/timing.sh" 2>"$tmp/err"
    fi
}
[ "$(DOTUPGRADE_YES=1 ask '')" = "[y]" ] || fail "sh: --yes must answer y without reading"
grep -Fq 'y (--yes)' "$tmp/err" || fail "sh: --yes must say it answered"
[ "$(ask 's')" = "[s]" ] || fail "sh: a typed answer must be returned"
[ "$(DOTUPGRADE_PROMPT_TIMEOUT=1 ask '')" = "[]" ] || fail "sh: no answer within the timeout must give the empty (default) answer"
# timed inside the reader (the feeding `sleep 5` keeps the pipeline itself open longer)
waited="$( (sleep 5) | DOTUPGRADE_PROMPT_TIMEOUT=1 bash -c 's=$SECONDS; . "$1"; dot_ask got 2>/dev/null; echo $((SECONDS - s))' _ "$repo_root/scripts/lib/timing.sh")"
[ "$waited" -lt 4 ] || fail "sh: the timeout must end the wait (took ${waited}s)"
grep -Fq 'no answer in 1s - taking the default: no' "$tmp/err" || fail "sh: a timed-out question must say so (got: $(cat "$tmp/err"))"
hint() { bash -c '. "$1"; printf "[%s]" "$(dot_ask_hint)"' _ "$repo_root/scripts/lib/timing.sh"; }
[ "$(hint)" = "[ (60s)]" ] || fail "sh: the default hint is ' (60s)' (got $(hint))"
[ "$(DOTUPGRADE_PROMPT_TIMEOUT=0 hint)" = "[]" ] || fail "sh: no hint when there is no timeout"
[ "$(DOTUPGRADE_YES=1 hint)" = "[]" ] || fail "sh: no hint under --yes"
[ "$(DOTUPGRADE_PROMPT_TIMEOUT=abc hint)" = "[ (60s)]" ] || fail "sh: a non-numeric timeout falls back to 60"
pass

# --- 2. PowerShell Read-DotAnswer --------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$global:reads = 0
function Read-Host { param($Prompt) $global:reads++; 's' }
# stdin is redirected here, so the console poll is unavailable and Read-Host answers
Write-Output ('plain=' + (Read-DotAnswer 'Q?') + '|reads=' + $global:reads)
$script:DotAnswerYes = $true
$global:reads = 0
Write-Output ('yes=' + (Read-DotAnswer 'Q?' 6>$null) + '|reads=' + $global:reads)
$script:DotAnswerYes = $false
$env:DOTUPGRADE_PROMPT_TIMEOUT = ''
Write-Output ('timeout-default=' + (Get-DotAnswerTimeout))
$env:DOTUPGRADE_PROMPT_TIMEOUT = '0'
Write-Output ('timeout-zero=' + (Get-DotAnswerTimeout))
$env:DOTUPGRADE_PROMPT_TIMEOUT = 'abc'
Write-Output ('timeout-bad=' + (Get-DotAnswerTimeout))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" </dev/null 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "ps1: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300))"; }
    expect 'plain=s|reads=1'
    expect 'yes=y|reads=0'
    expect 'timeout-default=60'
    expect 'timeout-zero=0'
    expect 'timeout-bad=60'
    pass
else
    printf 'note: pwsh not installed - PowerShell checks skipped\n'
fi

finish
