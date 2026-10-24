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

# The function, extracted verbatim.
fn="$tmp/apt-resume-stopped.sh"
awk '/^apt_resume_stopped\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$lib" >"$fn"
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

finish
