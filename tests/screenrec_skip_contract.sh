#!/usr/bin/env bash
set -euo pipefail

# ScreenRec on a release that cannot install it, EXECUTED.
#
# screenrec's .deb hard-depends on libgdk-pixbuf2.0-0, renamed on Ubuntu 24.04+. Every `dot up`
# on #431's Ubuntu 26.04 VM (Run 17) still added the vendor repo, ran two apt updates and a
# failed install, then removed the repo: about 8 s and four sudo calls for the same warning.
# The rendered installer's ScreenRec step runs against a stub apt-cache and a logging $SUDO:
#   1. the old dependency has no candidate - skipped with a line that says why; no sudo at all;
#   2. it has one - the repo setup runs as before (stopped here at a failing download).

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$repo_root/tests/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render_to "$tmp/installer.sh" sh '{"dev_desktop": true}'
awk '/^screenrec_installable\(\) \{/ {on = 1} on {print} on && /^\}/ {exit}' "$tmp/installer.sh" >"$tmp/fn.sh"
awk '/# 4\. ScreenRec/ {on = 1} /# 5\. Handy/ {exit} on {print}' "$tmp/installer.sh" >"$tmp/block.sh"
grep -q 'apt-cache policy libgdk-pixbuf2.0-0' "$tmp/fn.sh" || fail "screenrec_installable not found in the rendered installer"
grep -q 'Installing ScreenRec' "$tmp/block.sh" || fail "ScreenRec block not found in the rendered installer (source shape changed?)"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/apt-cache" <<'EOF'
#!/bin/sh
printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$3" "${CANDIDATE:?}"
EOF
chmod +x "$tmp/bin/apt-cache"
{
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' 'info() { printf "info: %s\n" "$1"; }' 'warn() { printf "warn: %s\n" "$1"; }'
    printf '%s\n' 'stub_sudo() { printf "%s\n" "$*" >>"$SUDO_LOG"; }' 'SUDO=stub_sudo'
    printf '%s\n' 'net_timeout() { return 1; }' # the key download fails: no network in a test
    cat "$tmp/fn.sh"
    printf '%s\n' 'f() {'
    cat "$tmp/block.sh"
    printf '%s\n' '}' 'f'
} >"$tmp/harness.sh"

run() { # $1 = candidate for libgdk-pixbuf2.0-0
    : >"$tmp/sudo.log"
    CANDIDATE="$1" SUDO_LOG="$tmp/sudo.log" PATH="$tmp/bin:/usr/bin:/bin" bash "$tmp/harness.sh" 2>&1
}

# 1. Not installable: skipped, said, and nothing privileged ran.
out="$(run '(none)')"
case "$out" in *'ScreenRec skipped'*'libgdk-pixbuf2.0-0'*) pass ;; *) fail "uninstallable: the skip must say why (got: $out)" ;; esac
[ -s "$tmp/sudo.log" ] && fail "uninstallable: no sudo may run (ran: $(tr '\n' ';' <"$tmp/sudo.log"))" || pass

# 2. Installable: the repo setup still runs.
out="$(run '2.42.10+dfsg-3')"
case "$out" in *'Installing ScreenRec'*) pass ;; *) fail "installable: the install must still be tried (got: $out)" ;; esac
grep -q 'mkdir -p /etc/apt/keyrings' "$tmp/sudo.log" && pass || fail "installable: the repo setup must run"

finish
