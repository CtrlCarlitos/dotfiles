#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # the sourced/extracted code consumes these
set -euo pipefail

# `dot upgrade` defers codex and graft while "an agent session is live", because npm -g
# deletes and recreates the package directories a running session resolves from. It
# matched PROCESS NAMES only, so two things that are not sessions kept deferring them:
#   - Codex's shared app-server daemon (`codex app-server daemon`), which runs its OWN
#     copy under ~/.codex/packages/app-server-daemon/releases/<id>/ - not the npm-global
#     CLI that the upgrade replaces;
#   - Claude Desktop (an Electron app: ~10 `claude.exe` processes under AnthropicClaude\),
#     which is not Claude Code.
# A process whose path cannot be read (an elevated process seen from a normal shell) still
# counts: when in doubt, defer. Both twins are EXECUTED with fake process tables:
#   scripts/dotupgrade.sh   live()            (pgrep + ps)
#   scripts/lib/ps-common.ps1  Test-LiveProcess / Get-LiveAgentProcess (Get-Process)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- shell twin ------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat >"$tmp/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
# pgrep -x NAME: print matching pids from the fake table "name pid args...", exit 1 when none
[ "$1" = -x ] || exit 2
found=1
while read -r name pid _; do
    if [ "$name" = "$2" ]; then echo "$pid"; found=0; fi
done <"$PROC_TABLE"
exit "$found"
EOF
cat >"$tmp/bin/ps" <<'EOF'
#!/usr/bin/env bash
# ps -o args= -p PID
pid="${@: -1}"
while read -r name p args; do
    if [ "$p" = "$pid" ]; then printf '%s\n' "$args"; fi
done <"$PROC_TABLE"
EOF
chmod +x "$tmp/bin/pgrep" "$tmp/bin/ps"

awk '/^live\(\) \{/{f=1; print; if ($0 ~ /\}$/) exit; next} f{print} f && /^\}$/{exit}' "$repo_root/scripts/dotupgrade.sh" >"$tmp/live.sh"
[ -s "$tmp/live.sh" ] || fail "live() not found in scripts/dotupgrade.sh"

sh_live() { # $1 = process table contents, rest = names; prints yes/no
    local table="$1"; shift
    printf '%s\n' "$table" >"$tmp/table"
    (
        export PROC_TABLE="$tmp/table" PATH="$tmp/bin:$PATH"
        eval "$(cat "$tmp/live.sh")"
        if live "$@"; then echo yes; else echo no; fi
    )
}
daemon='codex 100 /home/u/.codex/packages/app-server-daemon/releases/local-abc/bin/codex app-server --listen unix://'
cli='codex 101 /usr/lib/node_modules/@openai/codex/vendor/x86_64/codex/codex'
[ "$(sh_live "$daemon" codex)" = no ] || fail "sh: Codex's app-server daemon is not a session; it must not defer codex"
[ "$(sh_live "$cli" codex)" = yes ] || fail "sh: a Codex CLI process is a live session"
[ "$(sh_live "$daemon
$cli" codex)" = yes ] || fail "sh: the CLI counts even beside the daemon"
[ "$(sh_live "claude 200 /home/u/.local/bin/claude" claude)" = yes ] || fail "sh: claude keeps counting"
[ "$(sh_live "$daemon" opencode claude codex agy)" = no ] || fail "sh: the daemon alone must not defer graft either"
[ "$(sh_live "" codex claude)" = no ] || fail "sh: nothing running means nothing live"

# --- PowerShell twin -------------------------------------------------------------------------
if command -v pwsh >/dev/null 2>&1; then
    cat >"$tmp/harness.ps1" <<'PSEOF'
param([string]$Lib)
Set-StrictMode -Version Latest
. $Lib
$script:table = @()
function Get-Process {
    param([Parameter(Position = 0)][string[]]$Name)
    foreach ($n in $Name) { $script:table | Where-Object { $_.ProcessName -eq $n } }
}
function P($name, $path) { [pscustomobject]@{ ProcessName = $name; Name = $name; Path = $path } }
function Case($label, $rows, [string[]]$names) {
    $script:table = @($rows)
    Write-Output ("$label=" + (Test-LiveProcess $names))
}
$daemon = P 'codex' 'C:\Users\u\.codex\packages\app-server-daemon\releases\local-abc\bin\codex.exe'
$cli    = P 'codex' 'C:\Users\u\AppData\Roaming\npm-global\node_modules\@openai\codex\vendor\codex.exe'
$desktop = P 'claude' 'C:\Users\u\AppData\Local\AnthropicClaude\app-2.19675.0\claude.exe'
$code    = P 'claude' 'C:\Users\u\.local\bin\claude.exe'
$blind   = P 'codex' $null
Case 'daemon-only' @($daemon) @('codex')
Case 'cli' @($cli) @('codex')
Case 'daemon-and-cli' @($daemon, $cli) @('codex')
Case 'desktop-only' @($desktop) @('claude')
Case 'desktop-ten-processes' @(1..10 | ForEach-Object { $desktop }) @('opencode', 'claude', 'codex', 'agy')
Case 'claude-code' @($code) @('claude')
Case 'desktop-and-code' @($desktop, $code) @('claude')
Case 'unreadable-path' @($blind) @('codex')
Case 'nothing' @() @('codex', 'claude')
$script:table = @($daemon, $desktop, $code)
Write-Output ('names=' + ((Get-LiveAgentProcess @('opencode', 'claude', 'codex', 'agy', 'serena') | ForEach-Object { $_.ProcessName } | Select-Object -Unique | Sort-Object) -join ','))
PSEOF
    out="$(pwsh -NoProfile -File "$(winpath "$tmp/harness.ps1")" -Lib "$(winpath "$repo_root/scripts/lib/ps-common.ps1")" 2>&1 | tr -d '\r')"
    expect() { printf '%s\n' "$out" | grep -Fxq "$1" || fail "PowerShell: expected '$1' (got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300))"; }
    expect 'daemon-only=False'
    expect 'cli=True'
    expect 'daemon-and-cli=True'
    expect 'desktop-only=False'
    expect 'desktop-ten-processes=False'
    expect 'claude-code=True'
    expect 'desktop-and-code=True'
    expect 'unreadable-path=True'
    expect 'nothing=False'
    expect 'names=claude'
else
    printf 'SKIP (PowerShell twin only): pwsh not installed\n'
fi

finish
