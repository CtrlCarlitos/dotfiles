#!/usr/bin/env bash
set -euo pipefail

# Every `dot up` on Linux/WSL printed the `skills` CLI's banner, summary box and security table
# eight times (about 280 lines) while the Windows installer printed one "installed" line per
# skill; `dot upgrade` printed the Claude Code installer's banner and "next steps" block just to
# say a version. Both are shown now only when the call fails (skills: or DOT_SKILLS_VERBOSE=1).
#   scripts/lib/agent-skills.sh   skills_cli      (every `skills add` goes through it)
#   scripts/update_ai_tools.sh/.ps1               Claude Code installer output captured
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

lib="$repo_root/scripts/lib/agent-skills.sh"
run() { # run <env...> -- <cmd...>: skills_cli with the lib sourced; prints "stdout|stderr|rc"
    local out err rc=0
    out="$(mktemp)"; err="$(mktemp)"
    (
        # shellcheck disable=SC1090
        . "$lib"
        skills_cli 30 "$@"
    ) >"$out" 2>"$err" || rc=$?
    printf '%s|%s|%s' "$(tr '\n' ' ' <"$out")" "$(tr '\n' ' ' <"$err")" "$rc"
    rm -f "$out" "$err"
}

# success: nothing at all
[ "$(run bash -c 'echo BANNER; echo BOX >&2; exit 0')" = "||0" ] || fail "a successful skills call must print nothing (got: $(run bash -c 'echo BANNER; echo BOX >&2; exit 0'))"
# failure: the whole output is shown, on stderr, and the status survives
res="$(run bash -c 'echo BANNER; echo BOX >&2; exit 3')"
case "$res" in *"BANNER"*"BOX"*"|3") ;; *) fail "a failing skills call must show its output and keep its status (got: $res)" ;; esac
# verbose: the output is not swallowed
res="$(DOT_SKILLS_VERBOSE=1 run bash -c 'echo BANNER; exit 0')"
case "$res" in "BANNER "*"|0") ;; *) fail "DOT_SKILLS_VERBOSE=1 must show the output (got: $res)" ;; esac
pass

# wiring: no `skills add` call is left outside skills_cli
if grep -E 'net_timeout [0-9]+ "\$\{SK\[@\]\}" add' "$lib" >/dev/null; then
    fail "a skills add call bypasses skills_cli (its output would flood dot up)"
fi
[ "$(grep -c 'skills_cli [0-9]* "${SK\[@\]}" add' "$lib")" -ge 8 ] || fail "expected all eight curated skills add calls to go through skills_cli"

# the Claude Code installer's output is captured, and shown only on failure (both twins)
grep -Fq 'bash "$cl_inst" >"$cl_out" 2>&1' "$repo_root/scripts/update_ai_tools.sh" || fail "update_ai_tools.sh must capture the Claude Code installer output"
grep -Fq '$claudeOut = @(& powershell -c' "$repo_root/scripts/update_ai_tools.ps1" || fail "update_ai_tools.ps1 must capture the Claude Code installer output"
pass

finish
