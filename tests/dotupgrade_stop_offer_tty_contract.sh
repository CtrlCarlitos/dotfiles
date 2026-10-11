#!/usr/bin/env bash
set -euo pipefail

# The live-session stop offer must be reachable from a terminal. A WSL `dot upgrade --yes`
# (2026-10-11) never offered to stop the live claude and serena sessions, while the Windows twin
# stopped its sessions: dotupgrade.sh calls `stop_live_sessions ... >/dev/null` (the count of
# stopped sessions travels on stdout), and is_interactive tested `[ -t 1 ]` - inside that call
# stdout is /dev/null, so the offer was unreachable on every Linux/WSL run, --yes or not.
# tests/dotupgrade_stop_sessions_contract.sh stubs is_interactive, so it never saw this.
# The prompt is written to stderr; the terminal check must look at the descriptors the prompt
# actually uses (stdin for the answer, stderr for the question). EXECUTED under a real pty.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
du="$repo_root/scripts/dotupgrade.sh"

command -v script >/dev/null 2>&1 || skip 'script (util-linux) not installed - no pty for this test'
script --version 2>&1 | grep -q util-linux || skip 'script is not util-linux (needs -e and -c)'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fn="$(awk '/^is_interactive\(\)/ {print; exit}' "$du")"
[ -n "$fn" ] || { fail "dotupgrade.sh: is_interactive() must be defined on one line"; finish; }

# probe: the real call shape - stdout to /dev/null, the verdict on stderr (the pty).
{
    printf '%s\n' "$fn"
    printf '%s\n' 'if { is_interactive; } >/dev/null; then echo VERDICT=yes >&2; else echo VERDICT=no >&2; fi'
} >"$tmp/probe.sh"
out="$(script -qec "bash $tmp/probe.sh" /dev/null 2>&1 | tr -d '\r')"
case "$out" in
    *VERDICT=yes*) pass ;;
    *) fail "a terminal with the count redirected to /dev/null must still count as interactive (got: $out)" ;;
esac

# a non-terminal stdin (a cron, a pipe) must never count as interactive, even on a pty
out="$(script -qec "bash $tmp/probe.sh </dev/null" /dev/null 2>&1 | tr -d '\r')"
case "$out" in
    *VERDICT=no*) pass ;;
    *) fail "stdin from /dev/null must not count as interactive (got: $out)" ;;
esac

# the call site still sends the count to stdout - the shape that hid the bug - so the check
# above is the one that keeps the offer reachable
require "$du" 'stop_live_sessions opencode claude codex agy serena >/dev/null'

finish
