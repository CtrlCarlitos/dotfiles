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

# --- every install and update goes to apt-get -qq, through sudo or as root --------------------------
out="$(run 'quiet_apt_enable; sudo apt install -y git curl; sudo apt-get install -y gpg; sudo apt update -y; apt install -y wget; apt-get update')"
want="sudo apt-get -qq install -y git curl${nl}apt-get -qq install -y git curl${nl}sudo apt-get -qq install -y gpg${nl}apt-get -qq install -y gpg${nl}sudo apt-get -qq update -y${nl}apt-get -qq update -y${nl}apt-get -qq install -y wget${nl}apt-get -qq update"
[ "$out" = "$want" ] || fail "install/update must become apt-get -qq, with sudo kept (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# --- everything else passes through untouched ------------------------------------------------------
out="$(run 'quiet_apt_enable; sudo apt list --installed; sudo apt remove -y x; sudo apt-cache policy x; sudo systemctl status y; apt --version')"
want="sudo apt list --installed${nl}apt list --installed${nl}sudo apt remove -y x${nl}apt remove -y x${nl}sudo apt-cache policy x${nl}apt-cache policy x${nl}sudo systemctl status y${nl}systemctl status y${nl}apt --version"
[ "$out" = "$want" ] || fail "other apt subcommands and other sudo commands must be untouched (got: $(printf '%s' "$out" | tr '\n' '|'))"
pass

# --- the argument shapes the installer really uses -----------------------------------------------------
out="$(run 'quiet_apt_enable; sudo apt install -f -y; sudo apt install -y ./pkg.deb')"
want="sudo apt-get -qq install -f -y${nl}apt-get -qq install -f -y${nl}sudo apt-get -qq install -y ./pkg.deb${nl}apt-get -qq install -y ./pkg.deb"
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
    || fail "the captured dpkg output must land in \$XDG_STATE_HOME/dotfiles/apt.log (got: $(/bin/cat "$state/dotfiles/apt.log" 2>/dev/null | tr '\n' '|'))"
grep -Eq '^=== [0-9T:-]+ .*apt-get -qq install -y libxt-dev' "$state/dotfiles/apt.log" 2>/dev/null \
    || fail "every captured call must start with a dated header naming the command (got: $(/bin/cat "$state/dotfiles/apt.log" 2>/dev/null | tr '\n' '|'))"
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

# --- off switch, and nothing is defined before the call ----------------------------------------------------
out="$(run 'DOT_APT_VERBOSE=1 quiet_apt_enable; sudo apt install -y git; apt update')"
want="sudo apt install -y git${nl}apt install -y git${nl}apt update"
[ "$out" = "$want" ] || fail "DOT_APT_VERBOSE=1 must leave apt alone (got: $(printf '%s' "$out" | tr '\n' '|'))"
out="$(run 'sudo apt install -y git')"
want="sudo apt install -y git${nl}apt install -y git"
[ "$out" = "$want" ] || fail "before quiet_apt_enable nothing may change (got: $(printf '%s' "$out" | tr '\n' '|'))"
run 'echo "$(type -t apt) $(type -t sudo) $(type -t apt-get)" >"'"$tmp"'/types"' >/dev/null
case "$(cat "$tmp/types")" in
    "file file file" | "file  file" | " file " | "file file ") ;;
    *) fail "the library must not define apt/sudo/apt-get until quiet_apt_enable runs, so macOS' command -v apt stays honest (got: $(cat "$tmp/types"))" ;;
esac
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
