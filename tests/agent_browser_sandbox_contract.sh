#!/usr/bin/env bash
set -euo pipefail

# agent_browser_sandbox_workaround (scripts/lib/agent-skills.sh), EXECUTED.
#
# Ubuntu 23.10+ restricts unprivileged user namespaces via AppArmor by
# default, so Chrome's own sandboxed launch refuses to start at all ("No
# usable sandbox!") - confirmed live on a plain Ubuntu 26.04 VM (issue #431
# Run 4/Run 5). The fix keeps Chrome's sandbox: an AppArmor profile allowing
# `userns` for agent-browser's Chrome, the rule Ubuntu ships for Google
# Chrome. agent-browser's --args "--no-sandbox" (which turns the sandbox off)
# is never written: where no profile loads it is the user's explicit choice,
# and whenever the config carries it, every run says so. The contract:
#   1. unrestricted (proc file reads 0, or is missing) - nothing touched;
#   2. restricted, no profile possible, no config - nothing written; a warning
#      says agent-browser cannot launch Chrome and how to opt in;
#   3. ...existing config with other keys - untouched, same warning;
#   4. ...existing config with other args - never overwritten;
#   5. ...no jq or grep on PATH - warns, does not crash, writes nothing;
#   9. profile loadable - loaded (parser -r), then written; no config created;
#  10. profile loadable, config holds exactly the --no-sandbox this repo wrote
#      - that key removed, the rest kept; a user's own different args kept;
#  11. profile already installed with the same text - the parser never runs;
#  12. the parser refuses it - no profile written, no config written;
#  14. --no-sandbox in the config (opted in, a user's own args, or what an
#      older run wrote) - warned on every run, profile or not, never removed
#      unless it is exactly the value this repo wrote and the profile loaded;
#  15. a browser still running with --no-sandbox after the profile loads -
#      named, with the command that restarts it.
#  13. the real profile text parses with the real apparmor_parser, where
#      this host has one.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

# tests/lib.sh keeps every test off the real sudo and /etc/apparmor.d: a suite run once loaded this
# profile into the operator's kernel through superpowers_refresh_contract.sh (#431, 2026-10-26).
[ -n "${AGENT_BROWSER_APPARMOR_DIR:-}" ] && [ ! -e "$AGENT_BROWSER_APPARMOR_DIR" ] &&
    [ "$(cat "${AGENT_BROWSER_APPARMOR_PROC:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}" 2>/dev/null)" != 1 ] &&
    pass || fail "tests/lib.sh must point AGENT_BROWSER_APPARMOR_DIR/PROC away from the host's AppArmor"

command -v jq >/dev/null 2>&1 || skip 'jq not installed'

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run() { # $1 = proc file content ("" = missing), $2 = HOME, extra args = env assignments
    local content="$1" home="$2"; shift 2
    local procfile="$tmp/apparmor_proc"
    rm -f "$procfile"
    [ -n "$content" ] && printf '%s' "$content" >"$procfile"
    # No profile can be installed unless a case says so: the real /etc/apparmor.d is never touched.
    env AGENT_BROWSER_APPARMOR_DIR="$tmp/no-apparmor" "$@" HOME="$home" AGENT_BROWSER_APPARMOR_PROC="$procfile" \
        bash -c '. "$1"; agent_browser_sandbox_workaround ""' _ "$repo_root/scripts/lib/agent-skills.sh" 2>&1
}

# 1a. Unrestricted (reads 0): config untouched (not even created).
h1="$tmp/home1"; mkdir -p "$h1"
run 0 "$h1" >/dev/null
[ -e "$h1/.agent-browser/config.json" ] && fail "unrestricted (0): config.json must not be created" || pass

# 1b. Proc file missing entirely (older kernel/distro): same as unrestricted.
h1b="$tmp/home1b"; mkdir -p "$h1b"
run "" "$h1b" >/dev/null
[ -e "$h1b/.agent-browser/config.json" ] && fail "missing proc file: config.json must not be created" || pass

# 2. Restricted, no profile possible, no config: nothing written (the sandbox is never turned off
#    on the user's behalf), and the warning says why it cannot launch and how to opt in.
h2="$tmp/home2"; mkdir -p "$h2"
out2="$(run 1 "$h2")"
[ -e "$h2/.agent-browser/config.json" ] && fail "no profile: --no-sandbox must be opt-in, yet a config was written ($(cat "$h2/.agent-browser/config.json"))"
case "$out2" in *'cannot launch'*'"args": "--no-sandbox"'*'yourself'*) pass ;; *) fail "no profile: must say it cannot launch and how to opt in (got: $out2)" ;; esac

# 3. Restricted, no profile possible, existing config with other keys: untouched, same warning.
h3="$tmp/home3"; mkdir -p "$h3/.agent-browser"
cfg3="$h3/.agent-browser/config.json"
printf '%s\n' '{"headed": true}' >"$cfg3"
out3="$(run 1 "$h3")"
[ "$(jq -c . "$cfg3")" = '{"headed":true}' ] || fail "no profile, existing config: must stay untouched (got: $(cat "$cfg3"))"
case "$out3" in *'cannot launch'*) pass ;; *) fail "no profile, existing config: must warn (got: $out3)" ;; esac

# 4. Restricted, existing config already sets args: never overwritten, even to a
#    value that does not include --no-sandbox (the user's own choice wins).
h4="$tmp/home4"; mkdir -p "$h4/.agent-browser"
cfg4="$h4/.agent-browser/config.json"
printf '%s\n' '{"args": "--disable-gpu"}' >"$cfg4"
before4="$(cat "$cfg4")"
run 1 "$h4" >/dev/null
after4="$(cat "$cfg4")"
[ "$before4" = "$after4" ] || fail "existing args: must never be overwritten (before: $before4 | after: $after4)"

# 5. Restricted, no jq or grep on PATH: warns, does not crash, writes nothing.
h5="$tmp/home5"; mkdir -p "$h5"
procfile5="$tmp/apparmor_proc5"; printf 1 >"$procfile5"
emptybin="$tmp/emptybin"; mkdir -p "$emptybin"
ln -s "$(command -v bash)" "$emptybin/bash"
ln -s "$(command -v cat)" "$emptybin/cat"
out5="$(PATH="$emptybin" HOME="$h5" AGENT_BROWSER_APPARMOR_PROC="$procfile5" AGENT_BROWSER_APPARMOR_DIR="$tmp/no-apparmor" \
    bash -c '. "$1"; agent_browser_sandbox_workaround' _ "$repo_root/scripts/lib/agent-skills.sh" 2>&1)" || fail "no jq: must not crash (got: $out5)"
case "$out5" in *'cannot launch'*) ;; *) fail "no jq: must still warn (got: $out5)" ;; esac
[ -e "$h5/.agent-browser/config.json" ] && fail "no jq: must not write a config" || pass

# agent_browser_doctor: doctor's live launch probe ignores config.json's args (agent-browser
# 0.39.2, issue #431 Run 8), so under the workaround it must run --quick and say so; anywhere
# else the full launch test stays.
#   6. restricted + config passes --no-sandbox - --quick, skip line printed;
#   7. restricted + the user's own args without it - full doctor;
#   8. unrestricted + --no-sandbox in config - full doctor.
ab="$tmp/agent-browser"
cat >"$ab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"${AB_ARGS:?}"
printf '%s\n' '{"summary":{"pass":11,"warn":0,"fail":0},"checks":[]}'
EOF
chmod +x "$ab"
doctor() { # $1 = proc content, $2 = config.json content; prints doctor's output
    local home="$tmp/dhome" procfile="$tmp/apparmor_doctor"
    rm -rf "$home"; mkdir -p "$home/.agent-browser"
    printf '%s' "$1" >"$procfile"
    printf '%s\n' "$2" >"$home/.agent-browser/config.json"
    HOME="$home" AGENT_BROWSER_APPARMOR_PROC="$procfile" AB_ARGS="$tmp/ab.args" \
        bash -c '. "$1"; agent_browser_doctor "$2"' _ "$repo_root/scripts/lib/agent-skills.sh" "$ab" 2>&1
}

out6="$(doctor 1 '{"args": "--no-sandbox"}')" || fail "restricted + --no-sandbox: doctor must succeed (got: $out6)"
grep -qx 'doctor --json --quick' "$tmp/ab.args" || fail "restricted + --no-sandbox: doctor must run --quick (args: $(cat "$tmp/ab.args"))"
case "$out6" in *'skipped: doctor'*'launch test'*) pass ;; *) fail "restricted + --no-sandbox: the skipped launch test must be said (got: $out6)" ;; esac

doctor 1 '{"args": "--disable-gpu"}' >/dev/null
grep -qx 'doctor --json' "$tmp/ab.args" && pass || fail "restricted + other args: the full launch test must run (args: $(cat "$tmp/ab.args"))"

out8="$(doctor 0 '{"args": "--no-sandbox"}')"
grep -qx 'doctor --json' "$tmp/ab.args" || fail "unrestricted: the full launch test must run (args: $(cat "$tmp/ab.args"))"
case "$out8" in *skipped*) fail "unrestricted: nothing was skipped, so nothing may say so (got: $out8)" ;; *) pass ;; esac

# The profile route. A stub parser records its arguments and fails on demand; `install` is the
# real one, writing into a temp dir that stands in for /etc/apparmor.d.
parser="$tmp/apparmor_parser"
cat >"$parser" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${PARSER_LOG:?}"
[ -z "${PARSER_FAIL:-}" ]
EOF
chmod +x "$parser"
profile_run() { # $1 = HOME; extra args = env assignments
    local home="$1"; shift
    run 1 "$home" AGENT_BROWSER_APPARMOR_DIR="$tmp/aa" AGENT_BROWSER_APPARMOR_PARSER="$parser" \
        PARSER_LOG="$tmp/parser.log" "$@"
}
want_profile="$(bash -c '. "$1"; agent_browser_apparmor_profile' _ "$repo_root/scripts/lib/agent-skills.sh")"
case "$want_profile" in *'agent-browser/browsers/chrome-'*'userns,'*) ;; *) fail "profile: must allow userns for agent-browser's Chrome (got: $want_profile)" ;; esac

# 9. Loadable: loaded with -r, then written; no --no-sandbox config.
mkdir -p "$tmp/aa"; rm -f "$tmp/parser.log"
h9="$tmp/home9"; mkdir -p "$h9"
out9="$(profile_run "$h9")"
grep -q '^-r ' "$tmp/parser.log" || fail "profile: the parser must load it with -r (log: $(cat "$tmp/parser.log" 2>/dev/null))"
[ "$(cat "$tmp/aa/agent-browser-chrome" 2>/dev/null)" = "$want_profile" ] || fail "profile: not written to the AppArmor dir"
[ -e "$h9/.agent-browser/config.json" ] && fail "profile: Chrome keeps its sandbox, so no --no-sandbox config may be written"
case "$out9" in *'keeps its sandbox'*) pass ;; *) fail "profile: the install must be said (got: $out9)" ;; esac

# 10. The --no-sandbox this repo wrote earlier is removed once the profile is in place; other
#     keys stay, and a user's own different args are never touched.
h10="$tmp/home10"; mkdir -p "$h10/.agent-browser"
printf '%s\n' '{"args": "--no-sandbox", "headed": true}' >"$h10/.agent-browser/config.json"
profile_run "$h10" >/dev/null
[ "$(jq -c . "$h10/.agent-browser/config.json")" = '{"headed":true}' ] && pass ||
    fail "migration: only the args key may go (got: $(cat "$h10/.agent-browser/config.json"))"
h10b="$tmp/home10b"; mkdir -p "$h10b/.agent-browser"
printf '%s\n' '{"args": "--disable-gpu --no-sandbox"}' >"$h10b/.agent-browser/config.json"
profile_run "$h10b" >/dev/null
[ "$(jq -r .args "$h10b/.agent-browser/config.json")" = '--disable-gpu --no-sandbox' ] && pass ||
    fail "migration: a user's own args must stay (got: $(cat "$h10b/.agent-browser/config.json"))"

# 11. Already installed with the same text: no parser call (no sudo prompt on every run).
rm -f "$tmp/parser.log"
h11="$tmp/home11"; mkdir -p "$h11"
out11="$(profile_run "$h11")"
[ -e "$tmp/parser.log" ] && fail "installed: the parser must not run again (log: $(cat "$tmp/parser.log"))"
[ -z "$out11" ] && pass || fail "installed: nothing to say (got: $out11)"

# 12. The parser refuses it (a container, a refused sudo): no profile written, no config written.
rm -rf "$tmp/aa"; mkdir -p "$tmp/aa"
h12="$tmp/home12"; mkdir -p "$h12"
out12="$(profile_run "$h12" PARSER_FAIL=1)"
[ -e "$tmp/aa/agent-browser-chrome" ] && fail "refused: a profile that never loaded must not be written"
[ -e "$h12/.agent-browser/config.json" ] && fail "refused: --no-sandbox must be opt-in, yet a config was written"
case "$out12" in *'cannot launch'*) pass ;; *) fail "refused: must warn (got: $out12)" ;; esac

# 14. --no-sandbox in the config is said on every run, never silently kept.
#  a. Opted in where no profile loads: kept, and warned (not the "cannot launch" one).
h14="$tmp/home14"; mkdir -p "$h14/.agent-browser"
printf '%s\n' '{"args": "--no-sandbox"}' >"$h14/.agent-browser/config.json"
out14="$(run 1 "$h14")"
[ "$(jq -r .args "$h14/.agent-browser/config.json")" = '--no-sandbox' ] || fail "opted in: the user's choice must stay"
case "$out14" in *'cannot launch'*) fail "opted in: Chrome can launch, so do not say it cannot (got: $out14)" ;; *'passes --no-sandbox'*'exploits it'*) pass ;; *) fail "opted in: must warn on every run (got: $out14)" ;; esac
#  b. A user's own args with it, profile installed: kept, and warned.
rm -rf "$tmp/aa"; mkdir -p "$tmp/aa"
h14b="$tmp/home14b"; mkdir -p "$h14b/.agent-browser"
printf '%s\n' '{"args": "--disable-gpu --no-sandbox"}' >"$h14b/.agent-browser/config.json"
out14b="$(profile_run "$h14b")"
case "$out14b" in *'passes --no-sandbox'*) pass ;; *) fail "own args with --no-sandbox: must warn even with the profile (got: $out14b)" ;; esac
#  c. Unrestricted kernel: still warned.
h14c="$tmp/home14c"; mkdir -p "$h14c/.agent-browser"
printf '%s\n' '{"args": "--no-sandbox"}' >"$h14c/.agent-browser/config.json"
case "$(run 0 "$h14c")" in *'passes --no-sandbox'*) pass ;; *) fail "unrestricted: --no-sandbox in the config must still be said" ;; esac

# 15. A browser started before the profile keeps --no-sandbox until it is closed: named, with the
#     command. A stand-in process carries the agent-browser path in its command line.
h15="$tmp/home15"; mkdir -p "$h15"
if command -v pgrep >/dev/null 2>&1; then
    bash -c 'exec -a "$1" sleep 30' _ "$h15/.agent-browser/browsers/chrome-1/chrome --no-sandbox" &
    stale=$!
    sleep 0.5
    out15="$(profile_run "$h15")"
    kill "$stale" 2>/dev/null || true
    case "$out15" in *'agent-browser close --all'*) pass ;; *) fail "stale browser: must name the restart command (got: $out15)" ;; esac
    out15b="$(profile_run "$h15")"
    case "$out15b" in *'close --all'*) fail "no stale browser: nothing to restart (got: $out15b)" ;; *) pass ;; esac
fi

# 13. The real text parses (no kernel load, no root) wherever this host has the parser.
if [ -x /usr/sbin/apparmor_parser ] && [ -d /etc/apparmor.d/abi ]; then
    printf '%s\n' "$want_profile" >"$tmp/real-profile"
    /usr/sbin/apparmor_parser -Q -K -I /etc/apparmor.d "$tmp/real-profile" && pass ||
        fail "profile: apparmor_parser rejects the profile text"
fi

finish
