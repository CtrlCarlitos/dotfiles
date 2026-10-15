#!/usr/bin/env bash
set -euo pipefail

# dot upgrade's apt sweep (apt_upgrade_run, scripts/dotupgrade.sh): dpkg's routine lines went to
# the console on every upgrade - "Preparing to unpack / Unpacking / Setting up / Processing
# triggers", 17 of them for four packages on WSL (2026-10-12) - after a line had already named
# what upgrades. Now:
#   1. quiet (default): apt's output is captured, one line says how many packages were set up;
#      apt runs non-interactively (DEBIAN_FRONTEND=noninteractive, confdef/confold) because a
#      prompt behind a captured stdout could neither be seen nor answered
#   2. a failed apt shows its whole output, says so, and the sweep continues (exit 0)
#   3. DOT_APT_VERBOSE=1 leaves everything on the terminal and adds none of the non-interactive flags
#   4. the current GitHub-release tools share one line (tool_current_collect ... tool_current_flush)
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
up_sh="$repo_root/scripts/dotupgrade.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# sudo: runs its command; env: the real one (sudo env X=Y apt-get ...) resolves apt-get on PATH
printf '#!/bin/sh\nexec "$@"\n' >"$tmp/bin/sudo"
# apt-get: logs argv and its environment's DEBIAN_FRONTEND/NEEDRESTART_MODE, prints dpkg's lines,
# exits $FAKE_APT_RC
cat >"$tmp/bin/apt-get" <<'STUB'
#!/bin/sh
printf 'apt-get %s [DEBIAN_FRONTEND=%s] [NEEDRESTART_MODE=%s]\n' "$*" "${DEBIAN_FRONTEND:-}" "${NEEDRESTART_MODE:-}" >>"${APT_LOG:?}"
printf '%s\n' '(Reading database ... 340961 files and directories currently installed.)' \
    'Preparing to unpack .../libx11-6_2%3a1.8.7-1ubuntu0.1_amd64.deb ...' 'Unpacking libx11-6:amd64 (2:1.8.7-1ubuntu0.1) over (2:1.8.7-1build1) ...' \
    'Setting up libx11-data (2:1.8.7-1ubuntu0.1) ...' 'Setting up libx11-6:amd64 (2:1.8.7-1ubuntu0.1) ...' 'Processing triggers for man-db (2.12.0-4build2) ...'
[ "${FAKE_APT_RC:-0}" = 0 ] || { echo 'E: Sub-process /usr/bin/dpkg returned an error code (1)' >&2; exit "$FAKE_APT_RC"; }
exit 0
STUB
chmod +x "$tmp/bin"/*

harness="$tmp/apt-fn.sh"
awk '/^apt_upgrade_run\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$up_sh" >"$harness"
grep -q '^apt_upgrade_run() {' "$harness" || fail "dotupgrade.sh: apt_upgrade_run() not found (the apt sweep must be a function the test can run)"
run() { # prints output and rc; env from the caller
    : >"$tmp/apt.log"
    # -u DEBIAN_FRONTEND: GitHub's runners export it as noninteractive themselves, which would make the
    # verbose case look non-interactive for a reason that is not the sweep's
    env -u DEBIAN_FRONTEND PATH="$tmp/bin:/usr/bin:/bin" APT_LOG="$tmp/apt.log" bash -c 'set -u; . "$1"; shift; rc=0; apt_upgrade_run "$@" || rc=$?; echo "rc=$rc"' _ "$harness" "$@" 2>&1
}

# 1. quiet: one line, dpkg's lines hidden, apt non-interactive
got="$(run -qq)"
case "$got" in *'  apt: 2 package(s) upgraded.'*rc=0*) pass ;; *) fail "quiet: one summary line expected (got: $got)" ;; esac
case "$got" in *Unpacking*|*'Setting up'*|*'Reading database'*) fail "quiet: dpkg's routine lines must not reach the console (got: $got)" ;; *) pass ;; esac
grep -Fq '[DEBIAN_FRONTEND=noninteractive]' "$tmp/apt.log" || fail "quiet: apt must run with DEBIAN_FRONTEND=noninteractive (log: $(cat "$tmp/apt.log"))"
grep -Fq '[NEEDRESTART_MODE=a]' "$tmp/apt.log" || fail "quiet: apt must run with NEEDRESTART_MODE=a (a captured run can't answer needrestart's own restart-services prompt; log: $(cat "$tmp/apt.log"))"
grep -Fq -- '-o Dpkg::Options::=--force-confold' "$tmp/apt.log" || fail "quiet: a changed conffile must keep the installed copy (log: $(cat "$tmp/apt.log"))"
grep -Fq -- '-qq -o Dpkg::Use-Pty=0' "$tmp/apt.log" || fail "quiet: the caller's flags and Dpkg::Use-Pty=0 must be passed (log: $(cat "$tmp/apt.log"))"
grep -Eq 'upgrade -y( |$)' "$tmp/apt.log" || fail "quiet: it must still be 'upgrade -y' (log: $(cat "$tmp/apt.log"))"

# 2. failure: whole output shown, said, sweep continues
got="$(FAKE_APT_RC=100 run -qq)"
case "$got" in *'Unpacking libx11-6'*'dpkg returned an error code'*'apt upgrade failed - continuing with the rest of the sweep.'*rc=0*) pass ;; *) fail "failure: apt's output and a continuing note expected (got: $got)" ;; esac

# 3. verbose: everything on the terminal, interactive apt
got="$(DOT_APT_VERBOSE=1 run)"
case "$got" in *'Unpacking libx11-6'*'Processing triggers'*rc=0*) pass ;; *) fail "verbose: dpkg's lines must stay on the terminal (got: $got)" ;; esac
case "$got" in *'package(s) upgraded.'*) fail "verbose: no summary line (got: $got)" ;; *) pass ;; esac
grep -Fq '[DEBIAN_FRONTEND=]' "$tmp/apt.log" || fail "verbose: apt stays interactive (log: $(cat "$tmp/apt.log"))"
grep -Fq '[NEEDRESTART_MODE=]' "$tmp/apt.log" || fail "verbose: needrestart stays interactive too, same as debconf (log: $(cat "$tmp/apt.log"))"
if grep -Fq 'force-confold' "$tmp/apt.log"; then fail "verbose: none of the non-interactive flags (log: $(cat "$tmp/apt.log"))"; else pass; fi

# 4. wiring: the sweep calls the function with the quiet flags; the current tools share one line
require "$up_sh" 'apt_upgrade_run "${apt_q[@]}"'
require "$up_sh" 'tool_current_collect'
require "$up_sh" "tool_current_flush 'GitHub-release tools'"

# 5. apt_sudo_prime: the sudo password prompt is its own timing section ("sudo password"), not
#    "system packages" - a WSL dot upgrade reported 53s of "system packages" with apt having
#    nothing at all to do (2026-10-12), almost all of it the operator typing the password. A
#    cached credential (sudo -n true succeeds) opens no extra section at all.
harness2="$tmp/prime-fn.sh"
awk '/^apt_sudo_prime\(\) \{/ {f=1} f {print} f && /^\}$/ {exit}' "$up_sh" >"$harness2"
grep -q '^apt_sudo_prime() {' "$harness2" || fail "dotupgrade.sh: apt_sudo_prime() not found (the apt sudo prompt must be a function the test can run)"
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/sh
if [ "$1" = -n ] && [ "$2" = true ]; then
    [ "${FAKE_SUDO_CACHED:-0}" = 1 ] && exit 0 || exit 1
fi
if [ "$1" = -v ]; then exit "${FAKE_SUDO_V_RC:-0}"; fi
exec "$@"
EOF
chmod +x "$tmp/bin/sudo"
prime_run() {
    env PATH="$tmp/bin:/usr/bin:/bin" bash -c '
        set -u
        . "'"$repo_root"'/scripts/lib/timing.sh"
        . "'"$harness2"'"
        dot_timing_mark "system packages"
        apt_sudo_prime
        dot_timing_mark "after"
        for i in "${!DOT_TIMING_NAMES[@]}"; do printf "%s\n" "${DOT_TIMING_NAMES[$i]}"; done
    '
}
out="$(FAKE_SUDO_CACHED=1 prime_run)"
[ "$out" = "system packages" ] || fail "apt_sudo_prime: a cached credential must open no extra timing section (got: $(printf '%s' "$out" | tr '\n' '|'))"
out="$(FAKE_SUDO_CACHED=0 prime_run)"
expected="$(printf 'system packages\nsudo password\nsystem packages')"
[ "$out" = "$expected" ] || fail "apt_sudo_prime: a real prompt must get its own 'sudo password' section, not count against system packages (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass
require "$up_sh" 'apt_sudo_prime'

finish
