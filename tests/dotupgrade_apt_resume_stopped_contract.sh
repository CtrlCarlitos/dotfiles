#!/usr/bin/env bash
set -euo pipefail

# apt_resume_stopped (scripts/lib/agent-skills.sh, used by scripts/dotupgrade.sh and the
# installer's Playwright install-deps), EXECUTED.
#
# sudo's own pty allocation (use_pty) races the new pty's foreground-process-group assignment
# against the exec of the privileged apt-get it runs: a descendant can lose that race and take
# one stray SIGTTIN before the group is installed, landing in `ps` state T. Nothing else in
# dotupgrade.sh ever notices or resumes a stopped grandchild - it is not an interactive shell, so
# there is no job-control loop watching for one - so without help it sits stopped forever.
# Confirmed live (issue #431 Run 7 follow-up): `sudo kill -CONT <pid>` by hand let the exact same
# transaction finish normally seconds later, proving the stop is a one-time race, not a real
# deadlock. apt_resume_stopped is that CONT, automated: a background loop that continues any
# apt/dpkg-named process it finds stopped.
#
# `pgrep -x` matches a process's /proc/pid/comm, never argv[0] (exec -a only changes the latter),
# so the fake "apt-get" here is a renamed bash process kept alive via its own `wait` on an
# untracked `sleep` child - the same technique
# tests/dotupgrade_docker_vscode_unix_contract.sh uses for its "dockerd" fake, for the same reason.
#
# Spawned under `setsid` (its own session, no controlling terminal at all): without it, the fake
# process is a background job of THIS test's own interactive-ish shell, and resuming it from the
# deliberate kill -STOP below immediately re-triggers the real job-control machinery this whole
# bug is about (SIGTTIN/SIGTTOU, since the test shell's foreground group is not its own) - caught
# live while writing this test: `kill -CONT` appeared to succeed but the process stayed in state T
# forever, because something in the resumed script's own job-control bookkeeping re-stopped it on
# the very next terminal touch. `setsid` removes the controlling terminal entirely, so there is
# nothing left to be background relative to, and a single deliberate STOP/CONT behaves as intended.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
lib="$repo_root/scripts/lib/agent-skills.sh"

case "${OSTYPE:-}" in msys* | cygwin* | win32) skip 'needs a Linux userland (/proc/self/comm, pgrep -x)' ;; esac
command -v pgrep >/dev/null 2>&1 || skip 'pgrep not installed'
command -v setsid >/dev/null 2>&1 || skip 'setsid not installed'

tmp="$(mktemp -d)"
cleanup() {
    [ -n "${watcher:-}" ] && kill "$watcher" 2>/dev/null
    [ -n "${fake_pid:-}" ] && kill -KILL "$fake_pid" 2>/dev/null
    [ -n "${child_pid:-}" ] && kill -KILL "$child_pid" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT

# The functions, extracted verbatim (the watcher and its ps listing).
fn="$tmp/apt-resume-stopped.sh"
for name in apt_resume_stopped _apt_watch_ps; do
    awk -v n="$name" '$0 ~ "^" n "\\(\\) \\{" {f=1} f {print} f && /^\}$/ {exit}' "$lib" >>"$fn"
done
grep -q '^_apt_watch_ps() {' "$fn" ||
    fail "agent-skills.sh: _apt_watch_ps() not found"
grep -q '^apt_resume_stopped() {' "$fn" ||
    fail "agent-skills.sh: apt_resume_stopped() not found (the watcher must be a function the test can run)"

harness="$tmp/harness.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    # sudo: a plain passthrough (dropping the watcher's -n) - the test owns the fake process, so
    # no real privilege is needed to CONT it; this isolates the watcher's own logic from sudo's
    # real behavior (covered live).
    printf '%s\n' 'sudo() { [ "$1" = -n ] && shift; "$@"; }'
    cat "$fn"
    printf '%s\n' 'apt_resume_stopped'
} >"$harness"
chmod +x "$harness"

# A fake "apt-get": a renamed bash process (comm, not argv0) kept alive via `wait` on an
# untracked sleep, under setsid - see the header note.
pidfile="$tmp/fake.pid"
setsid bash -c 'echo -n apt-get >/proc/self/comm 2>/dev/null || true; sleep 300 & echo $! >"$1"; wait' _ "$pidfile" </dev/null >/dev/null 2>&1 &
disown "$!" 2>/dev/null || true
# setsid's own process is not the renamed one (it execs bash itself, so no extra layer - but
# capture by name since $! here is setsid's immediate child, which IS the renamed bash on Linux).
fake_pid=$!
# give the rename and the untracked child a moment to land
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$pidfile" ] && break
    sleep 0.2
done
child_pid="$(cat "$pidfile" 2>/dev/null || true)"
[ -n "$child_pid" ] || fail "setup: the fake apt-get's untracked sleep child never recorded its pid"

comm="$(command ps -o comm= -p "$fake_pid" 2>/dev/null | tr -d ' ')"
[ "$comm" = apt-get ] || fail "setup: the fake process's comm is '$comm', not apt-get (rename failed?)"

kill -STOP "$fake_pid"
stat="$(command ps -o stat= -p "$fake_pid" 2>/dev/null | tr -d ' ')"
case "$stat" in T*) ;; *) fail "setup: the fake apt-get did not actually stop (stat: $stat)" ;; esac

# Run the watcher and confirm it continues the stopped fake within a few polling cycles.
watcher="$(bash "$harness")"
[ -n "$watcher" ] || fail "apt_resume_stopped did not print a watcher pid"

resumed=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    stat="$(command ps -o stat= -p "$fake_pid" 2>/dev/null | tr -d ' ')"
    case "$stat" in T*) ;; *) resumed=1; break ;; esac
    sleep 0.3
done
[ -n "$resumed" ] || fail "apt_resume_stopped never continued the stopped apt-get-named process (last stat: $stat)"
pass

kill "$watcher" 2>/dev/null
wait "$watcher" 2>/dev/null || true
watcher=""

# Run 10: install-deps' apt-get finished (End-Date written) and the chain above it - sudo ->
# npx -> node -> sh - still sat out the 300 s budget. A stopped process UNDER the calling script
# is continued whatever its name; one outside it, not apt-named, is left alone. The log records
# each resume and, after the snapshot delay, every process under the caller.
log="$tmp/watch.log"
harness2="$tmp/harness2.sh"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'sudo() { [ "$1" = -n ] && shift; "$@"; }'
    cat "$fn"
    # the "node": a child of this harness (the watcher's $$), renamed, under setsid as above
    printf '%s\n' 'setsid bash -c '"'"'echo -n node >/proc/self/comm 2>/dev/null || true; sleep 300 & wait'"'"' </dev/null >/dev/null 2>&1 &'
    printf '%s\n' 'echo $! >"$1"'
    printf '%s\n' 'apt_resume_stopped "$2" 1 >"$3"'
    printf '%s\n' 'sleep 30' # the caller stays alive while the test checks
} >"$harness2"
bash "$harness2" "$tmp/under.pid" "$log" "$tmp/watcher2.pid" </dev/null >/dev/null 2>&1 &
harness2_pid=$!
setsid bash -c 'echo -n node >/proc/self/comm 2>/dev/null || true; sleep 300 & wait' </dev/null >/dev/null 2>&1 &
outside_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -s "$tmp/under.pid" ] && [ -s "$tmp/watcher2.pid" ] && break
    sleep 0.2
done
under_pid="$(cat "$tmp/under.pid" 2>/dev/null || true)"
watcher="$(cat "$tmp/watcher2.pid" 2>/dev/null || true)"
[ -n "$under_pid" ] && [ -n "$watcher" ] || fail "setup: harness2 never recorded its node/watcher pids"
cleanup2() { kill -KILL "$under_pid" "$outside_pid" "$harness2_pid" 2>/dev/null; cleanup; }
trap cleanup2 EXIT
sleep 0.3 # let the renames land before the comm check
for p in "$under_pid" "$outside_pid"; do
    comm="$(command ps -o comm= -p "$p" 2>/dev/null | tr -d ' ')"
    [ "$comm" = node ] || fail "setup: pid $p's comm is '$comm', not node"
done
kill -STOP "$under_pid" "$outside_pid"

resumed=""
for _ in $(seq 1 20); do
    stat="$(command ps -o stat= -p "$under_pid" 2>/dev/null | tr -d ' ')"
    case "$stat" in T*) ;; *) resumed=1; break ;; esac
    sleep 0.3
done
[ -n "$resumed" ] ||
    fail "apt_resume_stopped never continued a stopped process under its caller that is not apt-named (last stat: $stat)"
pass

sleep 1 # several more polling cycles, and past the 1 s snapshot
stat="$(command ps -o stat= -p "$outside_pid" 2>/dev/null | tr -d ' ')"
case "$stat" in T*) pass ;; *) fail "apt_resume_stopped continued a non-apt process outside its caller (stat: $stat)" ;; esac

grep -q "resumed stopped: $under_pid .* node\$" "$log" ||
    fail "the watcher log has no 'resumed stopped' line for pid $under_pid: $(cat "$log")"
[ "$(grep -c 'resumed stopped:' "$log")" = 1 ] ||
    fail "the watcher log should name each resumed process once: $(cat "$log")"
grep -q "resumed stopped: $outside_pid " "$log" && fail "the watcher log names the outside process"
grep -q 'still running after 1s' "$log" || fail "the watcher log has no snapshot after 1 s: $(cat "$log")"
grep -qE "^$under_pid [0-9]+ .* node\$" "$log" || fail "the snapshot does not list the node under the caller: $(cat "$log")"
pass

finish
