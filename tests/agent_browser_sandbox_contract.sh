#!/usr/bin/env bash
set -euo pipefail

# agent_browser_sandbox_workaround (scripts/lib/agent-skills.sh), EXECUTED.
#
# Ubuntu 23.10+ restricts unprivileged user namespaces via AppArmor by
# default, so Chrome's own sandboxed launch refuses to start at all ("No
# usable sandbox!") before it ever writes DevToolsActivePort - confirmed live
# via `agent-browser doctor --json`'s own "launch.launch" check on a plain
# Ubuntu 26.04 VM (issue #431 Run 4/Run 5). agent-browser documents its own
# escape hatch for exactly this case: --args "--no-sandbox", read from
# ~/.agent-browser/config.json. The contract:
#   1. unrestricted (proc file reads 0, or is missing) - config untouched;
#   2. restricted, no config yet - config.json created with args=--no-sandbox;
#   3. restricted, existing config with other keys - args added, nothing else
#      touched;
#   4. restricted, existing config already has an `args` value - never
#      overwritten, even though the restriction stays unworked-around;
#   5. restricted, no jq on PATH - warns, does not crash, writes nothing.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run() { # $1 = proc file content ("" = missing), $2 = HOME, extra args = env assignments
    local content="$1" home="$2"; shift 2
    local procfile="$tmp/apparmor_proc"
    rm -f "$procfile"
    [ -n "$content" ] && printf '%s' "$content" >"$procfile"
    env "$@" HOME="$home" AGENT_BROWSER_APPARMOR_PROC="$procfile" \
        bash -c '. "$1"; agent_browser_sandbox_workaround' _ "$repo_root/scripts/lib/agent-skills.sh"
}

# 1a. Unrestricted (reads 0): config untouched (not even created).
h1="$tmp/home1"; mkdir -p "$h1"
run 0 "$h1"
[ -e "$h1/.agent-browser/config.json" ] && fail "unrestricted (0): config.json must not be created" || pass

# 1b. Proc file missing entirely (older kernel/distro): same as unrestricted.
h1b="$tmp/home1b"; mkdir -p "$h1b"
run "" "$h1b"
[ -e "$h1b/.agent-browser/config.json" ] && fail "missing proc file: config.json must not be created" || pass

# 2. Restricted, no existing config: created with exactly {"args":"--no-sandbox"}.
h2="$tmp/home2"; mkdir -p "$h2"
run 1 "$h2"
cfg2="$h2/.agent-browser/config.json"
[ -f "$cfg2" ] || fail "restricted: config.json was not created"
[ "$(jq -r '.args' "$cfg2")" = "--no-sandbox" ] || fail "restricted: args not set to --no-sandbox (got: $(cat "$cfg2"))"
[ "$(jq -r 'keys | length' "$cfg2")" = 1 ] || fail "restricted, fresh config: unexpected extra keys (got: $(cat "$cfg2"))"

# 3. Restricted, existing config with other keys: args added, other keys untouched.
h3="$tmp/home3"; mkdir -p "$h3/.agent-browser"
cfg3="$h3/.agent-browser/config.json"
printf '%s\n' '{"headed": true}' >"$cfg3"
run 1 "$h3"
[ "$(jq -r '.args' "$cfg3")" = "--no-sandbox" ] || fail "existing config: args not merged in (got: $(cat "$cfg3"))"
[ "$(jq -r '.headed' "$cfg3")" = "true" ] || fail "existing config: unrelated key 'headed' was lost (got: $(cat "$cfg3"))"

# 4. Restricted, existing config already sets args: never overwritten, even to a
#    value that does not include --no-sandbox (the user's own choice wins).
h4="$tmp/home4"; mkdir -p "$h4/.agent-browser"
cfg4="$h4/.agent-browser/config.json"
printf '%s\n' '{"args": "--disable-gpu"}' >"$cfg4"
before4="$(cat "$cfg4")"
run 1 "$h4"
after4="$(cat "$cfg4")"
[ "$before4" = "$after4" ] || fail "existing args: must never be overwritten (before: $before4 | after: $after4)"

# 5. Restricted, no jq on PATH: warns, does not crash, writes nothing.
h5="$tmp/home5"; mkdir -p "$h5"
procfile5="$tmp/apparmor_proc5"; printf 1 >"$procfile5"
emptybin="$tmp/emptybin"; mkdir -p "$emptybin"
ln -s "$(command -v bash)" "$emptybin/bash"
ln -s "$(command -v cat)" "$emptybin/cat"
out5="$(PATH="$emptybin" HOME="$h5" AGENT_BROWSER_APPARMOR_PROC="$procfile5" \
    bash -c '. "$1"; agent_browser_sandbox_workaround' _ "$repo_root/scripts/lib/agent-skills.sh" 2>&1)" || fail "no jq: must not crash (got: $out5)"
case "$out5" in *'jq unavailable'*) ;; *) fail "no jq: must warn (got: $out5)" ;; esac
[ -e "$h5/.agent-browser/config.json" ] && fail "no jq: must not write a config it never validated" || pass

finish
