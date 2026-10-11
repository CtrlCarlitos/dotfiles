#!/usr/bin/env bash
set -euo pipefail

# mcp_add_quiet <agent label> <server> <retry-hint> <cmd...> (scripts/lib/agent-skills.sh): an
# agent CLI's `mcp add`, quiet on success. The 2026-10-11 WSL `dot up` printed the CLIs' own
# lines raw - "Added stdio MCP server maestro with command: maestro mcp to user config" and
# "File modified: /home/.../.claude.json" (Claude Code), "Added global MCP server 'maestro'."
# (Codex) - while OpenCode's registration says "Registered/updated MCP in opencode (maestro)".
# The contract, EXECUTED against a fake CLI:
#   - success: one dotfiles line, "Registered MCP in <label> (<server>)"; the CLI's output is
#     not shown
#   - failure: the CLI's output first (stderr), then the warn naming the retry hint; return 0
#     (never aborts a `set -e` run)
#   - the command runs under net_timeout_tty (`claude mcp add` touches the controlling
#     terminal; plain `timeout` stops it dead on WSL - the #355 hang), argv passed through
#   - the installer's four registrations (maestro and agent-device, for Claude Code and Codex)
#     go through it, with the run_onchange re-entry command as the hint
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"
tmpl="$repo_root/run_onchange_install_packages.sh.tmpl"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/claude" <<'EOF2'
#!/bin/sh
printf '%s\n' "$*" >>"${CLI_LOG:?}"
echo "Added stdio MCP server maestro with command: maestro mcp to user config"
echo "File modified: /home/u/.claude.json"
[ "${CLI_MODE:-ok}" = fail ] && { echo "Error: could not reach the server" >&2; exit 1; }
exit 0
EOF2
chmod +x "$tmp/bin/claude"

run() { # [env...] -> stdout and stderr, separated, plus rc
    PATH="$tmp/bin:/usr/bin:/bin" CLI_LOG="$tmp/cli.log" \
        bash -c 'set -euo pipefail; . "$1"; shift; rc=0; mcp_add_quiet "$@" >"$OUT" 2>"$ERR" || rc=$?; echo "rc=$rc"' \
        _ "$lib" "$@"
}
hint='chezmoi state delete-bucket --bucket=scriptState && dot up'

# A. success: one line, the CLI's chatter kept off the terminal, argv passed through, rc 0
: >"$tmp/cli.log"
got="$(OUT="$tmp/out" ERR="$tmp/err" run 'Claude Code' maestro "$hint" claude mcp add -s user maestro -- maestro mcp)"
[ "$got" = "rc=0" ] || fail "success: must return 0 (got $got)"
grep -Fq 'Registered MCP in Claude Code (maestro)' "$tmp/out" || fail "success: must print the dotfiles line (stdout: $(/bin/cat "$tmp/out"))"
if grep -Fq 'Added stdio MCP server' "$tmp/out" "$tmp/err"; then fail "success: the CLI's own output must not reach the terminal"; else pass; fi
if grep -Fq 'File modified' "$tmp/out" "$tmp/err"; then fail "success: the CLI's own output must not reach the terminal"; else pass; fi
[ ! -s "$tmp/err" ] || fail "success: nothing on stderr (got: $(/bin/cat "$tmp/err"))"
grep -Fxq 'mcp add -s user maestro -- maestro mcp' "$tmp/cli.log" || fail "the argv must pass through unchanged (cli saw: $(/bin/cat "$tmp/cli.log"))"

# B. failure: the CLI's output shown, then the warn with the hint; still rc 0
: >"$tmp/cli.log"
got="$(CLI_MODE=fail OUT="$tmp/out" ERR="$tmp/err" run 'Claude Code' maestro "$hint" claude mcp add -s user maestro -- maestro mcp)"
[ "$got" = "rc=0" ] || fail "failure: must still return 0 (got $got)"
grep -Fq 'could not reach the server' "$tmp/err" || fail "failure: the CLI's output must be shown (stderr: $(/bin/cat "$tmp/err"))"
grep -Fq "maestro MCP registration for Claude Code failed - re-run: $hint" "$tmp/err" || fail "failure: the warn must name the server, the agent and the hint (stderr: $(/bin/cat "$tmp/err"))"
if grep -Fq 'Registered MCP' "$tmp/out"; then fail "failure: must not claim a registration"; else pass; fi

# C. under net_timeout_tty: the function body, not a grep of the whole lib
body="$(sed -n '/^mcp_add_quiet() {$/,/^}$/p' "$lib")"
[ -n "$body" ] || fail "mcp_add_quiet() not found in agent-skills.sh"
case "$body" in *net_timeout_tty*) pass ;; *) fail "mcp_add_quiet must run the CLI under net_timeout_tty (WSL tty-stop hang)" ;; esac

# D. wiring: the four installer registrations use it, keep their argv literal, and pass the
#    re-entry command; no bare net_timeout_tty mcp add remains
for argv in 'claude mcp add -s user maestro -- maestro mcp' 'claude mcp add -s user agent-device -- agent-device mcp' \
            'codex mcp add maestro -- maestro mcp' 'codex mcp add agent-device -- agent-device mcp'; do
    grep -Eq "mcp_add_quiet '[^']+' [a-z-]+ '$hint' $argv\$" "$tmpl" || fail "installer: $argv must go through mcp_add_quiet with the re-entry hint"
done
forbid "$tmpl" 'net_timeout_tty 60 claude mcp add'
forbid "$tmpl" 'net_timeout_tty 60 codex mcp add'

finish
