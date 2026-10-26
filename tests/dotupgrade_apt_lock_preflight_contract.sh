#!/usr/bin/env bash
set -euo pipefail

# dot upgrade's Linux apt arm calls apt_lock_preflight before touching apt at all - EXECUTED.
#
# scripts/dotupgrade.sh sources scripts/lib/agent-skills.sh (where apt_lock_preflight lives) but,
# until this contract, never actually called it: a leftover apt/dpkg holder (stuck under a
# debconf dialog, or - net_timeout_tty's own documented trade-off - an orphan left stopped by an
# earlier timed-out step) made the whole system-packages section fail silently, with no
# explanation and no recovery command. Confirmed live: a cancelled `dot upgrade` left exactly
# that chain behind (sudo -> apt-get -> a stopped apt-get child) and the next `dot upgrade` ran
# straight into it (issue #431).
#
# Contract:
#   1. apt_lock_preflight says locked -> the section is skipped with an explanation; apt-get is
#      never invoked at all (no update, no upgrade);
#   2. apt_lock_preflight says clear -> the section proceeds exactly as before, and apt-get
#      update carries the same bounded lock wait the installer uses.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"
du="$repo_root/scripts/dotupgrade.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# The whole `case "$NET_CHOICE:$(uname -s)" in ... esac` (the Linux arm needs the enclosing case
# to be syntactically complete on its own), extracted verbatim (same awk-block-extraction
# technique tests/dotupgrade_apt_quiet_contract.sh uses for apt_upgrade_run) - a reshaped source
# fails loudly here rather than silently testing nothing.
block="$tmp/apt-case.sh"
awk '
    /^case "\$NET_CHOICE:\$\(uname -s\)" in$/ {on = 1}
    on {print}
    on && /^esac$/ {exit}
' "$du" >"$block"
grep -Fq 'apt_lock_preflight' "$block" ||
    fail "extraction lost the Linux arm (source shape changed? dotupgrade.sh's case block moved)"
grep -Fq 'apt_upgrade_run "${apt_q[@]}"' "$block" ||
    fail "extraction lost the upgrade call (source shape changed?)"

# sudo: runs its command (apt-get resolves on the stub PATH); real `env` passes DEBIAN_FRONTEND
# through to it, same pattern as the quiet-apt contract.
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"${CALLS:?}"
exec "$@"
EOF
cat >"$tmp/bin/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >>"${CALLS:?}"
case "$1 ${2:-}" in
    *update*) exit 0 ;;
    "-s upgrade") exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/sudo" "$tmp/bin/apt-get"

# run FAKE_PREFLIGHT_RC: sources the real library (for the real functions the arm calls besides
# apt_lock_preflight), overrides apt_lock_preflight with a fake, stubs everything downstream of a
# successful preflight as a no-op (covered by their own contracts), and runs the extracted arm
# with NET_CHOICE=continue, uname faked to Linux.
run() {
    : >"$tmp/calls"
    env PATH="$tmp/bin:/usr/bin:/bin" CALLS="$tmp/calls" FAKE_PREFLIGHT_RC="${1:-0}" bash -c '
        set -u
        . "'"$repo_root"'/scripts/lib/agent-skills.sh"
        apt_lock_preflight() { echo "apt_lock_preflight called" >&2; return "${FAKE_PREFLIGHT_RC:-0}"; }
        apt_sudo_prime() { :; }
        dock_docker_running() { return 1; }
        apt_upgrade_run() { echo "apt_upgrade_run called" >&2; }
        tool_current_collect() { :; }
        github_tool_sync() { :; }
        release_tool_pins_upgrade() { :; }
        tool_current_flush() { :; }
        dot_sudo_keepalive() { :; }
        uname() { echo Linux; }
        NET_CHOICE=continue
        . "'"$block"'"
    ' 2>&1
}

# 1. Locked: the section is skipped, explained, and apt-get is never touched at all.
out="$(run 1)"
case "$out" in *'Skipping system packages'*) ;; *) fail "locked: must print the skip explanation (got: $out)" ;; esac
if [ -s "$tmp/calls" ]; then
    fail "locked: apt-get must never be invoked once the preflight says locked (calls: $(cat "$tmp/calls"))"
else
    pass
fi
case "$out" in *'apt_upgrade_run called'*) fail "locked: the upgrade step must not run either" ;; *) pass ;; esac

# 2. Clear: proceeds as before, apt-get update carries the bounded lock wait.
out="$(run 0)"
case "$out" in *'apt_lock_preflight called'*) pass ;; *) fail "clear: apt_lock_preflight must still be consulted (got: $out)" ;; esac
case "$out" in *'apt_upgrade_run called'*) pass ;; *) fail "clear: the upgrade step must still run (got: $out)" ;; esac
grep -Fq -- '-o Dpkg::Lock::Timeout=600' "$tmp/calls" ||
    fail "clear: apt-get update must carry the same bounded lock wait as the installer (calls: $(cat "$tmp/calls"))"
grep -Fq 'apt-get update' "$tmp/calls" || grep -Eq 'apt-get.*update' "$tmp/calls" ||
    fail "clear: apt-get update must still run (calls: $(cat "$tmp/calls"))"

finish
