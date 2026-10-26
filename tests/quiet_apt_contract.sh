#!/usr/bin/env bash
set -euo pipefail

# A WSL `dot up` printed ~100 lines of apt chatter across ~13 install groups ("git is already the
# newest version", "Reading package lists...", the update's Hit:/Get: list) while the Windows run
# was quiet. quiet_apt_enable routes `apt|apt-get install|update` to `apt-get -qq` (silent unless
# something fails; `apt -qq` still prints "already the newest version") and leaves everything else
# alone. It is done with shell functions, not a pipe, so the ~40 pinned call sites do not change and
# prompts, sudo's password request and exit codes behave as before. EXECUTED against fake
# sudo / apt / apt-get binaries that record how they were called (the sudo wrapper logs a line, and
# so does the tool it runs, so every call shows up as a `sudo ...` line followed by a tool line).
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"$CALLS"
exec "$@"
EOF
for t in apt apt-get apt-cache systemctl; do
    cat >"$tmp/bin/$t" <<EOF
#!/bin/sh
echo "$t \$*" >>"\$CALLS"
exit "\${FAKE_EXIT:-0}"
EOF
done
chmod +x "$tmp/bin/"*

# run <body>: runs the body after the library is loaded, under set -euo pipefail like the
# installer, and prints the recorded calls (one per line)
run() {
    : >"$tmp/calls"
    {
        printf '%s\n' 'set -euo pipefail' ". \"$repo_root/scripts/lib/agent-skills.sh\"" 'info() { :; }' "$1"
    } >"$tmp/snippet.sh"
    CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" bash "$tmp/snippet.sh" >/dev/null 2>&1 || true
    cat "$tmp/calls"
}
nl='
'
# What an install becomes (apt-get, non-interactive, bounded lock wait, keep changed conffiles) - as
# sudo sees it (`env` carries the variables past sudo's env_reset) and as apt-get itself sees it.
opts='-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
ENV='env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a'
I="apt-get -qq $opts install"
U='apt-get -qq -o DPkg::Lock::Timeout=600 update'

# --- every install and update goes to apt-get -qq, through sudo or as root --------------------------
out="$(run 'quiet_apt_enable; sudo apt install -y git curl; sudo apt-get install -y gpg; sudo apt update -y; apt install -y wget; apt-get update')"
want="sudo $ENV $I -y git curl${nl}$I -y git curl${nl}sudo $ENV $I -y gpg${nl}$I -y gpg${nl}sudo $U -y${nl}$U -y${nl}$I -y wget${nl}$U"
[ "$out" = "$want" ] || fail "install must become non-interactive apt-get -qq and update apt-get -qq, both with a lock timeout and sudo kept (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# --- everything else passes through untouched ------------------------------------------------------
out="$(run 'quiet_apt_enable; sudo apt list --installed; sudo apt remove -y x; sudo apt-cache policy x; sudo systemctl status y; apt --version')"
want="sudo apt list --installed${nl}apt list --installed${nl}sudo apt remove -y x${nl}apt remove -y x${nl}sudo apt-cache policy x${nl}apt-cache policy x${nl}sudo systemctl status y${nl}systemctl status y${nl}apt --version"
[ "$out" = "$want" ] || fail "other apt subcommands and other sudo commands must be untouched (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# --- the argument shapes the installer really uses -----------------------------------------------------
out="$(run 'quiet_apt_enable; sudo apt install -f -y; sudo apt install -y ./pkg.deb')"
want="sudo $ENV $I -f -y${nl}$I -f -y${nl}sudo $ENV $I -y ./pkg.deb${nl}$I -y ./pkg.deb"
[ "$out" = "$want" ] || fail "install -f -y and a local .deb path must keep their arguments (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# --- exit codes are the command's own (the installer's `|| warn` chains depend on it) -------------------
: >"$tmp/calls"
cat >"$tmp/snippet.sh" <<EOF
set -u
. "$repo_root/scripts/lib/agent-skills.sh"
info() { :; }
quiet_apt_enable
rc=0; sudo apt install -y nope || rc=\$?
rc2=0; apt-get update || rc2=\$?
echo "\$rc \$rc2" >"$tmp/codes"
EOF
CALLS="$tmp/calls" FAKE_EXIT=100 PATH="$tmp/bin:$PATH" bash "$tmp/snippet.sh" >/dev/null 2>&1 || true
[ "$(cat "$tmp/codes")" = "100 100" ] || fail "the exit status of apt must come through (got: $(cat "$tmp/codes" 2>/dev/null))"

# --- dpkg's own stdout is captured, kept in apt.log, and shown only when apt fails -------------------------
# `apt-get -qq` silences apt but not dpkg: a WSL `dot up` (2026-10-11) still printed the whole
# "Selecting previously unselected package ... / Unpacking ... / Setting up ... / update-alternatives"
# wall for one JDK. stdout goes to ~/.local/state/dotfiles/apt.log (XDG_STATE_HOME-aware, one
# header per call) and comes back on the terminal only when the command fails; stderr - where apt
# and dpkg put their errors - is never captured. DOT_APT_VERBOSE=1 leaves everything on the terminal.
for t in apt apt-get; do
    cat >"$tmp/bin/$t" <<EOF
#!/bin/sh
echo "$t \$*" >>"\$CALLS"
for a; do last=\$a; done
echo "Selecting previously unselected package \$last."
echo "E: on stderr" >&2
exit "\${FAKE_EXIT:-0}"
EOF
    chmod +x "$tmp/bin/$t"
done
state="$tmp/state"
rm -rf "$state"
cat >"$tmp/snippet.sh" <<EOF
set -u
. "$repo_root/scripts/lib/agent-skills.sh"
info() { :; }
quiet_apt_enable
rc=0; sudo apt install -y libxt-dev || rc=\$?
echo "rc=\$rc"
EOF
out="$(CALLS="$tmp/calls" XDG_STATE_HOME="$state" PATH="$tmp/bin:$PATH" bash "$tmp/snippet.sh" 2>"$tmp/stderr")"
[ "$out" = "rc=0" ] || fail "a successful install must print nothing of dpkg's on stdout (got: $(printf '%s' "$out" | tr '\n' '|'))"
grep -Fxq 'E: on stderr' "$tmp/stderr" || fail "stderr must pass through live even when stdout is captured (got: $(tr '\n' '|' <"$tmp/stderr"))"
grep -Fq 'Selecting previously unselected package libxt-dev.' "$state/dotfiles/apt.log" 2>/dev/null \
    || fail "the captured dpkg output must land in \$XDG_STATE_HOME/dotfiles/apt.log (got: $(tr '\n' '|' <"$state/dotfiles/apt.log" 2>/dev/null))"
grep -Eq '^=== [0-9T:-]+ .*DEBIAN_FRONTEND=noninteractive .*apt-get -qq .*install -y libxt-dev' "$state/dotfiles/apt.log" 2>/dev/null \
    || fail "every captured call must start with a dated header naming the command (got: $(tr '\n' '|' <"$state/dotfiles/apt.log" 2>/dev/null))"
pass
out="$(CALLS="$tmp/calls" XDG_STATE_HOME="$state" FAKE_EXIT=100 PATH="$tmp/bin:$PATH" bash "$tmp/snippet.sh" 2>/dev/null)"
case "$out" in
    *'Selecting previously unselected package libxt-dev.'*'rc=100'*) pass ;;
    *) fail "a failed install must replay the captured stdout before the caller's own || warn, and keep the exit code (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
out="$(CALLS="$tmp/calls" XDG_STATE_HOME="$state" DOT_APT_VERBOSE=1 PATH="$tmp/bin:$PATH" bash "$tmp/snippet.sh" 2>/dev/null)"
case "$out" in
    *'Selecting previously unselected package libxt-dev.'*) pass ;;
    *) fail "DOT_APT_VERBOSE=1 must leave dpkg's output on the terminal (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
# other apt subcommands are never captured
out="$(CALLS="$tmp/calls" XDG_STATE_HOME="$state" PATH="$tmp/bin:$PATH" bash -c 'set -u; . "$1"; info() { :; }; quiet_apt_enable; sudo apt-get remove -y x' _ "$repo_root/scripts/lib/agent-skills.sh" 2>/dev/null)"
case "$out" in
    *'Selecting previously unselected package x.'*) pass ;;
    *) fail "only install/update are captured; remove must keep its stdout (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
# restore the silent fakes for the scenarios below
for t in apt apt-get; do
    cat >"$tmp/bin/$t" <<EOF
#!/bin/sh
echo "$t \$*" >>"\$CALLS"
exit "\${FAKE_EXIT:-0}"
EOF
    chmod +x "$tmp/bin/$t"
done

# --- verbose drops only the quieting, and nothing is defined before the call --------------------------------
# DOT_APT_VERBOSE=1 used to leave apt alone entirely - and [data.logging] verbose = true sets it, so
# a fresh Ubuntu 26.04 VM (2026-10-23) stopped on iperf3's debconf dialog, and Ctrl+C left that apt
# holding the dpkg lock for the next two runs. Verbose shows apt's output; it never lets apt ask.
out="$(run 'DOT_APT_VERBOSE=1 quiet_apt_enable; sudo apt install -y git; apt update')"
want="sudo $ENV apt-get $opts install -y git${nl}apt-get $opts install -y git${nl}apt-get -o DPkg::Lock::Timeout=600 update"
[ "$out" = "$want" ] || fail "DOT_APT_VERBOSE=1 must keep installs non-interactive and lock-bounded, without -qq (got: $(printf '%s' "$out" | tr '\n' '|'))"
out="$(run 'export DOT_APT_LOCK_TIMEOUT=30; quiet_apt_enable; apt-get update')"
[ "$out" = "apt-get -qq -o DPkg::Lock::Timeout=30 update" ] || fail "DOT_APT_LOCK_TIMEOUT must set the lock wait (got: $out)"
out="$(run 'sudo apt install -y git')"
want="sudo apt install -y git${nl}apt install -y git"
[ "$out" = "$want" ] || fail "before quiet_apt_enable nothing may change (got: $(printf '%s' "$out" | tr '\n' '|'))"
run 'echo "$(type -t apt) $(type -t sudo) $(type -t apt-get)" >"'"$tmp"'/types"' >/dev/null
case "$(cat "$tmp/types")" in
    "file file file" | "file  file" | " file " | "file file ") ;;
    *) fail "the library must not define apt/sudo/apt-get until quiet_apt_enable runs, so macOS' command -v apt stays honest (got: $(cat "$tmp/types"))" ;;
esac
pass

# --- apt_lock_preflight: name the holder; stop for one stuck on a debconf dialog OR one that is
# just plain stopped (state T, an orphan left by a timed-out step - issue #431 Run 2) -------------
# The 2026-10-23 incident, replayed with a fake pgrep/ps: runs 2 and 3 printed "Waiting for cache lock"
# for minutes behind an apt from run 1 that sat under an invisible whiptail. unattended-upgrade-shutdown
# shares unattended-upgrade's 15-char comm but only idles until shutdown, so it is never a holder.
cat >"$tmp/bin/pgrep" <<'EOF'
#!/bin/sh
case "$*" in
    *whiptail*) out="${FAKE_DIALOGS:-}" ;;
    *) out="${FAKE_HOLDERS:-}" ;;
esac
[ -n "$out" ] || exit 1
printf '%s\n' "$out"
EOF
cat >"$tmp/bin/ps" <<'EOF'
#!/bin/sh
case "$*" in
    *stat=*)
        # the argument after -p; not ${*##*-p }, which bash (a bash /bin/sh, Git Bash) strips per word
        pid=""; prev=""; for a in "$@"; do [ "$prev" = -p ] && pid="$a"; prev="$a"; done
        for p in ${FAKE_STOPPED:-}; do [ "$p" = "$pid" ] && { echo " T"; exit 0; }; done
        echo " S"
        ;;
    *) echo " 16:04" ;;
esac
EOF
chmod +x "$tmp/bin/pgrep" "$tmp/bin/ps"
preflight() { # env assignments as arguments; prints "rc=N" after the combined output
    env PATH="$tmp/bin:$PATH" "$@" bash -c '. "$1"; rc=0; apt_lock_preflight || rc=$?; echo "rc=$rc"' _ "$repo_root/scripts/lib/agent-skills.sh" 2>&1
}
idle='1276 /usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown --wait-for-signal'
stuck='12942 apt install -y net-tools iperf3'
out="$(preflight FAKE_HOLDERS="$idle")"
[ "$out" = "rc=0" ] || fail "an idle unattended-upgrade-shutdown is not a lock holder (got: $(printf '%s' "$out" | tr '\n' '|'))"
out="$(preflight FAKE_HOLDERS="$stuck")"
case "$out" in
    *'12942 apt install -y net-tools iperf3 (running 16:04)'*rc=0) ;;
    *) fail "a busy package manager is named with its age and waited for, not fatal (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
out="$(preflight FAKE_HOLDERS="$idle
$stuck" FAKE_DIALOGS=12988)"
case "$out" in
    *'stuck on a debconf question'*'sudo kill 12942 12988 && sudo dpkg --configure -a'*rc=1) ;;
    *) fail "an apt under a debconf dialog must stop the run with the exact clean-up command (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
case "$out" in *1276*) fail "the clean-up command must not kill unattended-upgrade-shutdown (got: $(printf '%s' "$out" | tr '\n' '|'))" ;; esac
pass
# A holder that is merely busy (state S, not T) and under no dialog: still not fatal.
out="$(preflight FAKE_HOLDERS="$stuck")"
case "$out" in
    *rc=0) ;;
    *) fail "a running (state S), undialoged holder must not stop the run (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
# A holder that is STOPPED (state T) with no dialog in sight: net_timeout_tty's --foreground only
# ever signals its direct child, never a descendant left orphaned by the timeout (apt_lock_preflight's
# own comment) - this is the Playwright-orphan shape from issue #431 Run 2, and must be just as fatal
# as the debconf-dialog case, with the same clean-up command (no dialog pid to append this time).
out="$(preflight FAKE_HOLDERS="$stuck" FAKE_STOPPED=12942)"
case "$out" in
    *'stopped (state T)'*'sudo kill 12942 && sudo dpkg --configure -a'*rc=1) ;;
    *) fail "a stopped (state T) holder with no dialog must stop the run with the clean-up command (got: $(printf '%s' "$out" | tr '\n' '|'))" ;;
esac
pass
# Call-site ordering: a call's LINE NUMBER is not its execution order here - the playwright-site
# call lives inside install_agent_toolkit(), a function defined (and thus textually earlier in the
# file) before main() itself, even though it runs AFTER main()'s own top-of-run call. So pick, for
# each anchor, the nearest apt_lock_preflight call strictly AFTER it - not just the first by line.
tpl="$repo_root/run_onchange_install_packages.sh.tmpl"
tpl_calls="$(grep -n '! apt_lock_preflight' "$tpl" | cut -d: -f1)"
qa_call="$(awk '!/^[[:space:]]*#/ && /quiet_apt_enable/ { print NR; exit }' "$tpl")"
after_qa="$(awk -v n="$qa_call" '$1>n{print;exit}' <<<"$tpl_calls")"
[ -n "$after_qa" ] || fail "the installer must run apt_lock_preflight right after quiet_apt_enable, before any apt call"
pass
# A second call, right after install_playwright_chromium: that step's own sudo_net_timeout_tty is
# exactly where a Playwright-orphaned apt-get (issue #431 Run 2) would be created, and every apt
# call downstream of it (desktop apps, mobile_dev's scrcpy, OpenCode Desktop) needs the same guard,
# not just the one before install_apt/install_brew.
[ "$(wc -l <<<"$tpl_calls")" -ge 2 ] || fail "apt_lock_preflight must also be re-checked after install_playwright_chromium, not only once at the top"
pw_call="$(awk '!/^[[:space:]]*#/ && /install_playwright_chromium$/ { print NR; exit }' "$tpl")"
after_pw="$(awk -v n="$pw_call" '$1>n{print;exit}' <<<"$tpl_calls")"
[ -n "$after_pw" ] || fail "the second apt_lock_preflight call must come after install_playwright_chromium runs"
pass

# --- wiring: enabled only once apt is the known package manager --------------------------------------------
tpl="$repo_root/run_onchange_install_packages.sh.tmpl"
set_line="$(grep -n 'PKG_MANAGER="$pkg_manager"' "$tpl" | head -1 | cut -d: -f1)"
# The CALL, not any mention: this used to take the first textual match, so a
# comment that merely named quiet_apt_enable earlier in the file (the sudo
# helper's note about the sudo() shim) looked like a call before PKG_MANAGER
# was set and failed the ordering check. awk keeps the real line number while
# skipping full-line comments.
call_line="$(awk '!/^[[:space:]]*#/ && /quiet_apt_enable/ { print NR; exit }' "$tpl")"
if [ -z "$set_line" ] || [ -z "$call_line" ] || [ "$call_line" -le "$set_line" ]; then
    fail "quiet_apt_enable must be called after PKG_MANAGER is set"
fi
grep -Eq 'if \[ "\$PKG_MANAGER" = apt \]; then quiet_apt_enable; fi' "$tpl" || fail "quiet_apt_enable must be guarded by PKG_MANAGER = apt"
pass

finish
