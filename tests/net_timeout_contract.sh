#!/usr/bin/env bash
set -euo pipefail

# net_timeout / net_timeout_tty (scripts/lib/agent-skills.sh): the wall-clock guard
# around every network step. EXECUTED against real commands.
#
# A WSL `dot up` (2026-10-11) printed
#   /tmp/3833146279.install_packages.sh: line 161:  3657 Killed   "$bin" -k 10 "$secs" "$@"
#   agent-device MCP registration for Claude Code failed - continuing
# when a `claude mcp add` the kernel had stopped (SIGTTIN, #355) could not take SIGTERM and `-k 10` escalated to SIGKILL. coreutils
# `timeout` then kills its own process group (itself included), so bash reports the
# raw "Killed" line and the exit status is 137, not the 124 the helper documented
# ("Exit 124 = timed out") - a caller could not tell a hang from a crash. The
# contract: both exits read as a timeout (124), the helper says so in one line
# naming the command and the budget, the kernel's "Killed" notice never reaches
# the terminal, and a command that finishes keeps its own output and exit code.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"

command -v timeout >/dev/null 2>&1 || skip 'coreutils timeout not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# run <helper> <secs> <cmd...>: executes the helper from the library under set -e like the
# installer; prints "rc=<n>", stdout and stderr land in $tmp/out and $tmp/err.
run() {
    local rc=0
    NET_TIMEOUT_KILL_AFTER=1 bash -c 'set -euo pipefail; . "$1"; shift; "$@"' _ "$lib" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
    printf 'rc=%s' "$rc"
}

# 1. A child that ignores SIGTERM: escalated to SIGKILL, reported as a timeout.
got="$(run net_timeout 1 bash -c 'trap "" TERM; sleep 20')"
[ "$got" = rc=124 ] || fail "net_timeout: a SIGKILL-escalated timeout must exit 124 like a plain one (got $got)"
if grep -q 'Killed' "$tmp/err"; then fail "net_timeout: the kernel's 'Killed' notice must not reach the terminal (stderr: $(tr '\n' '|' <"$tmp/err"))"; else pass; fi
grep -Fq 'timed out after 1s' "$tmp/err" || fail "net_timeout: must say the command timed out and after how long (stderr: $(tr '\n' '|' <"$tmp/err"))"
grep -Fq 'bash' "$tmp/err" || fail "net_timeout: the timeout line must name the command (stderr: $(tr '\n' '|' <"$tmp/err"))"

# 2. A child that honours SIGTERM: the plain 124 path says the same thing.
got="$(run net_timeout 1 sleep 20)"
[ "$got" = rc=124 ] || fail "net_timeout: a plain timeout must exit 124 (got $got)"
grep -Fq 'sleep timed out after 1s' "$tmp/err" || fail "net_timeout: the plain timeout must be reported too (stderr: $(tr '\n' '|' <"$tmp/err"))"

# 3. A command that finishes keeps its stdout, its stderr and its exit code, with no
#    timeout line.
got="$(run net_timeout 10 bash -c 'echo out; echo err >&2; exit 3')"
[ "$got" = rc=3 ] || fail "net_timeout: a finished command's exit code must come through (got $got)"
[ "$(/bin/cat "$tmp/out")" = out ] || fail "net_timeout: stdout must pass through (got '$(/bin/cat "$tmp/out")')"
[ "$(/bin/cat "$tmp/err")" = err ] || fail "net_timeout: stderr must pass through untouched (got '$(/bin/cat "$tmp/err")')"
got="$(run net_timeout 10 true)"
[ "$got" = rc=0 ] || fail "net_timeout: a successful command must exit 0 (got $got)"
[ ! -s "$tmp/err" ] || fail "net_timeout: nothing on stderr for a command that finished (got '$(/bin/cat "$tmp/err")')"

# 4. stdin reaches the command (the installer feeds `y` answers through a pipe).
got="$(printf 'ping\n' | NET_TIMEOUT_KILL_AFTER=1 bash -c 'set -euo pipefail; . "$1"; net_timeout 10 head -n1' _ "$lib")"
[ "$got" = ping ] || fail "net_timeout: stdin must reach the command (got '$got')"

# 5. The tty variant maps the SIGKILL escalation the same way.
got="$(run net_timeout_tty 1 bash -c 'trap "" TERM; sleep 20')"
[ "$got" = rc=124 ] || fail "net_timeout_tty: a SIGKILL-escalated timeout must exit 124 (got $got)"
grep -Fq 'timed out after 1s' "$tmp/err" || fail "net_timeout_tty: must report the timeout (stderr: $(tr '\n' '|' <"$tmp/err"))"
if grep -q 'Killed' "$tmp/err"; then fail "net_timeout_tty: no raw 'Killed' line (stderr: $(tr '\n' '|' <"$tmp/err"))"; else pass; fi

finish
