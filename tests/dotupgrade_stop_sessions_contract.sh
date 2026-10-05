#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the sourced/extracted code consumes these
set -euo pipefail

# `dot upgrade` used to only defer when an agent session was live, leaving the tool
# un-upgraded until the operator closed things by hand. It now offers to stop the blockers
# on an interactive console. The rules this pins (both twins are EXECUTED, with fake
# process tables and a recorded stop):
#   - nothing is stopped unless the operator answers y (all) or s (choose each);
#   - the invoker's own ancestry is never offered;
#   - a non-interactive console and DOTUPGRADE_NO_PROMPT=1 keep defer-and-report;
#   - nothing running means no prompt at all.
#   scripts/dotupgrade.sh        live_pids / stop_live_sessions   (pgrep + ps)
#   scripts/lib/ps-common.ps1    Invoke-LiveSessionStop           (Get-Process)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- shell twin ------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
# pgrep -x NAME: pids from the fake table "name pid args...", exit 1 when none; -P PID: none
[ "$1" = -x ] || exit 1
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
    if [ "$p" = "$pid" ]; then
        case "$*" in *comm=*) echo "$name" ;; *etime=*) echo "01:00" ;; *) printf '%s\n' "$args" ;; esac
    fi
done <"$PROC_TABLE"
EOF
chmod +x "$tmp/bin/pgrep" "$tmp/bin/ps"
fakepath="$tmp/bin:$PATH"

extract_fn() {
    awk -v n="$1" 'index($0, n "() {") == 1 {f=1; print; if ($0 ~ /\}$/ && $0 !~ /\{$/) exit; next} f{print} f && /^\}$/{exit}' "$2"
}
: >"$tmp/fns.sh"
for fn in live_pids ancestor_pids descendant_pids is_interactive stop_pid_tree describe_pid stop_live_sessions; do
    extract_fn "$fn" "$repo_root/scripts/dotupgrade.sh" >>"$tmp/fns.sh"
    grep -q "^$fn() {" "$tmp/fns.sh" || fail "$fn() not found in scripts/dotupgrade.sh"
done

# sh_stop <table> <ancestors> <interactive:0|1> <answers> [env] -> "count|stopped pids"
sh_stop() {
    local table="$1" ancestors="$2" interactive="$3" answers="$4" noprompt="${5:-}"
    printf '%s\n' "$table" >"$tmp/table"
    : >"$tmp/stopped"
    (
        export PROC_TABLE="$tmp/table" PATH="$fakepath"
        [ -z "$noprompt" ] || export DOTUPGRADE_NO_PROMPT=1
        eval "$(cat "$tmp/fns.sh")"
        ancestor_pids() { for a in $ancestors; do echo "$a"; done; }
        is_interactive() { [ "$interactive" = 1 ]; }
        stop_pid_tree() { echo "$1" >>"$tmp/stopped"; }
        count="$(printf '%s' "$answers" | stop_live_sessions opencode claude codex agy serena 2>/dev/null)"
        echo "$count|$(tr '\n' ' ' <"$tmp/stopped" | sed 's/ $//')"
    )
}
two='claude 200 /home/u/.local/bin/claude
serena 300 /home/u/.local/bin/serena start-mcp-server'
daemon='codex 100 /home/u/.codex/packages/app-server-daemon/releases/local-abc/bin/codex app-server'

[ "$(sh_stop "$two" "" 1 $'y\n')" = "2|200 300" ] || fail "sh: y must stop every blocker"
[ "$(sh_stop "$two" "" 1 $'n\n')" = "0|" ] || fail "sh: n must stop nothing"
[ "$(sh_stop "$two" "" 1 $'\n')" = "0|" ] || fail "sh: the default (Enter) must stop nothing"
[ "$(sh_stop "$two" "" 1 $'garbage\n')" = "0|" ] || fail "sh: an unknown answer must stop nothing"
[ "$(sh_stop "$two" "" 1 $'s\nn\ny\n')" = "1|300" ] || fail "sh: s must ask per process (n then y -> only the second)"
[ "$(sh_stop "$two" "" 0 $'y\n')" = "0|" ] || fail "sh: a non-terminal must never stop anything, even with a y on stdin"
[ "$(sh_stop "$two" "" 1 $'y\n' noprompt)" = "0|" ] || fail "sh: DOTUPGRADE_NO_PROMPT=1 must stop nothing"
[ "$(sh_stop "$two" "200" 1 $'y\n')" = "1|300" ] || fail "sh: an ancestor (the invoking agent) must never be offered"
[ "$(sh_stop "$two" "200 300" 1 $'y\n')" = "0|" ] || fail "sh: only ancestors left means no stop"
[ "$(sh_stop "$daemon" "" 1 $'y\n')" = "0|" ] || fail "sh: Codex's app-server daemon is not a session and must not be offered"
[ "$(sh_stop "" "" 1 $'y\n')" = "0|" ] || fail "sh: nothing running means nothing stopped"
pass

# the real ancestor walk always includes the shell asking
ancestors_out="$(PATH="$fakepath" PROC_TABLE="$tmp/table" bash -c "$(cat "$tmp/fns.sh"); ancestor_pids")"
printf '%s\n' "$ancestors_out" | grep -Fxq "$$" || printf '%s\n' "$ancestors_out" | grep -Eq '^[0-9]+$' || fail "sh: ancestor_pids printed no pid"

# the wiring: dotupgrade.sh offers the stop before it scans for blockers
grep -Fq 'stop_live_sessions opencode claude codex agy serena' "$repo_root/scripts/dotupgrade.sh" || fail "dotupgrade.sh does not call stop_live_sessions"
awk '/stop_live_sessions opencode claude codex agy serena/{a=NR} /^live codex/{b=NR} END{exit !(a && b && a<b)}' "$repo_root/scripts/dotupgrade.sh" || fail "dotupgrade.sh must offer the stop BEFORE the live-session scan"
grep -Fq 'Invoke-LiveSessionStop' "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1 does not call Invoke-LiveSessionStop"
awk '/Invoke-LiveSessionStop/{a=NR} /Test-LiveProcess @\(.codex.\)/{b=NR} END{exit !(a && b && a<b)}' "$repo_root/scripts/dotupgrade.ps1" || fail "dotupgrade.ps1 must offer the stop BEFORE the live-session scan"

# --- PowerShell twin -------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:table = @()
$script:answers = [System.Collections.Queue]::new()
$script:stopped = @()
$script:interactive = $true
$script:prompts = 0
function Get-Process {
    param([Parameter(Position = 0)][string[]]$Name)
    foreach ($n in $Name) { $script:table | Where-Object { $_.ProcessName -eq $n } }
}
function Test-InteractiveConsole { return $script:interactive }
function Read-Host { param($Prompt) $script:prompts++; return [string]$script:answers.Dequeue() }
function Stop-AgentProcess { param($Process) $script:stopped += $Process.Id; return $true }
function P($name, $id, $path) { [pscustomobject]@{ ProcessName = $name; Id = $id; Path = $path; StartTime = [datetime]'2026-10-04 10:00' } }
function Case($label, $rows, [string[]]$answers, [int[]]$exclude = @(), [bool]$tty = $true) {
    $script:table = @($rows); $script:stopped = @(); $script:prompts = 0
    $script:interactive = $tty
    $script:answers = [System.Collections.Queue]::new(); foreach ($a in $answers) { $script:answers.Enqueue($a) }
    $result = @(Invoke-LiveSessionStop -Name @('opencode', 'claude', 'codex', 'agy', 'serena') -ExcludeId $exclude)
    Write-Output ("$label=" + $result.Count + '|' + ($script:stopped -join ',') + "|prompts=" + $script:prompts)
}
$code   = P 'claude' 200 'C:\Users\u\.local\bin\claude.exe'
$serena = P 'serena' 300 'C:\Users\u\.local\bin\serena.exe'
$daemon = P 'codex' 100 'C:\Users\u\.codex\packages\app-server-daemon\releases\local-abc\bin\codex.exe'
$two = @($code, $serena)
Case 'all' $two @('y')
Case 'no' $two @('n')
Case 'default' $two @('')
Case 'garbage' $two @('maybe')
Case 'each' $two @('s', 'n', 'y')
Case 'notty' $two @('y') @() $false
Case 'ancestor' $two @('y') @(200)
Case 'only-ancestors' $two @('y') @(200, 300)
Case 'daemon' @($daemon) @('y')
Case 'nothing' @() @('y')
$env:DOTUPGRADE_NO_PROMPT = '1'
Case 'noprompt-env' $two @('y')
Remove-Item Env:\DOTUPGRADE_NO_PROMPT
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'all=2|200,300|prompts=1'
    expect 'no=0||prompts=1'
    expect 'default=0||prompts=1'
    expect 'garbage=0||prompts=1'
    expect 'each=1|300|prompts=3'
    expect 'notty=0||prompts=0'
    expect 'ancestor=1|300|prompts=1'
    expect 'only-ancestors=0||prompts=0'
    expect 'daemon=0||prompts=0'
    expect 'nothing=0||prompts=0'
    expect 'noprompt-env=0||prompts=0'
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
