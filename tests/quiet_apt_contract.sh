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
