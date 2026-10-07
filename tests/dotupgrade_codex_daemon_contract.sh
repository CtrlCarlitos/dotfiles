#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the sourced/extracted code consumes these
set -euo pipefail

# Codex's shared app-server daemon keeps running the release it started with, so after
# `dot upgrade` replaced the CLI it stayed several versions behind until something restarted
# it. It is not a session (it never defers anything) and restarts on demand, so `dot upgrade`
# now stops it before the sweep - but only when no Codex session is left, and never a CLI
# session. Both twins are EXECUTED against a fake process table:
#   scripts/dotupgrade.sh      codex_daemon_pids / stop_codex_daemon   (pgrep + ps + codex)
#   scripts/lib/ps-common.ps1  Get-CodexDaemonProcess / Stop-CodexDaemon (Get-Process + Start-Process)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# The wiring: the stop happens after sessions were offered a stop, and only with no live codex.
grep -Fq 'live codex || stop_codex_daemon' "$repo_root/scripts/dotupgrade.sh" \
    || fail "dotupgrade.sh must stop the daemon only when no Codex session is live"
grep -Fq "if (-not (Test-LiveProcess @('codex')))" "$repo_root/scripts/dotupgrade.ps1" \
    || fail "dotupgrade.ps1 must stop the daemon only when no Codex session is live"

# --- shell twin ------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -x ] || exit 2
found=1
while read -r name pid _; do
    if [ "$name" = "$2" ]; then echo "$pid"; found=0; fi
done <"$PROC_TABLE"
exit "$found"
EOF
cat >"$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
pid="${@: -1}"
while read -r name p args; do
    if [ "$p" = "$pid" ]; then printf '%s\n' "$args"; fi
done <"$PROC_TABLE"
EOF
cat >"$tmp/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat >"$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex $*" >>"$CALLS"
# A working `daemon stop` removes the daemon from the table; CODEX_STOP_FAILS=1 leaves it.
if [ "$*" = "app-server daemon stop" ] && [ "${CODEX_STOP_FAILS:-0}" != 1 ]; then
    grep -v 'app-server-daemon' "$PROC_TABLE" >"$PROC_TABLE.new" || true
    mv "$PROC_TABLE.new" "$PROC_TABLE"
fi
EOF
chmod +x "$tmp/bin/"*

extract_fn() {
    awk -v n="$1" 'index($0, n "() {") == 1 {f=1; print; next} f{print} f && /^\}$/{exit}' "$2"
}
{ extract_fn codex_daemon_pids "$repo_root/scripts/dotupgrade.sh"; extract_fn stop_codex_daemon "$repo_root/scripts/dotupgrade.sh"; } >"$tmp/daemon.sh"
[ -s "$tmp/daemon.sh" ] || fail "stop_codex_daemon not found in scripts/dotupgrade.sh"

sh_case() { # $1 = process table, $2 = CODEX_STOP_FAILS; prints "calls|kills|message"
    printf '%s\n' "$1" >"$tmp/table"
    : >"$tmp/calls"; : >"$tmp/kills"
    (
        export PROC_TABLE="$tmp/table" CALLS="$tmp/calls" CODEX_STOP_FAILS="$2" PATH="$tmp/bin:$PATH"
        kill() { echo "kill $*" >>"$tmp/kills"; }
        # the daemon goes as a tree (its helpers: code-mode host, command runner, voice host)
        stop_pid_tree() { echo "tree $*" >>"$tmp/kills"; }
        eval "$(cat "$tmp/daemon.sh")"
        msg="$(stop_codex_daemon)"
        printf '%s|%s|%s\n' "$(tr '\n' ';' <"$tmp/calls")" "$(tr '\n' ';' <"$tmp/kills")" "${msg:+stopped}"
    )
}
daemon='codex 100 /home/u/.codex/packages/app-server-daemon/releases/local-abc/bin/codex app-server --listen unix://'
cli='codex 200 /usr/lib/node_modules/@openai/codex/bin/codex'

[ "$(sh_case "$daemon" 0)" = "codex app-server daemon stop;||stopped" ] \
    || fail "sh: a running daemon is stopped through the CLI (got $(sh_case "$daemon" 0))"
[ "$(sh_case "$daemon" 1)" = "codex app-server daemon stop;|tree 100;|stopped" ] \
    || fail "sh: when the CLI stop does not take, the daemon pid is ended (got $(sh_case "$daemon" 1))"
[ "$(sh_case "$cli" 0)" = "||" ] || fail "sh: a Codex CLI session alone is never touched (got $(sh_case "$cli" 0))"
r="$(sh_case "$daemon
$cli" 1)"
[ "$r" = "codex app-server daemon stop;|tree 100;|stopped" ] || fail "sh: only the daemon pid is ended, never the CLI (got $r)"
[ "$(sh_case "" 0)" = "||" ] || fail "sh: nothing running means nothing happens"
pass

# --- PowerShell twin -------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:table = @()
$script:calls = New-Object System.Collections.Generic.List[string]
$script:stopFails = $false
function Get-Process { param([Parameter(Position = 0)][string[]]$Name) foreach ($n in $Name) { $script:table | Where-Object { $_.ProcessName -eq $n } } }
function Get-Command { param([string]$Name) [pscustomobject]@{ Source = 'codex.cmd' } }
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru)
    $script:calls.Add("start $($ArgumentList -join ' ')")
    if (-not $script:stopFails) { $script:table = @($script:table | Where-Object { $_.Path -notmatch 'app-server-daemon' }) }
    $p = [pscustomobject]@{}
    $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
    $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
    $p
}
# The stubborn daemon goes as a TREE: it runs helpers (codex-code-mode-host, codex-command-runner,
# codex-voice-host) that a plain Stop-Process would leave behind.
function taskkill { $script:calls.Add("taskkill $($args -join ' ')"); $global:LASTEXITCODE = 0 }
function Stop-Process { param($Id, [switch]$Force) $script:calls.Add("stop $Id") }
function P($id, $path) { [pscustomobject]@{ ProcessName = 'codex'; Id = $id; Path = $path } }
function Case($label, $rows, $fails) {
    $script:table = @($rows); $script:calls.Clear(); $script:stopFails = $fails
    $n = Stop-CodexDaemon
    Write-Output ("$label=$n|" + ($script:calls -join ';'))
}
$daemon = P 100 'C:\Users\u\.codex\packages\app-server-daemon\releases\local-abc\bin\codex.exe'
$cli    = P 200 'C:\Users\u\AppData\Roaming\npm-global\node_modules\@openai\codex\vendor\codex.exe'
$blind  = P 300 $null
Case 'daemon' @($daemon) $false
Case 'daemon-stubborn' @($daemon) $true
Case 'cli-only' @($cli) $false
Case 'both-stubborn' @($daemon, $cli) $true
Case 'unreadable' @($blind) $false
Case 'nothing' @() $false
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'daemon=1|start app-server daemon stop'
    expect 'daemon-stubborn=1|start app-server daemon stop;taskkill /PID 100 /T /F'
    expect 'cli-only=0|'
    expect 'both-stubborn=1|start app-server daemon stop;taskkill /PID 100 /T /F'
    expect 'unreadable=0|'
    expect 'nothing=0|'
    pass
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
