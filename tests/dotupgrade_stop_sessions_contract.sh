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
        case "$*" in *tty=*) echo "${FAKE_TTY:-}" ;; *comm=*) echo "$name" ;; *etime=*) echo "01:00" ;; *) printf '%s\n' "$args" ;; esac
    fi
done <"$PROC_TABLE"
EOF
chmod +x "$tmp/bin/pgrep" "$tmp/bin/ps"
fakepath="$tmp/bin:$PATH"

extract_fn() {
    awk -v n="$1" 'index($0, n "() {") == 1 {f=1; print; if ($0 ~ /\}$/ && $0 !~ /\{$/) exit; next} f{print} f && /^\}$/{exit}' "$2"
}
: >"$tmp/fns.sh"
for fn in live_pids ancestor_pids descendant_pids is_interactive stop_pid_tree agent_tty reset_agent_terminal describe_pid stop_live_sessions; do
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
        # dot_ask / dot_ask_hint (the timed prompt reader) live in timing.sh, which dotupgrade.sh sources
        . "$repo_root/scripts/lib/timing.sh"
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
# a stopped TUI agent's terminal gets its modes switched off (written to its tty), and only a real tty
mkdir -p "$tmp/dev"; : >"$tmp/dev/pts9"
FAKE_TTY=pts9 DOT_TTY_ROOT="$tmp/dev" sh_stop "$two" "" 1 $'y\n' >/dev/null
for code in '?1000l' '?1006l' '?2004l' '<99u' '?25h'; do
    grep -Fq "$code" "$tmp/dev/pts9" || fail "sh: a stopped agent's tty must get the reset ($code missing)"
done
: >"$tmp/dev/pts9"
FAKE_TTY='?' DOT_TTY_ROOT="$tmp/dev" sh_stop "$two" "" 1 $'y\n' >/dev/null
[ ! -s "$tmp/dev/pts9" ] || fail "sh: no tty ('?') must write nothing"
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
    param([Parameter(Position = 0)][string[]]$Name, [int]$Id)
    if ($Id) { return @($script:table | Where-Object { $_.Id -eq $Id }) }
    if (-not $Name) { return @($script:table) }
    foreach ($n in $Name) { $script:table | Where-Object { $_.ProcessName -eq $n } }
}
# command lines and parents (Get-OrphanAgentHelper, the OpenCode server label); services
$script:ptable = @()
function Get-ProcessTable { return @($script:ptable) }
$script:services = @{}
$script:serviceStops = @()
function Get-Service { param([string]$Name) if ($script:services.ContainsKey($Name)) { [pscustomobject]@{ Name = $Name; Status = $script:services[$Name] } } }
function Stop-Service { param([string]$Name, [switch]$Force) $script:serviceStops += $Name }
function Test-InteractiveConsole { return $script:interactive }
function Read-Host { param($Prompt) $script:prompts++; return [string]$script:answers.Dequeue() }
function Stop-AgentProcess { param($Process, [switch]$ResetTerminal) if ($ResetTerminal) { $script:resets++ }; $script:stopped += $Process.Id; return $true }
$script:resets = 0
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
Write-Output ('all-resets-terminal=' + $script:resets)
# Serena dies with Claude Code's tree: already gone when its turn comes - counted, not stopped again.
$exited = P 'serena' 301 'C:\Users\u\.local\bin\serena.exe'
$exited | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
$exited | Add-Member -MemberType NoteProperty -Name HasExited -Value $true
$script:resets = 0
Case 'exited' @($code, $exited) @('y')
Write-Output ('exited-resets=' + $script:resets)
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

# Desktop apps: offered as a whole, by install folder - several share a CLI's process name.
$deskA = P 'claude' 501 'C:\Users\u\AppData\Local\AnthropicClaude\app-2.26454.0\claude.exe'
$deskB = P 'claude' 502 'C:\Users\u\AppData\Local\AnthropicClaude\app-2.26454.0\claude.exe'
$codexApp = P 'ChatGPT' 601 'C:\Program Files\WindowsApps\OpenAI.Codex_26.930.4958.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe'
$codexAppCli = P 'codex' 602 'C:\Program Files\WindowsApps\OpenAI.Codex_26.930.4958.0_x64__2p2nqsd0c76g0\app\resources\codex.exe'
$ocDesk = P 'OpenCode' 701 'C:\Users\u\AppData\Local\Programs\@opencode-aidesktop\OpenCode.exe'
$ocCli = P 'opencode' 702 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links\opencode.exe'
$agDesk = P 'Antigravity' 801 'C:\Users\u\AppData\Local\Programs\antigravity\Antigravity.exe'
$noPath = P 'Antigravity' 802 $null
# Claude Code + Claude Desktop: "y" stops both, so no claude.exe is left to hold Claude Desktop
$script:resets = 0
Case 'desk-all' @($code, $deskA, $deskB) @('y')
Write-Output ('desk-resets-only-the-session=' + $script:resets)
Case 'desk-only' @($deskA, $deskB, $agDesk) @('y')
# choose each: one question per session, one per app (not per process)
Case 'desk-each' @($code, $deskA, $deskB) @('s', 'n', 'y')
Case 'desk-keep' @($deskA, $deskB) @('n')
Case 'desk-ancestor' @($deskA, $deskB) @('y') @(501)
Case 'desk-nopath' @($noPath) @('y')
# grouping, and desktop processes never count as CLI sessions (they would defer CLI upgrades)
$script:table = @($code, $deskA, $codexApp, $codexAppCli, $ocDesk, $ocCli, $agDesk)
Write-Output ('desk-apps=' + ((@(Get-AgentDesktopApp) | ForEach-Object { "$($_.Label):$(@($_.Processes).Count)" }) -join ','))
Write-Output ('desk-sessions=' + ((@(Get-LiveAgentProcess -Name @('opencode', 'claude', 'codex', 'agy', 'serena')) | ForEach-Object { $_.Id }) -join ','))
$script:table = @($codexApp, $codexAppCli, $ocDesk)
Write-Output ('desk-defers-nothing=' + (Test-LiveProcess @('codex', 'opencode', 'claude')))

# Every process in an app's folder belongs to it - Antigravity's language server too.
$agLs = P 'language_server' 803 'C:\Users\u\AppData\Local\Programs\antigravity\resources\bin\language_server.exe'
$script:table = @($agDesk, $agLs)
Write-Output ('desk-helpers=' + ((@(Get-AgentDesktopApp) | ForEach-Object { "$($_.Label):$((@($_.Processes) | ForEach-Object { $_.Id }) -join '+')" }) -join ','))
# The Codex Store app's sandbox service is stopped with the app; listed even with no window open.
$script:services = @{ 'CodexSandboxService.OpenAI.Codex' = 'Running' }
$script:serviceStops = @()
Case 'desk-service' @() @('y')
Write-Output ('desk-service-stopped=' + ($script:serviceStops -join ','))
$script:services = @{ 'CodexSandboxService.OpenAI.Codex' = 'Stopped' }
Case 'desk-service-idle' @() @('y')
$script:services = @{}

# Background work an ENDED session left: offered; the same work under a live session is not.
# not R: that is a built-in alias (Invoke-History), and aliases win over functions
function Row($id, $parent, $name, $cmd, $path = '') { [pscustomobject]@{ Id = $id; ParentId = $parent; Name = $name; Path = $path; CommandLine = $cmd } }
$bgShell = Row 900 4242 'cmd.exe' 'cmd.exe /d /s /c "pwsh -Command "$__claudeCodeScript = $env:CLAUDE_CODE_SHELL_LAUNCH""'
$bgChild = Row 901 900 'pwsh.exe' 'pwsh -Command "$__claudeCodeScript = $env:CLAUDE_CODE_SHELL_LAUNCH"'
$graftTop = Row 910 4343 'cmd.exe' 'cmd.exe /d /s /c "npx ^"-y^" ^"@nanonets/graft^" ^"mcp^""'
$graftNode = Row 911 910 'node.exe' 'node npx-cli.js -y @nanonets/graft mcp'
$liveClaude = Row 200 1 'claude.exe' 'claude' 'C:\Users\u\.local\bin\claude.exe'
$ownedShell = Row 920 200 'cmd.exe' 'cmd.exe /d /s /c "pwsh -Command "$__claudeCodeScript = $env:CLAUDE_CODE_SHELL_LAUNCH""'
$deskClaude = Row 501 1 'claude.exe' 'claude' 'C:\Users\u\AppData\Local\AnthropicClaude\app-2.26454.0\claude.exe'
$deskChild = Row 930 501 'cmd.exe' 'cmd.exe /c "pwsh -Command "$__claudeCodeScript = 1""'
$script:ptable = @($bgShell, $bgChild, $graftTop, $graftNode, $liveClaude, $ownedShell, $deskClaude, $deskChild)
Write-Output ('orphans=' + ((@(Get-OrphanAgentHelper) | ForEach-Object { "$($_.Kind)@$($_.Id)" }) -join ','))
$script:table = @((P 'cmd' 900 'C:\Windows\System32\cmd.exe'), (P 'cmd' 910 'C:\Windows\System32\cmd.exe'))
$script:stopped = @(); $script:prompts = 0
$script:answers = [System.Collections.Queue]::new(); $script:answers.Enqueue('y')
$result = @(Invoke-LiveSessionStop -Name @('opencode', 'claude', 'codex', 'agy', 'serena'))
Write-Output ('orphans-stopped=' + ($script:stopped -join ',') + '|prompts=' + $script:prompts)
$script:ptable = @()

# OpenCode's server is labelled as one (still a session: it defers OpenCode's upgrade).
$ocServe = P 'opencode' 950 'C:\Users\u\AppData\Local\Microsoft\WinGet\Links\opencode.exe'
$script:ptable = @(Row 950 1 'opencode.exe' 'opencode.exe serve --port 4096 --hostname 127.0.0.1')
$script:table = @($ocServe)
$script:answers = [System.Collections.Queue]::new(); $script:answers.Enqueue('n')
$label = (Invoke-LiveSessionStop -Name @('opencode') 6>&1 | Out-String)
Write-Output ('server-label=' + ($label -match 'OpenCode server \(opencode serve\) - opencode \(pid 950'))
$script:ptable = @()
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400))"; }
    expect 'all=2|200,300|prompts=1'
    # the terminal reset is for TUI agents (Claude Code), not for Serena (an MCP server)
    expect 'all-resets-terminal=1'
    expect 'exited=2|200|prompts=1'
    expect 'exited-resets=1'
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
    expect 'desk-all=3|200,501,502|prompts=1'
    expect 'desk-resets-only-the-session=1'
    expect 'desk-only=3|501,502,801|prompts=1'
    expect 'desk-each=2|501,502|prompts=3'
    expect 'desk-keep=0||prompts=1'
    expect 'desk-ancestor=1|502|prompts=1'
    expect 'desk-nopath=0||prompts=0'
    expect 'desk-apps=Claude Desktop:1,ChatGPT / Codex:2,Antigravity:1,OpenCode Desktop:1'
    expect 'desk-sessions=702,200'
    expect 'desk-defers-nothing=False'
    expect 'desk-helpers=Antigravity:801+803'
    expect 'desk-service=0||prompts=1'
    expect 'desk-service-stopped=CodexSandboxService.OpenAI.Codex'
    expect 'desk-service-idle=0||prompts=0'
    # top of each orphaned chain only; owned by a live session (or by Claude DESKTOP, not a session) differs
    expect 'orphans=Claude Code background task@900,graft MCP server@910,Claude Code background task@930'
    expect 'orphans-stopped=900,910|prompts=1'
    expect 'server-label=True'
    # A console agent ended by taskkill never switches off its TUI's terminal modes; they print as
    # stray characters. Stop-AgentProcess -ResetTerminal writes the switch-offs to its console
    # FIRST (and only then), and the sequence covers mouse, focus, paste, kitty keys, cursor.
    cat >"$tmp/reset.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:calls = @()
function Reset-AgentTerminal { param([int]$ProcessId) $script:calls += "reset:$ProcessId"; return $true }
function taskkill { $script:calls += 'taskkill'; $global:LASTEXITCODE = 0 }
$proc = [pscustomobject]@{ ProcessName = 'claude'; Id = 77 }
$proc | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { return $false }
$null = Stop-AgentProcess -Process $proc -ResetTerminal
Write-Output ('with=' + ($script:calls -join ','))
$script:calls = @()
$null = Stop-AgentProcess -Process $proc
Write-Output ('without=' + ($script:calls -join ','))
$seq = Get-TerminalResetSequence
foreach ($code in '?1000l', '?1006l', '?1004l', '?2004l', '<99u', '?25h') { Write-Output ("seq-$code=" + $seq.Contains($code)) }
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/reset.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '')"
    expect 'with=reset:77,taskkill'
    expect 'without=taskkill'
    for code in '?1000l' '?1006l' '?1004l' '?2004l' '<99u' '?25h'; do expect "seq-$code=True"; done
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
