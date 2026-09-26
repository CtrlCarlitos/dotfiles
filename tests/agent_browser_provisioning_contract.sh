#!/usr/bin/env bash
set -euo pipefail

# agent-browser provisioning contract, EXECUTED (#135's headline example).
#
# This test used to pin seven source lines verbatim, indentation included
# (grep -Fqx on 8-12 leading spaces): any re-indent or message edit failed it
# with behaviour unchanged, and a behavioural regression that kept the text
# passed. Now both installer twins are rendered, the agent-browser block is
# extracted and run against stubbed binaries, and the contract is asserted
# from what actually happened:
#
#   1. install goes through npm -g with --allow-scripts=agent-browser;
#   2. the CLI is located via `npm prefix -g` (never a hardcoded path);
#   3. when present, `install` (browser setup) and `doctor --json`
#      (verification) both run;
#   4. an install failure or a missing CLI degrades to a warning - the
#      browser setup never aborts the installer.

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

. "$repo_root/tests/lib.sh"

command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed (the Windows twin block needs it)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
prefix="$tmp/prefix"
mkdir -p "$bin" "$prefix/bin"
# Resolved BEFORE any PATH restriction below (the runner lives outside them).
PWSH_BIN="$(command -v pwsh)"

# --- Unix twin ----------------------------------------------------------------
sh_rendered="$tmp/installer.sh"
render_to "$sh_rendered" sh '{"agent_toolkit": true}'
[ -s "$sh_rendered" ] || fail "sh installer did not render"

# The block: from its info line through the closing `fi` of the
# installed/not-installed branch. Anchors are the info/warn literals the
# block itself prints; extraction validity is checked below (a reshaped
# source fails loudly here rather than silently testing nothing).
awk '
    /Installing agent-browser\.\.\./ {on = 1}
    on {print}
    on && /agent-browser command was not installed/ {getline; print; exit}
' "$sh_rendered" >"$tmp/block.sh"
grep -Fq 'net_timeout 300' "$tmp/block.sh" ||
    fail "sh block extraction lost the install step (source shape changed?)"
grep -Fq 'doctor --json' "$tmp/block.sh" ||
    fail "sh block extraction lost the verification step (source shape changed?)"
grep -Fq '[[ -x "$AGENT_BROWSER_BIN" ]]' "$tmp/block.sh" ||
    fail "sh block extraction lost the presence branch (source shape changed?)"

sh_run() { # $1 = outfile; env pre-set by caller
    local outfile="$1"
    HOME="$tmp/home" PATH="$bin:/usr/bin:/bin" NPM_BIN="$bin/npm" npm_sudo="" \
        NPM_LOG="$tmp/npm.log" NPM_FAIL="${NPM_FAIL:-0}" NPM_FAKE_PREFIX="$prefix" \
        AB_LOG="$tmp/ab.log" \
        timeout 60 bash "$tmp/harness.sh" >"$outfile" 2>&1
}

printf '#!/bin/sh\nexit 0\n' >"$bin/npm" # placeholder, replaced below
cat >"$bin/npm" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${NPM_LOG:?}"
if [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then
    printf '%s\n' "${NPM_FAKE_PREFIX:?}"
    exit 0
fi
[ "${NPM_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
chmod +x "$bin/npm"

make_ab_stub() {
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${AB_LOG:?}"\nexit 0\n' >"$prefix/bin/agent-browser"
    chmod +x "$prefix/bin/agent-browser"
}

{
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. "%s"\n' "$repo_root/scripts/lib/agent-skills.sh" # info/warn/net_timeout
    cat "$tmp/block.sh"
} >"$tmp/harness.sh"

# 1. Happy path: npm -g install with the allow-scripts list, CLI resolved via
#    `npm prefix -g`, then browser setup + verification.
: >"$tmp/npm.log"; : >"$tmp/ab.log"
make_ab_stub
out="$tmp/sh-ok.log"
sh_run "$out"
grep -Fq 'install -g --allow-scripts=agent-browser agent-browser' "$tmp/npm.log" ||
    fail "sh twin: install must go through npm -g with --allow-scripts=agent-browser"
grep -Fq 'prefix -g' "$tmp/npm.log" ||
    fail "sh twin: the CLI must be located via npm prefix -g"
grep -Fq 'install' "$tmp/ab.log" || fail "sh twin: agent-browser install (browser setup) did not run"
grep -Fq 'doctor --json' "$tmp/ab.log" ||
    fail "sh twin: agent-browser doctor --json verification did not run"
if [ "$(grep -c 'net_timeout' "$sh_rendered")" -ge 1 ]; then pass; else fail "sh installer lost net_timeout guards"; fi

# 2. Install failure: warning, no browser setup (the prefix lookup itself is
#    unconditional in the source - only the setup is guarded; with no CLI left
#    behind from an earlier install, the presence guard skips the setup).
rm -f "$prefix/bin/agent-browser"
: >"$tmp/npm.log"; : >"$tmp/ab.log"
NPM_FAIL=1 sh_run "$tmp/sh-npmfail.log"
grep -Fq 'agent-browser install failed or timed out - continuing' "$tmp/sh-npmfail.log" ||
    fail "sh twin: an install failure must warn-and-continue"
if [ -s "$tmp/ab.log" ]; then
    fail "sh twin: no browser setup after a failed install"
else
    pass
fi

# 3. CLI missing at the prefix: warn-and-skip the browser setup.
rm -f "$prefix/bin/agent-browser"
: >"$tmp/npm.log"; : >"$tmp/ab.log"
sh_run "$tmp/sh-nobin.log"
grep -Fq 'agent-browser command was not installed - skipping browser setup' "$tmp/sh-nobin.log" ||
    fail "sh twin: a missing CLI must be reported and skipped"
if [ -s "$tmp/ab.log" ]; then
    fail "sh twin: browser setup ran without the CLI"
else
    pass
fi

# --- Windows twin ---------------------------------------------------------------
ps1_rendered="$tmp/installer.ps1"
render_to "$ps1_rendered" ps1 '{"agent_toolkit": true}'
[ -s "$ps1_rendered" ] || fail "ps1 installer did not render"

ps1_start="$(grep -nF 'Installing agent-browser...' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$ps1_start" ] || fail "ps1 render: agent-browser block not found"
skip_line="$(grep -nF 'skipping browser setup' "$ps1_rendered" | head -1 | cut -d: -f1)"
[ -n "$skip_line" ] || fail "ps1 render: skip-warn anchor not found"
ps1_end=$((skip_line + 2))

fixture="$(mktemp)" && mv "$fixture" "$fixture.ps1" && fixture="$fixture.ps1"
cat >"$fixture" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$rendered, $start, $end, $mode = $args
$lines = [IO.File]::ReadAllLines($rendered)
function Slice([object[]]$All, [int]$From, [int]$To) { ($All[($From - 1)..($To - 1)] -join "`n") + "`n" }
$block = Slice $lines $start $end

function Fail([string]$m) { Write-Host "FAIL: $m"; exit 1 }

# Jobs would need a live PowerShell job infrastructure per call; the contract
# under test is the ACTIONS, so Invoke-WithTimeout runs them inline (and logs).
$script:Descriptions = @()
function Invoke-WithTimeout {
    param([string]$Description, [int]$Seconds, [scriptblock]$Action, [switch]$NoStream)
    $script:Descriptions += $Description
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
}

try {
    Invoke-Expression $block
} catch {
    Fail "ps1 block threw: $_"
}
# Windows hosts get Windows-path spellings of the log files (batch stubs and
# pwsh's own path resolution need them); CI Linux uses the POSIX ones.
$npmLog = if ($env:NPM_LOG_WIN) { $env:NPM_LOG_WIN } else { $env:NPM_LOG }
$abLog = if ($env:AB_LOG_WIN) { $env:AB_LOG_WIN } else { $env:AB_LOG }
switch ($mode) {
    'ok' {
        $npm = Get-Content $npmLog
        if (-not ($npm -match 'install -g --allow-scripts=agent-browser agent-browser')) { Fail "ps1: npm argv wrong: $npm" }
        if (-not ($npm -match 'prefix -g')) { Fail 'ps1: CLI must be located via npm prefix -g' }
        $ab = Get-Content $abLog
        if (-not ($ab -match 'install')) { Fail 'ps1: agent-browser install did not run' }
        if (-not ($ab -match 'doctor --json')) { Fail 'ps1: agent-browser doctor --json did not run' }
        if ($env:AGENT_BROWSER) { Fail 'ps1: AGENT_BROWSER env leaked' }
    }
    'npmfail' {
        if (Get-Content $npmLog | Select-String 'prefix -g') { Fail 'ps1: failed install must not look up the CLI' }
        if (Test-Path $abLog) { Fail 'ps1: browser setup ran after a failed install' }
    }
    'nobin' {
        if (Test-Path $abLog) { Fail 'ps1: browser setup ran without the CLI' }
    }
    default { Fail "unknown mode: $mode" }
}
POWERSHELL

ps1_run() { # $1 = mode, $2 = outfile; NPM_FAIL via env
    local mode="$1" outfile="$2"
    local wintmp
    wintmp="$(cygpath -w "$tmp" 2>/dev/null || printf '%s' "$tmp")"
    PATH="$bin:/usr/bin:/bin" NPM_LOG="$tmp/npm.log" NPM_FAIL="${NPM_FAIL:-0}" \
        NPM_FAKE_PREFIX="$(cygpath -w "$prefix" 2>/dev/null || printf '%s' "$prefix")" \
        AB_LOG="$tmp/ab.log" AB_LOG_WIN="$wintmp\\ab.log" \
        NPM_LOG_WIN="$wintmp\\npm.log" \
        "$PWSH_BIN" -NoProfile -File "$fixture" "$ps1_rendered" "$ps1_start" "$ps1_end" "$mode" \
        >"$outfile" 2>&1
}

# npm stub, platform-appropriate: .cmd for a Windows host, POSIX script for
# CI Linux (pwsh resolves `npm` through PATH; extension rules differ).
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${NPM_LOG:?}"\nif [ "${1:-}" = prefix ] && [ "${2:-}" = -g ]; then printf "%%s\\n" "${NPM_FAKE_PREFIX:?}"; exit 0; fi\n[ "${NPM_FAIL:-0}" = 1 ] && exit 1\nexit 0\n' >"$bin/npm"
chmod +x "$bin/npm"
cat >"$bin/npm.cmd" <<EOF
@echo off
echo %* >> "%NPM_LOG_WIN%"
if /i "%1"=="prefix" (
    echo %NPM_FAKE_PREFIX%
    exit /b 0
)
if "%NPM_FAIL%"=="1" exit /b 1
exit /b 0
EOF
# agent-browser stub where npm prefix -g points: batch content on a Windows
# host (cmd.exe executes it), shebang content on CI Linux (pwsh there runs
# the file by content, not extension) - both append argv to the same log.
case "${OSTYPE:-}" in
    msys*|cygwin*)
        # %AB_LOG_WIN% stays a live cmd env reference (printf renders %% as %).
        printf '@echo off\necho %%*>> "%%AB_LOG_WIN%%"\nexit /b 0\n' >"$prefix/agent-browser.cmd"
        ;;
    *)
        printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${AB_LOG:?}"\nexit 0\n' >"$prefix/agent-browser.cmd"
        chmod +x "$prefix/agent-browser.cmd"
        ;;
esac

: >"$tmp/npm.log"; : >"$tmp/ab.log"
ps1_run ok "$tmp/ps1-ok.log" || fail "ps1 twin: happy-path block failed: $(cat "$tmp/ps1-ok.log")"
if grep -q 'FAIL' "$tmp/ps1-ok.log"; then fail "ps1 twin happy path: $(cat "$tmp/ps1-ok.log")"; else pass; fi

: >"$tmp/npm.log"; rm -f "$tmp/ab.log"
NPM_FAIL=1 ps1_run npmfail "$tmp/ps1-npmfail.log" ||
    fail "ps1 twin: npm-failure scenario failed: $(cat "$tmp/ps1-npmfail.log")"
if grep -q 'FAIL' "$tmp/ps1-npmfail.log"; then fail "ps1 twin npmfail: $(cat "$tmp/ps1-npmfail.log")"; else pass; fi
grep -Fq 'install failed (exit code 1) - continuing' "$tmp/ps1-npmfail.log" ||
    fail "ps1 twin: an install failure must warn-and-continue"

rm -f "$prefix/agent-browser.cmd"
: >"$tmp/npm.log"; rm -f "$tmp/ab.log"
ps1_run nobin "$tmp/ps1-nobin.log" ||
    fail "ps1 twin: missing-CLI scenario failed: $(cat "$tmp/ps1-nobin.log")"
if grep -q 'FAIL' "$tmp/ps1-nobin.log"; then fail "ps1 twin nobin: $(cat "$tmp/ps1-nobin.log")"; else pass; fi
grep -Fq 'agent-browser command was not installed - skipping browser setup' "$tmp/ps1-nobin.log" ||
    fail "ps1 twin: a missing CLI must be reported and skipped"

rm -f "$fixture"

finish
