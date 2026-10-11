#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the PowerShell below runs in its own process
set -euo pipefail

# A Windows `dot up` spent 74 minutes in mobile_dev with no sign of life: Invoke-MobileDevTool
# (run_onchange_install_packages.ps1.tmpl) captured sdkmanager's output with `| Out-String`, which
# prints nothing until the tool exits. It now runs the tool with output going to files, prints a
# heartbeat line while it runs, feeds stdin from a file, and still reports a failure with the
# tail of the output. The function is extracted from the template and EXECUTED against a fake
# tool (a .cmd on Windows, a shell script elsewhere).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed - cannot execute Invoke-MobileDevTool"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

template="$repo_root/run_onchange_install_packages.ps1.tmpl"
# the function, from its header to the first closing brace at column 0
awk '/^function Invoke-MobileDevTool \{/ {on=1} on {print} on && /^\}/ {exit}' "$template" | tr -d '\r' >"$tmp/fn.ps1"
[ -s "$tmp/fn.ps1" ] || { fail "could not extract Invoke-MobileDevTool from the template"; finish; exit 1; }

if command -v cygpath >/dev/null 2>&1; then
    ext="cmd"
    cat >"$tmp/ok.$ext" <<'T'
@echo off
set /p L=
echo got:%L%
exit /b 0
T
    cat >"$tmp/bad.$ext" <<'T'
@echo off
echo first line
echo the real reason it failed
exit /b 3
T
    cat >"$tmp/slow.$ext" <<'T'
@echo off
ping -n 4 127.0.0.1 >nul
exit /b 0
T
else
    ext="sh"
    printf '#!/bin/sh\nread L\necho "got:$L"\nexit 0\n' >"$tmp/ok.$ext"
    printf '#!/bin/sh\necho first line\necho the real reason it failed\nexit 3\n' >"$tmp/bad.$ext"
    printf '#!/bin/sh\nsleep 3\nexit 0\n' >"$tmp/slow.$ext"
    chmod +x "$tmp/ok.$ext" "$tmp/bad.$ext" "$tmp/slow.$ext"
fi

cat >"$tmp/harness.ps1" <<'EOF2'
param([string]$Timing, [string]$Fn, [string]$Dir, [string]$Ext)
$ErrorActionPreference = 'Stop'
. $Timing
. $Fn
$sdk = Join-Path $Dir 'sdk'
New-Item -ItemType Directory -Force -Path (Join-Path $sdk '.temp') | Out-Null
[System.IO.File]::WriteAllBytes((Join-Path $sdk '.temp\blob.bin'), (New-Object byte[] (3MB)))

$rc = Invoke-MobileDevTool -Path (Join-Path $Dir "ok.$Ext") -ToolArguments @('a') -StdIn 'yes-please' -FailureLabel 'ok-tool'
"OK-RC=$rc"
$rc = Invoke-MobileDevTool -Path (Join-Path $Dir "bad.$Ext") -ToolArguments @('a') -FailureLabel 'bad-tool'
"BAD-RC=$rc"
$rc = Invoke-MobileDevTool -Path (Join-Path $Dir "slow.$Ext") -ToolArguments @('a') -FailureLabel 'slow-tool' -ProgressDir $sdk -HeartbeatSeconds 1
"SLOW-RC=$rc"
EOF2

out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Timing "$(winpath "$repo_root/scripts/lib/ps-timing.ps1")" -Fn "$(winpath "$tmp/fn.ps1")" -Dir "$(winpath "$tmp")" -Ext "$ext" 2>&1 | tr -d '\r' || true)"

case "$out" in *OK-RC=0*) pass ;; *) fail "a succeeding tool must return 0 (output: $out)" ;; esac
case "$out" in *'Warning: ok-tool failed'*) fail "a succeeding tool must not warn (output: $out)" ;; *) pass ;; esac
case "$out" in *BAD-RC=3*) pass ;; *) fail "a failing tool must return its exit code (output: $out)" ;; esac
case "$out" in *'Warning: bad-tool failed (exit code 3)'*'the real reason it failed'*) pass ;; *) fail "a failure must print the tail of the tool's output (output: $out)" ;; esac
case "$out" in *SLOW-RC=0*) pass ;; *) fail "a slow tool must still return 0 (output: $out)" ;; esac
case "$out" in *'slow-tool still running'*'3 MB staged'*) pass ;; *) fail "a long run must print a heartbeat with the staged size (output: $out)" ;; esac

# the stdin contract is the tool's: the fed answer must reach it. The helper returns only the code, so
# check through a failing path of its own: a tool that echoes stdin and exits non-zero.
if [ "$ext" = cmd ]; then
    printf '@echo off\nset /p L=\necho got:%%L%%\nexit /b 4\n' >"$tmp/echo.$ext"
else
    printf '#!/bin/sh\nread L\necho "got:$L"\nexit 4\n' >"$tmp/echo.$ext"; chmod +x "$tmp/echo.$ext"
fi
cat >"$tmp/harness2.ps1" <<'EOF2'
param([string]$Timing, [string]$Fn, [string]$Dir, [string]$Ext)
. $Timing
. $Fn
$null = Invoke-MobileDevTool -Path (Join-Path $Dir "echo.$Ext") -ToolArguments @('a') -StdIn 'yes-please' -FailureLabel 'echo-tool'
EOF2
out2="$(pwsh -NoProfile -File "$(winpath "$tmp/harness2.ps1")" -Timing "$(winpath "$repo_root/scripts/lib/ps-timing.ps1")" -Fn "$(winpath "$tmp/fn.ps1")" -Dir "$(winpath "$tmp")" -Ext "$ext" 2>&1 | tr -d '\r' || true)"
case "$out2" in *'got:yes-please'*) pass ;; *) fail "the StdIn answers must reach the tool (output: $out2)" ;; esac

# the old shape must not come back
forbid "$template" '| Out-String)'" 2>&1"
finish
